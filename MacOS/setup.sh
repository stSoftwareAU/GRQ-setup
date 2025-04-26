#!/bin/bash
set -e

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${BASE_DIR}"

# Validate arguments
if [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: $0 <node_number> <automated_password>"
  exit 1
fi

NODE_NUMBER="$1"
AUTOMATED_PASSWORD="$2"
HOSTNAME="GRQ-${NODE_NUMBER}"
IP_ADDRESS="10.0.0.${NODE_NUMBER}"
CURRENT_USER=$(whoami)

# Set hostname
echo "Setting hostname to ${HOSTNAME}"
sudo scutil --set HostName "${HOSTNAME}"
sudo scutil --set LocalHostName "${HOSTNAME}"
sudo scutil --set ComputerName "${HOSTNAME}"
dscacheutil -flushcache

# Setup static IP on Ethernet
echo "Configuring network"
ETHERNET=$(networksetup -listallnetworkservices | grep -Ei 'ethernet|lan' | head -n1 | sed 's/^\*//;s/^ //')
WIFI=$(networksetup -listallnetworkservices | grep -Ei 'wi-?fi|airport' | head -n1 | sed 's/^\*//;s/^ //')

if [[ -z "$ETHERNET" || -z "$WIFI" ]]; then
  echo "Error detecting interfaces. Ethernet='$ETHERNET', Wi-Fi='$WIFI'"
  networksetup -listallnetworkservices
  exit 1
fi

sudo networksetup -setmanual "$ETHERNET" "${IP_ADDRESS}" 255.255.255.0 10.0.0.1
sudo networksetup -setdnsservers "$ETHERNET" 8.8.8.8 8.8.4.4

# Set Ethernet priority over Wi-Fi
ALL_SERVICES=$(networksetup -listallnetworkservices | sed 's/^\*//;s/^ //' | grep -v '^An asterisk')
REMAINING_SERVICES=$(echo "$ALL_SERVICES" | grep -vxF -e "$ETHERNET" -e "$WIFI")

NEW_SERVICE_ORDER=("$ETHERNET" "$WIFI")
while IFS= read -r service; do
  [[ -n "$service" ]] && NEW_SERVICE_ORDER+=("$service")
done <<< "$REMAINING_SERVICES"

sudo networksetup -ordernetworkservices "${NEW_SERVICE_ORDER[@]}"

# Auto-restart on freeze
sudo systemsetup -setrestartfreeze on
sudo pmset -a autorestart 1

# Enable automatic updates
echo "Enabling automatic updates"
sudo softwareupdate --schedule on
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool TRUE
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool TRUE
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool TRUE
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool TRUE

# Disable sleep and low power modes
sudo pmset -a sleep 0 disksleep 0 displaysleep 0 powernap 0 lowpowermode 0

# Create automated users rocket and sloth
create_automated_user() {
  local USERNAME=$1
  local FULLNAME=$2

  if ! id -u "$USERNAME" &>/dev/null; then
    echo "Creating user $USERNAME"
    sudo sysadminctl -addUser "$USERNAME" -fullName "$FULLNAME" -password "$AUTOMATED_PASSWORD" -home "/Users/$USERNAME" -adminUser "$CURRENT_USER"
    sudo createhomedir -c -u "$USERNAME"
  else
    echo "User $USERNAME already exists."
  fi

  sudo -u $USERNAME mkdir -p /Users/$USERNAME/logs
}

create_automated_user "rocket" "High performance Automated User"
create_automated_user "sloth" "Low priority Automated User"

# Install and bootstrap Rocket Daemon
echo "Installing Rocket Daemon"
sudo cp rocket-daemon.plist /Library/LaunchDaemons/com.lecklogic.highprioritytask.plist
sudo chown root:wheel /Library/LaunchDaemons/com.lecklogic.highprioritytask.plist
sudo chmod 644 /Library/LaunchDaemons/com.lecklogic.highprioritytask.plist
sudo launchctl bootout system /Library/LaunchDaemons/com.lecklogic.highprioritytask.plist || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.lecklogic.highprioritytask.plist

# Install and bootstrap Sloth Daemon
echo "Installing Sloth Daemon"
sudo cp sloth-daemon.plist /Library/LaunchDaemons/com.lecklogic.lowprioritytask.plist
sudo chown root:wheel /Library/LaunchDaemons/com.lecklogic.lowprioritytask.plist
sudo chmod 644 /Library/LaunchDaemons/com.lecklogic.lowprioritytask.plist
sudo launchctl bootout system /Library/LaunchDaemons/com.lecklogic.lowprioritytask.plist || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.lecklogic.lowprioritytask.plist

# Create per-user setup scripts for SSH key generation
create_user_setup_script() {
  local USERNAME=$1

  sudo tee /Users/$USERNAME/setup.sh > /dev/null <<EOF
#!/bin/bash
set -ex

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

git config --global user.email "\${USERNAME}-\${NODE_NUMBER}@lecklogic.com"
git config --global user.name "\${USERNAME} \${NODE_NUMBER}"

echo "Create GitHub ssh key..." 
cat ~/.ssh/id_ed25519.pub
read -p "Press enter to continue"
GRQ/worker/upgrade.sh
EOF

  sudo chmod +x /Users/$USERNAME/setup.sh
  sudo chown $USERNAME:staff /Users/$USERNAME/setup.sh
}

create_user_setup_script "rocket"
create_user_setup_script "sloth"

echo "🚀 Setup complete. Now login as 'rocket' and 'sloth' and run '~/setup.sh' to create their SSH keys!"
