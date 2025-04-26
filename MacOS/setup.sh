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


# Set Ethernet priority over Wi-Fi
ETHERNET=$(networksetup -listnetworkserviceorder | grep "Hardware Port: Ethernet" | awk -F'\\) ' '{print $2}' | sed 's/,.*//')
WIFI=$(networksetup -listnetworkserviceorder | grep "Hardware Port: Wi-Fi" | awk -F'\\) ' '{print $2}' | sed 's/,.*//')
sudo networksetup -ordernetworkservices "$ETHERNET" "$WIFI"

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
sudo systemsetup -setremotelogin on
sudo defaults write /var/db/launchd.db/com.apple.launchd/overrides.plist com.apple.screensharing -dict Disabled -bool false
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist

# Disable power saving and low power modes
sudo pmset -a sleep 0 disksleep 0 displaysleep 0 powernap 0 lowpowermode 0

# Schedule graceful shutdown signal every Monday at 1:3X AM (randomized minute)
(crontab -l 2>/dev/null; echo "${RAND_MINUTE} ${SHUTDOWN_HOUR} * * 1 touch ${SHUTDOWN_SIGNAL}") | crontab -

# Schedule weekly forced reboot on Monday at 3:0X AM (randomized minute)
sudo pmset repeat restart M "${REBOOT_HOUR}:0${RAND_MINUTE}:00"

# High-priority task setup (LaunchAgent)
mkdir -p ~/Library/LaunchAgents
cp plist.xml ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
sed -i '' "s|USERNAME|$CURRENT_USER|g" ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
launchctl load ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
