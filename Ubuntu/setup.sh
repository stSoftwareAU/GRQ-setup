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

# Validate arguments
if [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: $0 <node_number> <automated_password> [create_elephant]"
  echo "  create_elephant: optional 'true' to create elephant user for heavy lift tasks"
  exit 1
fi

NODE_NUMBER="$1"
AUTOMATED_PASSWORD="$2"
CREATE_ELEPHANT="$3"
HOSTNAME="GRQ-${NODE_NUMBER}"
CURRENT_USER=$(whoami)

echo "🔧 Setting up GRQ Node ${NODE_NUMBER} (SAFE MODE)"

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

# Create automated users rocket and sloth (idempotent)
create_automated_user() {
  local USERNAME=$1
  local FULLNAME=$2

  if ! id -u "$USERNAME" &>/dev/null; then
    echo "Creating user $USERNAME"
    sudo useradd -m -s /bin/bash -c "$FULLNAME" "$USERNAME"
    echo "$USERNAME:$AUTOMATED_PASSWORD" | sudo chpasswd
    # Remove from sudo group if they were added previously
    sudo deluser "$USERNAME" sudo 2>/dev/null || true
    echo "User $USERNAME created successfully (no sudo access)"
  else
    echo "User $USERNAME already exists"
    # Update password in case it changed
    echo "$USERNAME:$AUTOMATED_PASSWORD" | sudo chpasswd
    # Ensure they don't have sudo access
    sudo deluser "$USERNAME" sudo 2>/dev/null || true
    echo "Password updated for $USERNAME (sudo access removed)"
  fi

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

  # Check if script already exists and is up to date
  if [[ -f "$SCRIPT_PATH" ]] && grep -q "NODE_NUMBER=${NODE_NUMBER}" "$SCRIPT_PATH"; then
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

# Push SSH key to admin
echo "Setting up SSH access to admin servers..."
ssh-copy-id -f nigel@10.0.0.11
echo "Verifying host connections..."
ssh nigel@10.0.0.11 hostname
ssh nigel@10.0.0.89 hostname

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
