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
                                                                            
    🚀 ML Training Node Setup - Ubuntu Edition 🚀
    =============================================
EOF

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${BASE_DIR}"

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
IP_ADDRESS="10.0.0.${NODE_NUMBER}"
CURRENT_USER=$(whoami)

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

# Setup network configuration - static IP on primary interface, DHCP on secondary
echo "Configuring network"
PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
SECONDARY_INTERFACES=$(ip link show | grep -E '^[0-9]+:' | grep -v lo | awk -F: '{print $2}' | sed 's/^ *//' | grep -v "$PRIMARY_INTERFACE")

if [[ -n "$PRIMARY_INTERFACE" ]]; then
  echo "🔧 Configuring static IP on $PRIMARY_INTERFACE to ${IP_ADDRESS}"
  
  # Check if netplan config already exists and is correct
  NETPLAN_CONFIG="/etc/netplan/01-grq-static.yaml"
  if [[ -f "$NETPLAN_CONFIG" ]] && grep -q "$IP_ADDRESS" "$NETPLAN_CONFIG"; then
    echo "Network configuration already exists and is correct"
  else
    # Create netplan configuration
    sudo tee "$NETPLAN_CONFIG" > /dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $PRIMARY_INTERFACE:
      dhcp4: false
      addresses:
        - ${IP_ADDRESS}/24
      gateway4: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
EOF

    # Apply network configuration
    sudo netplan apply
    echo "🔧 Network configuration applied"
  fi
else
  echo "⚠️ No primary network interface found — skipping network configuration."
fi

# Auto-restart on freeze and power failure
echo "Configuring auto-restart on freeze and power failure"
sudo systemctl enable systemd-reboot.service

# Configure auto-restart on power failure
echo "Configuring auto-restart on power failure"
sudo systemctl enable systemd-poweroff.service
sudo systemctl enable systemd-reboot.service

# Set BIOS/UEFI settings for auto-restart on power failure (if supported)
if command -v efibootmgr &> /dev/null; then
  echo "Configuring UEFI auto-restart on power failure"
  sudo efibootmgr -A 2>/dev/null || echo "Note: UEFI auto-restart configuration may require manual BIOS settings"
fi

# Configure systemd to restart on power failure
sudo tee /etc/systemd/system/power-failure-restart.service > /dev/null <<EOF
[Unit]
Description=Restart on Power Failure
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo "Power failure detected, restarting system" && systemctl reboot'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable power-failure-restart.service

# Enable automatic updates
echo "Enabling automatic updates"
sudo apt update
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades

# Configure unattended upgrades
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF

# Disable sleep and low power modes for maximum performance
echo "Disabling sleep and power management for ML training"
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Disable unnecessary services for ML training performance
echo "Disabling unnecessary services for maximum CPU performance"
# Disable snap services (often resource-heavy)
sudo systemctl disable --now snapd 2>/dev/null || true
sudo systemctl mask snapd 2>/dev/null || true

# Disable bluetooth (not needed for ML training)
sudo systemctl disable --now bluetooth 2>/dev/null || true
sudo systemctl mask bluetooth 2>/dev/null || true

# Disable cups (printing service)
sudo systemctl disable --now cups 2>/dev/null || true
sudo systemctl mask cups 2>/dev/null || true

# Disable ModemManager (not needed)
sudo systemctl disable --now ModemManager 2>/dev/null || true
sudo systemctl mask ModemManager 2>/dev/null || true

# Set CPU governor to performance mode
echo "Setting CPU to performance mode"
echo 'GOVERNOR="performance"' | sudo tee /etc/default/cpufrequtils > /dev/null 2>/dev/null || true
sudo systemctl enable cpufrequtils 2>/dev/null || true
sudo systemctl start cpufrequtils 2>/dev/null || true

# Configure core dumps
echo "Configuring core dumps"
echo "kernel.core_pattern = /cores/core.%P" | sudo tee -a /etc/sysctl.conf
echo "kernel.core_uses_pid = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Create cores directory
sudo mkdir -p /cores
sudo chmod 755 /cores

# Clean up old core dumps
if [[ -d /cores ]]; then
  echo "Cleaning up old core dumps"
  sudo find /cores -name "core.*" -type f -delete 2>/dev/null || true
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

# Install and configure systemd services for rocket and sloth
echo "Installing systemd services"

# Create rocket service (idempotent)
ROCKET_SERVICE="/etc/systemd/system/rocket-daemon.service"
if [[ ! -f "$ROCKET_SERVICE" ]] || ! grep -q "High Priority Task Daemon" "$ROCKET_SERVICE"; then
  echo "Creating rocket daemon service"
  sudo tee "$ROCKET_SERVICE" > /dev/null <<EOF
[Unit]
Description=High Priority Task Daemon
After=network.target

[Service]
Type=simple
User=rocket
Group=rocket
WorkingDirectory=/home/rocket
ExecStart=/bin/bash -c 'while true; do sleep 60; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
else
  echo "Rocket daemon service already exists"
fi

# Create sloth service (idempotent)
SLOTH_SERVICE="/etc/systemd/system/sloth-daemon.service"
if [[ ! -f "$SLOTH_SERVICE" ]] || ! grep -q "Low Priority Task Daemon" "$SLOTH_SERVICE"; then
  echo "Creating sloth daemon service"
  sudo tee "$SLOTH_SERVICE" > /dev/null <<EOF
[Unit]
Description=Low Priority Task Daemon
After=network.target

[Service]
Type=simple
User=sloth
Group=sloth
WorkingDirectory=/home/sloth
ExecStart=/bin/bash -c 'while true; do sleep 60; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
else
  echo "Sloth daemon service already exists"
fi

# Create elephant service if elephant user was created (idempotent)
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  ELEPHANT_SERVICE="/etc/systemd/system/elephant-daemon.service"
  if [[ ! -f "$ELEPHANT_SERVICE" ]] || ! grep -q "Heavy Lift Task Daemon" "$ELEPHANT_SERVICE"; then
    echo "Creating elephant daemon service"
    sudo tee "$ELEPHANT_SERVICE" > /dev/null <<EOF
[Unit]
Description=Heavy Lift Task Daemon
After=network.target

[Service]
Type=simple
User=elephant
Group=elephant
WorkingDirectory=/home/elephant
ExecStart=/bin/bash -c 'while true; do sleep 60; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  else
    echo "Elephant daemon service already exists"
  fi
fi

# Enable and start services (idempotent)
sudo systemctl daemon-reload

# Enable services (idempotent - systemctl enable is idempotent)
sudo systemctl enable rocket-daemon.service
sudo systemctl enable sloth-daemon.service

# Start services (idempotent - systemctl start is idempotent)
sudo systemctl start rocket-daemon.service
sudo systemctl start sloth-daemon.service

if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  sudo systemctl enable elephant-daemon.service
  sudo systemctl start elephant-daemon.service
fi

echo "All daemon services enabled and started"

# Create per-user setup scripts for SSH key generation (idempotent)
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

# Install tools if missing (upgrades handled in training scripts)
echo "Installing Deno and Rust tools if missing..."
# Install Deno if missing
if ! command -v deno &> /dev/null; then
  curl -fsSL https://deno.land/install.sh | sh
  export PATH="\$HOME/.deno/bin:\$PATH"
fi

# Install Rust if missing
if ! command -v rustc &> /dev/null; then
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  export PATH="\$HOME/.cargo/bin:\$PATH"
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

# Skip VNC installation - not needed for headless ML training machines
echo "Skipping VNC installation (not needed for headless ML training)"

# Configure system settings
echo "Configuring system settings..."

# Disable password hints
sudo sed -i 's/# PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Remove unnecessary packages for ML training performance
echo "Removing unnecessary packages for maximum CPU performance"
# Remove desktop environments and GUI packages
sudo apt remove --purge -y ubuntu-desktop-minimal ubuntu-desktop xfce4* 2>/dev/null || true
# Remove backup services
sudo apt remove --purge -y deja-dup 2>/dev/null || true
# Remove development tools not needed for training
sudo apt remove --purge -y build-essential make gcc g++ 2>/dev/null || true
# Remove documentation and man pages
sudo apt remove --purge -y man-db manpages 2>/dev/null || true
# Remove text editors
sudo apt remove --purge -y nano vim-tiny 2>/dev/null || true
# Disable any remaining backup services
sudo systemctl disable --now deja-dup 2>/dev/null || true
sudo systemctl mask deja-dup 2>/dev/null || true

# Mark system as ephemeral/safe to wipe
echo "🧼 Note: This system is considered safe-to-wipe. All AI training data syncs hourly to GitHub."

# Install additional packages
if [[ -n "$(which apt-get)" ]]; then
  set +e
  # Clean up old kernel modules
  sudo dpkg --purge $(dpkg -l | grep -E 'linux-modules-[0-9]' | awk '{print $2}' | sort -V | head -n -2) 2>/dev/null || true
  sudo dpkg --purge $(dpkg -l | grep -E 'linux-modules-extra' | awk '{print $2}' | sort -V | head -n -2) 2>/dev/null || true
  sudo dpkg --purge $(dpkg -l | grep -E 'linux-image-' | awk '{print $2}' | sort -V | head -n -2) 2>/dev/null || true

  sudo apt update
  sudo apt upgrade -y
  # Install only absolutely essential packages for ML training
  sudo apt install -y git openssh-server cpufrequtils jq curl htop
  # Remove unnecessary packages that might have been installed
  echo "Removing unnecessary packages for pure ML training machine..."
  sudo apt remove --purge -y rustc cargo rustup 2>/dev/null || true
  sudo apt remove --purge -y build-essential make gcc g++ 2>/dev/null || true
  sudo apt remove --purge -y man-db manpages 2>/dev/null || true
  sudo apt remove --purge -y nano vim-tiny 2>/dev/null || true
  sudo apt remove --purge -y ubuntu-desktop-minimal ubuntu-desktop xfce4* 2>/dev/null || true
  sudo apt remove --purge -y deja-dup 2>/dev/null || true
  sudo apt remove --purge -y snapd 2>/dev/null || true
  sudo apt remove --purge -y bluetooth 2>/dev/null || true
  sudo apt remove --purge -y cups 2>/dev/null || true
  sudo apt remove --purge -y ModemManager 2>/dev/null || true
  
  # Remove any system-level Deno and Rust installations
  sudo rm -rf /usr/local/bin/deno 2>/dev/null || true
  sudo rm -rf /root/.deno 2>/dev/null || true
  sudo rm -rf /root/.cargo 2>/dev/null || true
  sudo rm -rf /root/.rustup 2>/dev/null || true
  # Also remove from current user's home directory to ensure user-level only
  rm -rf ~/.deno 2>/dev/null || true
  rm -rf ~/.cargo 2>/dev/null || true
  rm -rf ~/.rustup 2>/dev/null || true
  echo "Removed unnecessary packages and system-level installations"
  sudo apt autoremove --purge -y
fi

# Install Deno and Rust for each user (user-level installation)
echo "Installing Deno and Rust for each user..."

# Function to install tools for a specific user
install_user_tools() {
  local USERNAME=$1
  local USER_HOME="/home/$USERNAME"
  
  echo "Installing tools for $USERNAME user..."
  
  # Install Deno for this user
  if [[ ! -d "$USER_HOME/.deno/bin" ]]; then
    sudo -u $USERNAME bash -c 'curl -fsSL https://deno.land/install.sh | sh'
    echo "Deno installed for $USERNAME user"
  else
    echo "Deno already installed for $USERNAME user"
  fi
  
  # Install Rust for this user
  if ! sudo -u $USERNAME bash -c 'command -v rustc &> /dev/null'; then
    sudo -u $USERNAME bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
    echo "Rust installed for $USERNAME user"
  else
    echo "Rust already installed for $USERNAME user"
  fi
  
  # Configure PATH for this user
  local BASHRC="$USER_HOME/.bashrc"
  
  # Add Deno and Rust to PATH if not already present
  if ! sudo -u $USERNAME grep -q "export PATH.*\.deno/bin" "$BASHRC" 2>/dev/null; then
    echo 'export PATH="$HOME/.deno/bin:$PATH"' | sudo -u $USERNAME tee -a "$BASHRC" > /dev/null
  fi
  
  if ! sudo -u $USERNAME grep -q "export PATH.*\.cargo/bin" "$BASHRC" 2>/dev/null; then
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' | sudo -u $USERNAME tee -a "$BASHRC" > /dev/null
  fi
  
  # Note: Tool upgrades are handled in the user's training scripts
  
  echo "Tools configured for $USERNAME"
}

# Install tools for each user
install_user_tools "rocket"
install_user_tools "sloth"

if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  install_user_tools "elephant"
fi

# Set timezone
sudo timedatectl set-timezone Australia/Sydney

# Install user-specific crontabs with priority settings (idempotent)
echo "Installing user-specific crontabs with priority settings"

# Create rocket user crontab (HIGHEST PRIORITY)
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

# Final setup message
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  echo "🚀 Setup complete. Now login as 'rocket', 'sloth', and 'elephant' and run '~/setup.sh' to create their SSH keys!"
else
  echo "🚀 Setup complete. Now login as 'rocket' and 'sloth' and run '~/setup.sh' to create their SSH keys!"
fi
