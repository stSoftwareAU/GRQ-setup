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

# Set timezone
echo "Setting timezone to Australia/Sydney"
sudo ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime

# Set hostname
sudo scutil --set HostName "${HOSTNAME}"
sudo scutil --set LocalHostName "${HOSTNAME}"
sudo scutil --set ComputerName "${HOSTNAME}"
dscacheutil -flushcache

# Setup static IP on Ethernet
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

# Auto-restart
sudo systemsetup -setrestartfreeze on
sudo pmset -a autorestart 1

# Auto-updates
sudo softwareupdate --schedule on
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool TRUE
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool TRUE
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool TRUE
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool TRUE

# Disable low power modes
sudo pmset -a sleep 0 disksleep 0 displaysleep 0 powernap 0 lowpowermode 0

# Create users rocket and sloth
create_automated_user() {
  local USERNAME=$1
  local FULLNAME=$2

  if ! id -u "$USERNAME" &>/dev/null; then
    sudo sysadminctl -addUser "$USERNAME" -fullName "$FULLNAME" -password "$AUTOMATED_PASSWORD" -home "/Users/$USERNAME" -adminUser "$CURRENT_USER"
    sudo createhomedir -c -u "$USERNAME"
    echo "User $USERNAME created."
  else
    echo "User $USERNAME already exists."
  fi
}

create_automated_user "rocket" "High performance Automated User"
create_automated_user "sloth" "Low priority Automated User"

# Create LaunchAgents
sudo -u rocket mkdir -p /Users/rocket/Library/LaunchAgents
sudo cp rocket.plist /Users/rocket/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
sudo chown rocket:staff /Users/rocket/Library/LaunchAgents/com.lecklogic.highprioritytask.plist

sudo -u sloth mkdir -p /Users/sloth/Library/LaunchAgents
sudo cp sloth.plist /Users/sloth/Library/LaunchAgents/com.lecklogic.lowprioritytask.plist
sudo chown sloth:staff /Users/sloth/Library/LaunchAgents/com.lecklogic.lowprioritytask.plist

# Generate per-user setup scripts
create_user_setup_script() {
  local USERNAME=$1
  local ROLE=$2  # high or low

  sudo tee /Users/$USERNAME/setup.sh > /dev/null <<EOF
#!/bin/bash
set -ex

USERNAME=\$(whoami)
NODE_NUMBER=${NODE_NUMBER}

# SSH key setup
if [[ ! -f "\$HOME/.ssh/id_ed25519" ]]; then
  echo "Generating new SSH key for \$USERNAME..."
  mkdir -p "\$HOME/.ssh"
  ssh-keygen -t ed25519 -f "\$HOME/.ssh/id_ed25519" -N "" -C "\${USERNAME}-\${NODE_NUMBER}@lecklogic.com"
fi

# Push SSH key to admin
ssh-copy-id nigel@10.0.0.11

# LaunchAgent load
if [[ "$ROLE" == "high" ]]; then
  launchctl bootstrap user/\$(id -u) "\$HOME/Library/LaunchAgents/com.lecklogic.highprioritytask.plist"
elif [[ "$ROLE" == "low" ]]; then
  launchctl bootstrap user/\$(id -u) "\$HOME/Library/LaunchAgents/com.lecklogic.lowprioritytask.plist"
fi

EOF

  sudo chmod +x /Users/$USERNAME/setup.sh
  sudo chown $USERNAME:staff /Users/$USERNAME/setup.sh
}

create_user_setup_script "rocket" "high"
create_user_setup_script "sloth" "low"

echo "🚀 Setup complete. Now login as 'rocket' and 'sloth' to complete their setups!"
