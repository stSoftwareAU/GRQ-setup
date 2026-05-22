#!/bin/bash
set -e

# ASCII Art Header
cat << 'EOF'
    ██████╗ ██████╗  ██████╗     ███████╗███████╗████████╗██╗   ██╗██████╗ 
    ██╔══██╗██╔══██╗██╔═══██╗    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
    ██████╔╝██████╔╝██║   ██║    ███████╗█████╗     ██║   ██║   ██║██████╔╝
    ██╔══██╗██╔══██╗██║   ██║    ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ 
    ██║  ██║██║  ██║╚██████╔╝    ███████║███████╗   ██║   ╚██████╔╝██║     
    ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝     ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝     
                                                                            
    🚀 ML Training Node Setup - SAFE Ubuntu Edition 🚀
    ==================================================
EOF

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "${BASE_DIR}/.." && pwd -P)"
cd "${BASE_DIR}"

# Supply-chain hardening (issue #16): pin every external installer to a
# specific version and verify SHA-256 before executing.
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/pinned_versions.sh"

# Per-account passwords (issue #18): each automated user gets its own
# randomly generated password stored in a root-owned 0600 file under
# /var/lib/grq/passwords. A single shared password gave any one account
# compromise full reach over all of them.
export GRQ_PASSWORD_DIR="/var/lib/grq/passwords"
export GRQ_PASSWORD_OWNER="root:root"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/per_user_password.sh"

# Validate arguments. The second positional argument used to be a single
# shared <automated_password>; it is retained for backwards CLI
# compatibility but is now ignored (see issue #18).
if [[ -z "$1" ]]; then
  echo "Usage: $0 <node_number> [ignored_password] [create_elephant]"
  echo "  ignored_password: retained for backwards compatibility — ignored (issue #18)"
  echo "  create_elephant: optional 'true' to create elephant user for heavy lift tasks"
  exit 1
fi

NODE_NUMBER="$1"
AUTOMATED_PASSWORD_DEPRECATED="${2:-}"
CREATE_ELEPHANT="${3:-}"
HOSTNAME="GRQ-${NODE_NUMBER}"
CURRENT_USER=$(whoami)

if [[ -n "$AUTOMATED_PASSWORD_DEPRECATED" ]]; then
  echo "NOTE: the <automated_password> positional argument is deprecated and ignored (issue #18)."
  echo "      Each automated user now has its own random password persisted in"
  echo "      ${GRQ_PASSWORD_DIR}/<user>.secret (root-owned, 0600)."
fi

echo "🔧 Setting up GRQ Node ${NODE_NUMBER} (SAFE MODE)"

# SSH host-key TOFU hardening (issue #17): copy the pre-distributed
# admin known_hosts file into /etc/ssh/ssh_known_hosts so every newly
# provisioned user can verify the admin hosts (10.0.0.11, 10.0.0.89)
# under StrictHostKeyChecking=yes instead of blindly accepting whatever
# key is on the wire on first connection.
install_admin_known_hosts() {
  local src="${REPO_ROOT}/lib/admin_known_hosts"
  local dst="/etc/ssh/ssh_known_hosts"

  if [[ ! -f "$src" ]]; then
    echo "WARNING: $src not found — generated user setup scripts will fail-closed when they try to ssh to admin hosts." >&2
    return 0
  fi

  if ! grep -E -v '^[[:space:]]*(#|$)' "$src" >/dev/null 2>&1; then
    echo "WARNING: $src contains no pinned host keys — populate it before users run ~/setup.sh." >&2
  fi

  echo "Installing admin known_hosts to $dst"
  sudo install -m 0644 -o root -g root "$src" "$dst"
}

install_admin_known_hosts

# Set hostname (idempotent)
echo "Setting hostname to ${HOSTNAME}"
CURRENT_HOSTNAME=$(hostname)
if [[ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]]; then
  sudo hostnamectl set-hostname "${HOSTNAME}"
  echo "Hostname changed from $CURRENT_HOSTNAME to $HOSTNAME"
else
  echo "Hostname already set to $HOSTNAME"
fi

# Update /etc/hosts (idempotent)
if ! grep -q "127.0.1.1 ${HOSTNAME}" /etc/hosts; then
  echo "127.0.1.1 ${HOSTNAME}" | sudo tee -a /etc/hosts
  echo "Added hostname entry to /etc/hosts"
else
  echo "Hostname entry already exists in /etc/hosts"
fi

# Per-account passwords (issue #18): make sure the password store exists
# before any create_automated_user call asks for a per-user secret.
ensure_password_dir

# Create automated users rocket and sloth (idempotent). Each user gets
# its own randomly generated password from get_or_create_user_password.
# We only call chpasswd when the persisted .secret file is newly minted —
# subsequent reruns leave the existing account password alone so the
# script is idempotent. To rotate a password, delete the .secret file
# under $GRQ_PASSWORD_DIR and rerun.
create_automated_user() {
  local USERNAME=$1
  local FULLNAME=$2

  local PWFILE="${GRQ_PASSWORD_DIR}/${USERNAME}.secret"
  local PWFILE_EXISTED="no"
  if sudo test -f "$PWFILE"; then
    PWFILE_EXISTED="yes"
  fi

  local USER_PASSWORD
  USER_PASSWORD=$(get_or_create_user_password "$USERNAME")

  if ! id -u "$USERNAME" &>/dev/null; then
    echo "Creating user $USERNAME"
    sudo useradd -m -s /bin/bash -c "$FULLNAME" "$USERNAME"
    # New account — always apply the freshly generated per-user password.
    echo "$USERNAME:$USER_PASSWORD" | sudo chpasswd
    # Remove from sudo group if they were added previously
    sudo deluser "$USERNAME" sudo 2>/dev/null || true
    echo "User $USERNAME created successfully (no sudo access)"
  else
    echo "User $USERNAME already exists"
    if [[ "$PWFILE_EXISTED" == "no" ]]; then
      # First-rerun migration from the old shared-password regime: the
      # persisted secret was just created, so push it onto the existing
      # account exactly once.
      echo "$USERNAME:$USER_PASSWORD" | sudo chpasswd
      echo "Per-user password initialised for $USERNAME (persisted at $PWFILE)"
    else
      echo "Per-user password for $USERNAME already persisted — leaving account password unchanged"
    fi
    # Ensure they don't have sudo access
    sudo deluser "$USERNAME" sudo 2>/dev/null || true
  fi
  unset USER_PASSWORD

  # Create logs directory (idempotent)
  sudo -u $USERNAME mkdir -p /home/$USERNAME/logs
  echo "Logs directory ensured for $USERNAME"
}

create_automated_user "rocket" "High performance Automated User"
create_automated_user "sloth" "Low priority Automated User"

# Create elephant user if requested
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  echo "Creating elephant user for heavy lift tasks"
  create_automated_user "elephant" "Heavy lift Automated User"
fi

# Create per-user setup scripts for SSH key generation and tool installation (idempotent)
create_user_setup_script() {
  local USERNAME=$1
  local SCRIPT_PATH="/home/$USERNAME/setup.sh"

  # Check if script already exists and is up to date. Issue #17 added the
  # StrictHostKeyChecking marker, so any script written before that fix is
  # treated as stale and regenerated.
  if [[ -f "$SCRIPT_PATH" ]] \
      && grep -q "NODE_NUMBER=${NODE_NUMBER}" "$SCRIPT_PATH" \
      && grep -q "StrictHostKeyChecking=yes" "$SCRIPT_PATH"; then
    echo "Setup script for $USERNAME already exists and is current"
  else
    echo "Creating/updating setup script for $USERNAME"
    sudo tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
set -e

USERNAME=\$(whoami)
NODE_NUMBER=${NODE_NUMBER}

echo "🔧 Setting up tools and environment for \$USERNAME..."

# Supply-chain hardening (issue #16): download installers to a temp file,
# verify against the SHA-256 pinned by the GRQ-setup admin, and refuse to
# execute on mismatch.
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
  if command -v sha256sum >/dev/null 2>&1; then
    actual=\$(sha256sum "\$tmp" | awk '{print \$1}')
  else
    actual=\$(shasum -a 256 "\$tmp" | awk '{print \$1}')
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

# Install Deno if missing (pinned, verified)
if ! command -v deno &> /dev/null; then
  echo "Installing Deno..."
  if ! _grq_verify_install "${DENO_INSTALL_URL}" "${DENO_INSTALL_SHA256}"; then
    echo "ERROR: Deno installer failed pinned SHA-256 verification — aborting." >&2
    exit 1
  fi
  export PATH="\$HOME/.deno/bin:\$PATH"
  echo "Deno installed successfully"
else
  echo "Deno already installed"
fi

# Install Rust if missing (pinned, verified)
if ! command -v rustc &> /dev/null; then
  echo "Installing Rust..."
  if ! _grq_verify_install "${RUSTUP_INSTALL_URL}" "${RUSTUP_INSTALL_SHA256}" -s -- -y; then
    echo "ERROR: Rust installer failed pinned SHA-256 verification — aborting." >&2
    exit 1
  fi
  export PATH="\$HOME/.cargo/bin:\$PATH"
  echo "Rust installed successfully"
else
  echo "Rust already installed"
fi

# Configure PATH in .bashrc if not already present
BASHRC="\$HOME/.bashrc"
if ! grep -q "export PATH.*\.deno/bin" "\$BASHRC" 2>/dev/null; then
  echo 'export PATH="\$HOME/.deno/bin:\$PATH"' >> "\$BASHRC"
  echo "Added Deno to PATH in .bashrc"
fi

if ! grep -q "export PATH.*\.cargo/bin" "\$BASHRC" 2>/dev/null; then
  echo 'export PATH="\$HOME/.cargo/bin:\$PATH"' >> "\$BASHRC"
  echo "Added Rust to PATH in .bashrc"
fi

# Check if jq is available (should be system-wide)
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is not available. Please ensure jq is installed system-wide."
  echo "This should have been installed during system setup."
  exit 1
fi

# Generate SSH key if missing
if [[ ! -f "\$HOME/.ssh/id_ed25519" ]]; then
  echo "Generating new SSH key for \$USERNAME..."
  mkdir -p "\$HOME/.ssh"
  ssh-keygen -t ed25519 -f "\$HOME/.ssh/id_ed25519" -N "" -C "\${USERNAME}-\${NODE_NUMBER}@lecklogic.com"
  echo "SSH key generated successfully"
else
  echo "SSH key already exists"
fi

# Push SSH key to admin under strict host-key checking (issue #17).
# /etc/ssh/ssh_known_hosts was pre-populated by the provisioning script
# from lib/admin_known_hosts. Drop ssh-copy-id -f so any future
# fingerprint change is surfaced instead of silently overwritten.
echo "Setting up SSH access to admin servers..."
SSH_STRICT_OPTS=( -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts )
ssh-copy-id "\${SSH_STRICT_OPTS[@]}" nigel@10.0.0.11
echo "Verifying host connections..."
ssh "\${SSH_STRICT_OPTS[@]}" nigel@10.0.0.11 hostname
ssh "\${SSH_STRICT_OPTS[@]}" nigel@10.0.0.89 hostname

# Configure git
git config --global user.email "\${USERNAME}-\${NODE_NUMBER}@lecklogic.com"
git config --global user.name "\${USERNAME} \${NODE_NUMBER}"

# Setup GRQ repository
echo "Setting up GRQ repository..."
echo "Create GitHub ssh key..." 
cat ~/.ssh/id_ed25519.pub
read -p "Press enter to continue after adding this key to GitHub"
if [[ ! -d GRQ ]]; then
  git clone --depth 1 git@github.com:stSoftwareAU/GRQ.git
fi
GRQ/worker/upgrade.sh
echo "PRIMARY_READ_URL=nigel@10.0.0.89:Training" > GRQ/.env
echo "SECONDARY_READ_URL=nigel@10.0.0.11:Training" >> GRQ/.env

echo "✅ Setup complete for \$USERNAME!"
echo "Tools installed: Deno, Rust"
echo "SSH keys configured"
echo "GRQ repository ready"

EOF

    sudo chmod +x "$SCRIPT_PATH"
    sudo chown $USERNAME:$USERNAME "$SCRIPT_PATH"
    echo "Setup script created/updated for $USERNAME"
  fi
}

create_user_setup_script "rocket"
create_user_setup_script "sloth"

if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  create_user_setup_script "elephant"
fi

# Enable SSH server (idempotent)
echo "Enabling SSH server..."
sudo systemctl enable ssh
sudo systemctl start ssh
echo "SSH server enabled and started"

# Install essential packages only
echo "Installing essential packages..."
sudo apt update
sudo apt install -y git openssh-server jq curl htop unzip cron bc rsync build-essential dnsutils
# Set timezone
sudo timedatectl set-timezone Australia/Sydney

# Install user-specific crontabs with priority settings (idempotent)
echo "Installing user-specific crontabs with priority settings"

# Create rocket user crontab (NORMAL PRIORITY)
create_rocket_crontab() {
  local USERNAME="rocket"
  local CRON_FILE="/tmp/rocket_crontab"
  
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
# Rocket user - NORMAL PRIORITY (default) - runs every 5 minutes at :00, :05, :10, etc.
0,5,10,15,20,25,30,35,40,45,50,55 * * * * ~/GRQ/rocket.sh > ~/logs/rocket.log 2>&1
EOF
  
  sudo -u $USERNAME crontab "$CRON_FILE"
  rm -f "$CRON_FILE"
  echo "Rocket crontab installed with normal priority (default)"
}

# Create sloth user crontab (LOW PRIORITY)
create_sloth_crontab() {
  local USERNAME="sloth"
  local CRON_FILE="/tmp/sloth_crontab"
  
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
# Sloth user - LOW PRIORITY (nice) - runs every 5 minutes at :02, :07, :12, etc. (offset by 2 minutes)
2,7,12,17,22,27,32,37,42,47,52,57 * * * * nice -n19 ~/GRQ/sloth.sh > ~/logs/sloth.log 2>&1
EOF
  
  sudo -u $USERNAME crontab "$CRON_FILE"
  rm -f "$CRON_FILE"
  echo "Sloth crontab installed with low priority (nice)"
}

# Create elephant user crontab (LOW PRIORITY) - only if elephant user exists
create_elephant_crontab() {
  local USERNAME="elephant"
  local CRON_FILE="/tmp/elephant_crontab"
  
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
# Elephant user - LOW PRIORITY (nice) - runs every 5 minutes at :04, :09, :14, etc. (offset by 4 minutes)
4,9,14,19,24,29,34,39,44,49,54,59 * * * * nice -n19 ~/GRQ/elephant.sh > ~/logs/elephant.log 2>&1
EOF
  
  sudo -u $USERNAME crontab "$CRON_FILE"
  rm -f "$CRON_FILE"
  echo "Elephant crontab installed with low priority (nice)"
}

# Install crontabs
create_rocket_crontab
create_sloth_crontab

if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  create_elephant_crontab
fi

echo "All user crontabs installed with appropriate priority settings"

# Note: Deno and Rust installation is now handled in each user's setup script
echo "User tool installation will be handled when each user runs their ~/setup.sh script"

# Final setup message
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  echo "🚀 SAFE Setup complete. Now login as 'rocket', 'sloth', and 'elephant' and run '~/setup.sh' to create their SSH keys!"
else
  echo "🚀 SAFE Setup complete. Now login as 'rocket' and 'sloth' and run '~/setup.sh' to create their SSH keys!"
fi

echo ""
echo "✅ What this SAFE setup includes:"
echo "   - User creation (rocket, sloth, optional elephant)"
echo "   - SSH server enabled"
echo "   - Essential packages (git, jq, curl, htop, unzip)"
echo "   - User crontabs for task scheduling"
echo "   - Deno and Rust installation per user"
echo "   - User setup scripts for SSH key generation"
echo ""
echo "🔧 The machine will use DHCP for networking and rely on hardware-level power failure restart."
