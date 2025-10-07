#!/bin/bash
set -e

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

# Disable sleep and low power modes
echo "Disabling sleep and power management"
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

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
    sudo usermod -aG sudo "$USERNAME"
    echo "User $USERNAME created successfully"
  else
    echo "User $USERNAME already exists"
    # Update password in case it changed
    echo "$USERNAME:$AUTOMATED_PASSWORD" | sudo chpasswd
    echo "Password updated for $USERNAME"
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

# Install and configure VNC server (equivalent to Screen Sharing) (idempotent)
echo "Installing VNC server..."
if ! dpkg -l | grep -q tightvncserver; then
  sudo apt install -y xfce4 xfce4-goodies tightvncserver
  echo "VNC server installed"
else
  echo "VNC server already installed"
fi

# Configure VNC for rocket and sloth users (idempotent)
configure_vnc_user() {
  local USERNAME=$1
  local VNC_DIR="/home/$USERNAME/.vnc"
  local XSTARTUP_FILE="$VNC_DIR/xstartup"
  
  sudo -u $USERNAME mkdir -p "$VNC_DIR"
  
  # Check if xstartup already exists and is correct
  if [[ -f "$XSTARTUP_FILE" ]] && grep -q "startxfce4" "$XSTARTUP_FILE"; then
    echo "VNC configuration for $USERNAME already exists"
  else
    echo "Configuring VNC for $USERNAME"
    sudo -u $USERNAME tee "$XSTARTUP_FILE" > /dev/null <<EOF
#!/bin/bash
xrdb \$HOME/.Xresources
startxfce4 &
EOF
    
    sudo chmod +x "$XSTARTUP_FILE"
    sudo chown $USERNAME:$USERNAME "$XSTARTUP_FILE"
    echo "VNC configured for $USERNAME"
  fi
}

configure_vnc_user "rocket"
configure_vnc_user "sloth"

if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  configure_vnc_user "elephant"
fi

# Configure system settings
echo "Configuring system settings..."

# Disable password hints
sudo sed -i 's/# PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Disable automatic Time Machine prompts (Ubuntu equivalent - disable backup prompts)
sudo apt install -y deja-dup
sudo gsettings set org.gnome.DejaDup backend 'none'

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
  sudo apt install -y jq curl zip git openssh-server
  sudo apt autoremove --purge -y
fi

# Install Deno if not present
if [[ ! -d ~/.deno/bin ]]; then
   curl -fsSL https://deno.land/install.sh | sh
fi

# Set timezone
sudo timedatectl set-timezone Australia/Sydney

# Install crontab (idempotent)
echo "Installing crontab..."
if [[ -f "crontab.txt" ]]; then
  # Check if crontab is already installed and matches
  if crontab -l 2>/dev/null | grep -q "GRQ/run.sh" && [[ "$(crontab -l 2>/dev/null | wc -l)" -eq "$(wc -l < crontab.txt)" ]]; then
    echo "Crontab already installed and matches"
  else
    crontab < crontab.txt
    echo "Crontab installed/updated"
  fi
else
  echo "Warning: crontab.txt not found, skipping crontab installation"
fi

# Final setup message
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  echo "🚀 Setup complete. Now login as 'rocket', 'sloth', and 'elephant' and run '~/setup.sh' to create their SSH keys!"
else
  echo "🚀 Setup complete. Now login as 'rocket' and 'sloth' and run '~/setup.sh' to create their SSH keys!"
fi
