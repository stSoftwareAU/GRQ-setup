#!/bin/bash
set -e

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "${BASE_DIR}/.." && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
cd "${BASE_DIR}"

# Supply-chain hardening (issue #16): pin every external installer to a
# specific version and verify SHA-256 before executing.
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/pinned_versions.sh"

# Per-account passwords (issue #18): each automated user gets its own
# randomly generated password stored in a root-owned 0600 file under
# /var/root/grq/passwords.
export GRQ_PASSWORD_DIR="/var/root/grq/passwords"
export GRQ_PASSWORD_OWNER="root:wheel"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/per_user_password.sh"

# Validate arguments. The third positional argument used to be a shared
# <automated_password>; it is retained for backwards CLI compatibility
# but is now ignored (see issue #18).
if [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: $0 <username> <node_number> [ignored_password]"
  echo "  This script adds a user to an existing Mac setup"
  echo "  The daemon will run <username>.sh from the user's GRQ directory"
  echo "  ignored_password: retained for backwards compatibility — ignored (issue #18)"
  exit 1
fi

USERNAME="$1"
NODE_NUMBER="$2"
AUTOMATED_PASSWORD_DEPRECATED="${3:-}"
CURRENT_USER=$(whoami)

if [[ -n "$AUTOMATED_PASSWORD_DEPRECATED" ]]; then
  echo "NOTE: the <automated_password> positional argument is deprecated and ignored (issue #18)."
  echo "      ${USERNAME}'s password is persisted at ${GRQ_PASSWORD_DIR}/${USERNAME}.secret"
  echo "      (root-owned, 0600). Delete that file and rerun to rotate."
fi

echo "👤 Adding user '$USERNAME' to existing Mac setup..."

# SSH host-key TOFU hardening (issue #17): refresh /etc/ssh/ssh_known_hosts
# from lib/admin_known_hosts so the new user's ~/setup.sh can verify the
# admin hosts under StrictHostKeyChecking=yes.
install_admin_known_hosts() {
  local src="${REPO_ROOT}/lib/admin_known_hosts"
  local dst="/etc/ssh/ssh_known_hosts"

  if [[ ! -f "$src" ]]; then
    echo "WARNING: $src not found — generated user setup script will fail-closed when it tries to ssh to admin hosts." >&2
    return 0
  fi

  if ! grep -E -v '^[[:space:]]*(#|$)' "$src" >/dev/null 2>&1; then
    echo "WARNING: $src contains no pinned host keys — populate it before the user runs ~/setup.sh." >&2
  fi

  echo "Installing admin known_hosts to $dst"
  sudo install -m 0644 -o root -g wheel "$src" "$dst"
}

install_admin_known_hosts

# Per-account passwords (issue #18): set up the password store and resolve
# this user's persisted secret. We only call sysadminctl when we are
# either creating the user fresh or when no persisted secret existed yet
# (so reruns are idempotent — to rotate, delete the .secret file and
# rerun).
# Issue #15: lib/grq_sysadm.sh reads the persisted .secret file directly
# as root and feeds the password to sysadminctl over a pty. The password
# is never on argv or in this script's variables.
ensure_password_dir
USER_PWFILE="${GRQ_PASSWORD_DIR}/${USERNAME}.secret"
PWFILE_EXISTED="no"
if [[ -f "$USER_PWFILE" ]] || sudo test -f "$USER_PWFILE"; then
  PWFILE_EXISTED="yes"
fi
ensure_user_password "$USERNAME"

# Create user or detect existing one
USER_HOME=""
if ! id -u "$USERNAME" &>/dev/null; then
  echo "Creating user $USERNAME"
  sudo "${REPO_ROOT}/lib/grq_sysadm.sh" \
    --password-file "$USER_PWFILE" \
    add "$USERNAME" "Automated User" "/Users/$USERNAME" "$CURRENT_USER"
  sudo createhomedir -c -u "$USERNAME"
  USER_HOME="/Users/$USERNAME"
  echo "User $USERNAME created successfully"
else
  echo "User $USERNAME already exists"
  # Get the actual home directory (may be on removable drive like /Volumes/GRQ/$USERNAME)
  USER_HOME=$(dscl . -read "/Users/$USERNAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  if [[ -z "$USER_HOME" ]]; then
    # Fallback method
    USER_HOME=$(eval echo ~"$USERNAME")
  fi

  # Validate that we got a valid home directory
  if [[ -z "$USER_HOME" ]]; then
    echo "ERROR: Could not determine $USERNAME user's home directory"
    exit 1
  fi

  echo "Detected $USERNAME home directory: $USER_HOME"

  # Verify the home directory exists
  if [[ ! -d "$USER_HOME" ]]; then
    echo "WARNING: Home directory $USER_HOME does not exist or is not mounted"
    echo "         The daemon will be configured, but ensure the drive is mounted before use"
  fi

  # First-rerun migration only: if the persisted secret was just created
  # for an account that existed under the old shared-password regime,
  # apply the freshly generated value. Subsequent reruns are no-ops.
  # Issue #15: helper feeds the password over a pty, not argv.
  if [[ "$PWFILE_EXISTED" == "no" ]]; then
    sudo "${REPO_ROOT}/lib/grq_sysadm.sh" \
      --password-file "$USER_PWFILE" \
      reset "$USERNAME" "$CURRENT_USER"
    echo "Per-user password initialised for $USERNAME (persisted at $USER_PWFILE)"
  else
    echo "Per-user password for $USERNAME already persisted — leaving account password unchanged"
  fi
fi

# Ensure logs directory exists in the actual home directory
sudo -u "$USERNAME" mkdir -p "$USER_HOME/logs"
echo "Logs directory ensured at $USER_HOME/logs"

# Create per-user setup script for SSH key generation
create_user_setup_script() {
  local USERNAME=$1
  local USER_HOME=$2

  sudo tee "$USER_HOME/setup.sh" > /dev/null <<EOF
#!/bin/bash
set -e

USERNAME=\$(whoami)
NODE_NUMBER=${NODE_NUMBER}
CARGO_PATH_SNIPPET='export PATH="\$HOME/.cargo/bin:\$PATH"'

if [[ -f "\$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "\$HOME/.cargo/env"
fi

# Confirm jq is present (installed system-wide during macOS provisioning)
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but missing. Please ask an administrator to rerun the macOS setup before continuing."
  exit 1
fi

# Supply-chain hardening (issue #16): download the installer, verify its
# SHA-256 against the hash pinned by the GRQ-setup admin, then execute.
_grq_verify_install() {
  # _grq_verify_install <url> <expected_sha256> [installer args...]
  local url="\$1" expected="\$2"
  shift 2
  local tmp
  tmp=\$(mktemp -t grq-installer.XXXXXX)
  echo "Fetching \$url"
  if ! curl --proto '=https' --tlsv1.2 -fsSL "\$url" -o "\$tmp"; then
    echo "ERROR: failed to download \$url" >&2
    rm -f "\$tmp"
    return 1
  fi
  local actual
  if command -v shasum >/dev/null 2>&1; then
    actual=\$(shasum -a 256 "\$tmp" | awk '{print \$1}')
  else
    actual=\$(sha256sum "\$tmp" | awk '{print \$1}')
  fi
  if [[ "\$actual" != "\$expected" ]]; then
    echo "ERROR: SHA-256 mismatch for \$url" >&2
    echo "  expected: \$expected" >&2
    echo "  actual:   \$actual" >&2
    rm -f "\$tmp"
    return 1
  fi
  sh "\$tmp" "\$@"
  local rc=\$?
  rm -f "\$tmp"
  return \$rc
}

# Install Rust toolchain if absent (pinned, verified)
if ! command -v rustc >/dev/null 2>&1; then
  echo "Installing Rust toolchain for \$USERNAME..."
  if ! _grq_verify_install "${RUSTUP_INSTALL_URL}" "${RUSTUP_INSTALL_SHA256}" -s -- -y; then
    echo "ERROR: Rust installer failed pinned SHA-256 verification — aborting." >&2
    exit 1
  fi
  if [[ -f "\$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "\$HOME/.cargo/env"
  fi
fi

export PATH="\$HOME/.cargo/bin:\$PATH"

for profile in "\$HOME/.zprofile" "\$HOME/.zshrc" "\$HOME/.bash_profile" "\$HOME/.bashrc" "\$HOME/.profile"; do
  if [[ -f "\$profile" ]]; then
    if ! grep -F "\$CARGO_PATH_SNIPPET" "\$profile" >/dev/null 2>&1; then
      echo "\$CARGO_PATH_SNIPPET" >> "\$profile"
    fi
  else
    echo "\$CARGO_PATH_SNIPPET" >> "\$profile"
  fi
done

# Generate SSH key if missing
if [[ ! -f "\$HOME/.ssh/id_ed25519" ]]; then
  echo "Generating new SSH key for \$USERNAME..."
  mkdir -p "\$HOME/.ssh"
  ssh-keygen -t ed25519 -f "\$HOME/.ssh/id_ed25519" -N "" -C "\${USERNAME}-\${NODE_NUMBER}@lecklogic.com"
fi

# Push SSH key to admin under strict host-key checking (issue #17).
# /etc/ssh/ssh_known_hosts was pre-populated by the provisioning script
# from lib/admin_known_hosts. Drop ssh-copy-id -f so any future
# fingerprint change is surfaced instead of silently overwritten.
SSH_STRICT_OPTS=( -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts )
ssh-copy-id "\${SSH_STRICT_OPTS[@]}" nigel@10.0.0.11
echo "verify host"
ssh "\${SSH_STRICT_OPTS[@]}" nigel@10.0.0.11 hostname
ssh "\${SSH_STRICT_OPTS[@]}" nigel@10.0.0.89 hostname

git config --global user.email "\${USERNAME}-\${NODE_NUMBER}@lecklogic.com"
git config --global user.name "\${USERNAME} \${NODE_NUMBER}"

echo "Create GitHub ssh key..." 
cat ~/.ssh/id_ed25519.pub
read -p "Press enter to continue"
if [[ ! -d GRQ ]]; then
  git clone --depth 1 git@github.com:stSoftwareAU/GRQ.git
fi
GRQ/worker/upgrade.sh
echo "PRIMARY_READ_URL=nigel@10.0.0.89:Training" > GRQ/.env
echo "SECONDARY_READ_URL=nigel@10.0.0.11:Training" >> GRQ/.env

EOF

  sudo chmod +x "$USER_HOME/setup.sh"
  sudo chown "$USERNAME:staff" "$USER_HOME/setup.sh"
  echo "Setup script created for $USERNAME at $USER_HOME/setup.sh"
}

create_user_setup_script "$USERNAME" "$USER_HOME"

# Install and bootstrap daemon with correct home directory paths
echo ""
echo "Installing daemon for $USERNAME..."
echo "Using detected home directory: $USER_HOME"

# Validate USER_HOME is set
if [[ -z "$USER_HOME" ]]; then
  echo "ERROR: USER_HOME is not set. Cannot install daemon."
  exit 1
fi

# Generate daemon label based on username
DAEMON_LABEL="com.lecklogic.${USERNAME}task"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
SCRIPT_NAME="${USERNAME}.sh"

# Generate daemon plist with actual home directory paths (supports removable drives)
sudo tee "$DAEMON_PLIST" > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${USER_HOME}/GRQ/${SCRIPT_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>Nice</key>
    <integer>20</integer> <!-- Low CPU priority for heavy disk I/O tasks -->
    <key>UserName</key>
    <string>${USERNAME}</string>
    <key>WorkingDirectory</key>
    <string>${USER_HOME}</string>
    <key>StandardOutPath</key>
    <string>${USER_HOME}/logs/${USERNAME}.out.log</string>
    <key>StandardErrorPath</key>
    <string>${USER_HOME}/logs/${USERNAME}.err.log</string>
</dict>
</plist>
EOF

sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 644 "$DAEMON_PLIST"
sudo launchctl bootout system "$DAEMON_PLIST" || true
sudo launchctl bootstrap system "$DAEMON_PLIST"
echo "Daemon installed and started with paths pointing to $USER_HOME"

echo ""
echo "✅ User '$USERNAME' setup complete!"
if [[ -n "$USER_HOME" ]]; then
  echo "   - User '$USERNAME' home directory: $USER_HOME"
fi
echo "   - Setup script created at $USER_HOME/setup.sh"
echo "   - Daemon installed and started (running $USER_HOME/GRQ/${SCRIPT_NAME})"
echo ""
echo "🔧 Next steps:"
echo "   1. Login as '$USERNAME' user"
echo "   2. Run '~/setup.sh' to create SSH keys and set up GRQ repository"
echo "   3. Ensure removable drives are mounted if home directory is on external drive"

