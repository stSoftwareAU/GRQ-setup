#!/bin/bash
set -ex
BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${BASE_DIR}"

if [[ -z "$1" ]]; then
  echo "Usage: $0 <node_number>"
  exit 1
fi

NODE_NUMBER=$1
HOSTNAME="GRQ-${NODE_NUMBER}"
IP_ADDRESS="10.0.0.${NODE_NUMBER}"
CURRENT_USER=$(whoami)

# Explicitly set timezone to Sydney/Australia
sudo systemsetup -settimezone "Australia/Sydney"

# Generate a single randomized minute (X) between 0-9
RAND_MINUTE=$(( RANDOM % 10 ))

SHUTDOWN_HOUR="1"
REBOOT_HOUR="3"
SHUTDOWN_SIGNAL="/tmp/.shutdown_pending"

# Set hostname and fixed IP address
sudo scutil --set HostName "${HOSTNAME}"
sudo scutil --set LocalHostName "${HOSTNAME}"
sudo scutil --set ComputerName "${HOSTNAME}"
dscacheutil -flushcache
sudo networksetup -setmanual "Ethernet" "${IP_ADDRESS}" 255.255.255.0 10.0.0.1
sudo networksetup -setdnsservers "Ethernet" 8.8.8.8 8.8.4.4

# Detect Ethernet and Wi-Fi network service names
echo "Detecting network interfaces..."
ETHERNET=$(networksetup -listallnetworkservices | grep -Ei 'ethernet|lan' | head -n1 | sed 's/^\*//;s/^ //')
WIFI=$(networksetup -listallnetworkservices | grep -Ei 'wi-?fi|airport' | head -n1 | sed 's/^\*//;s/^ //')

if [[ -z "$ETHERNET" || -z "$WIFI" ]]; then
  echo "Error detecting interfaces. Ethernet='$ETHERNET', Wi-Fi='$WIFI'"
  networksetup -listallnetworkservices
  exit 1
fi

echo "Detected Ethernet service: '$ETHERNET'"
echo "Detected Wi-Fi service: '$WIFI'"

# Configure Ethernet with static IP and DNS
echo "Configuring Ethernet with static IP ${IP_ADDRESS}"
sudo networksetup -setmanual "$ETHERNET" "${IP_ADDRESS}" 255.255.255.0 10.0.0.1
sudo networksetup -setdnsservers "$ETHERNET" 8.8.8.8 8.8.4.4

# Get current full list of network services, skipping any non-service lines
ALL_SERVICES=$(networksetup -listallnetworkservices | sed 's/^\*//;s/^ //' | grep -v '^An asterisk')

# Remove Ethernet and Wi-Fi from their current positions
REMAINING_SERVICES=$(echo "$ALL_SERVICES" | grep -vxF -e "$ETHERNET" -e "$WIFI")

# Reorder services: Ethernet first, Wi-Fi second, then the rest
NEW_SERVICE_ORDER=("$ETHERNET" "$WIFI")
while IFS= read -r service; do
  [[ -n "$service" ]] && NEW_SERVICE_ORDER+=("$service")
done <<< "$REMAINING_SERVICES"

# Apply new order (must quote each service)
echo "Setting network service priority: ${NEW_SERVICE_ORDER[*]}"
sudo networksetup -ordernetworkservices "${NEW_SERVICE_ORDER[@]}"

# Restart automatically after freeze/power failure
sudo systemsetup -setrestartfreeze on
sudo pmset -a autorestart 1

# Automatic updates and reboots
sudo softwareupdate --schedule on
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool TRUE
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool TRUE
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool TRUE
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool TRUE

# Enable SSH & Screen Sharing
# sudo systemsetup -setremotelogin on
sudo defaults write /var/db/launchd.db/com.apple.launchd/overrides.plist com.apple.screensharing -dict Disabled -bool false
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist

# Disable power saving and low power modes
sudo pmset -a sleep 0 disksleep 0 displaysleep 0 powernap 0 lowpowermode 0

# Schedule graceful shutdown signal every Monday at 1:3X AM (randomized minute)
(crontab -l 2>/dev/null; echo "${RAND_MINUTE} ${SHUTDOWN_HOUR} * * 1 touch ${SHUTDOWN_SIGNAL}") | crontab -

# Schedule weekly forced reboot on Monday at 3:0X AM (randomized minute)
sudo pmset repeat restart M "${REBOOT_HOUR}:0${RAND_MINUTE}:00"

# Automated user creation function
create_automated_user() {
  local USERNAME=$1
  local FULLNAME=$2
  
  if ! id -u "$USERNAME" &>/dev/null; then
    PASSWORD=$(openssl rand -base64 20)
    sudo sysadminctl -addUser "$USERNAME" -fullName "$FULLNAME" -password "$PASSWORD" -home "/Users/$USERNAME" -adminUser "$CURRENT_USER"
    sudo createhomedir -c -u "$USERNAME"
    echo "User $USERNAME created."
  else
    echo "User $USERNAME already exists."
  fi
}

# Create automated users Rocket 🚀 & Sloth 🦥
create_automated_user "rocket" "High performance Automated User"
create_automated_user "sloth" "Low priority Automated User"

# High-priority task setup (LaunchAgent)
mkdir -p ~/Library/LaunchAgents
cp plist.xml ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
sed -i '' "s|USERNAME|rocket|g" ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
launchctl load ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
