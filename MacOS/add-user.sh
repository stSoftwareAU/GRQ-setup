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

# Validate arguments
if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
  echo "Usage: $0 <username> <node_number> <automated_password>"
  echo "  This script adds a user to an existing Mac setup"
  echo "  The daemon will run <username>.sh from the user's GRQ directory"
  exit 1
fi

USERNAME="$1"
NODE_NUMBER="$2"
AUTOMATED_PASSWORD="$3"
CURRENT_USER=$(whoami)

echo "👤 Adding user '$USERNAME' to existing Mac setup..."

# Create user or detect existing one
USER_HOME=""
if ! id -u "$USERNAME" &>/dev/null; then
  echo "Creating user $USERNAME"
  sudo sysadminctl -addUser "$USERNAME" -fullName "Automated User" -password "$AUTOMATED_PASSWORD" -home "/Users/$USERNAME" -adminUser "$CURRENT_USER"
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
  
  # Update password in case it changed
  sudo sysadminctl -resetPasswordFor "$USERNAME" -newPassword "$AUTOMATED_PASSWORD" -adminUser "$CURRENT_USER"
  echo "Password updated for $USERNAME"
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

# Push SSH key to admin
ssh-copy-id -f nigel@10.0.0.11
echo "verify host"
ssh nigel@10.0.0.11 hostname
ssh nigel@10.0.0.89 hostname

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

