#!/bin/bash
set -e

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
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

# Setup network configuration - static IP on one interface, DHCP on the other
echo "Configuring network"
ETHERNET=$(networksetup -listallnetworkservices | grep -Ei 'ethernet|lan' | sed 's/^\*//;s/^ //' | head -n1 || true)
WIFI=$(networksetup -listallnetworkservices | grep -Ei 'wi[- ]?fi|airport' | sed 's/^\*//;s/^ //' | head -n1 || true)

# Determine which interface to use for static IP (prefer Ethernet, fallback to Wi-Fi for MacBook Airs)
STATIC_INTERFACE=""
DHCP_INTERFACE=""

if [[ -n "$ETHERNET" ]]; then
  STATIC_INTERFACE="$ETHERNET"
  DHCP_INTERFACE="$WIFI"
  echo "🔧 Using Ethernet ($ETHERNET) for static IP, Wi-Fi ($WIFI) for DHCP"
elif [[ -n "$WIFI" ]]; then
  STATIC_INTERFACE="$WIFI"
  DHCP_INTERFACE=""
  echo "🔧 Using Wi-Fi ($WIFI) for static IP (MacBook Air or no Ethernet found)"
else
  echo "⚠️ No network interfaces found — skipping network configuration."
fi

# Configure static IP on the chosen interface
if [[ -n "$STATIC_INTERFACE" ]]; then
  echo "🔧 Configuring static IP on $STATIC_INTERFACE to ${IP_ADDRESS}"
  sudo networksetup -setmanual "$STATIC_INTERFACE" "${IP_ADDRESS}" 255.255.255.0 10.0.0.1
  sudo networksetup -setdnsservers "$STATIC_INTERFACE" 8.8.8.8 8.8.4.4
fi

# Configure DHCP on the other interface
if [[ -n "$DHCP_INTERFACE" ]]; then
  echo "🔧 Configuring DHCP on $DHCP_INTERFACE"
  sudo networksetup -setdhcp "$DHCP_INTERFACE"
  sudo networksetup -setdnsservers "$DHCP_INTERFACE" empty
fi

# Set interface priority (static IP interface first)
ALL_SERVICES=$(networksetup -listallnetworkservices | sed 's/^\*//;s/^ //' | grep -v '^An asterisk')
REMAINING_SERVICES=$(echo "$ALL_SERVICES" | grep -vxF -e "$ETHERNET" -e "$WIFI")

# Build service order array, prioritizing the static IP interface
NEW_SERVICE_ORDER=()
[[ -n "$STATIC_INTERFACE" ]] && NEW_SERVICE_ORDER+=("$STATIC_INTERFACE")
[[ -n "$DHCP_INTERFACE" ]] && NEW_SERVICE_ORDER+=("$DHCP_INTERFACE")
while IFS= read -r service; do
  [[ -n "$service" ]] && NEW_SERVICE_ORDER+=("$service")
done <<< "$REMAINING_SERVICES"

# Only reorder if we have services to order
if [[ ${#NEW_SERVICE_ORDER[@]} -gt 0 ]]; then
  sudo networksetup -ordernetworkservices "${NEW_SERVICE_ORDER[@]}"
else
  echo "⚠️ No network services found to reorder."
fi

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

# Configure core dumps - limit to one core dump to save disk space
echo "Configuring core dumps"
sudo sysctl -w kern.corefile=/cores/core.%P
sudo sysctl -w kern.coredump=1

# Create cores directory if it doesn't exist
sudo mkdir -p /cores
sudo chmod 755 /cores

# Clean up old core dumps (keep only the most recent one)
if [[ -d /cores ]]; then
  echo "Cleaning up old core dumps"
  sudo find /cores -name "core.*" -type f -delete 2>/dev/null || true
fi

# Ensure jq is available for subsequent provisioning steps
ensure_jq_available() {
  if command -v jq >/dev/null 2>&1; then
    echo "jq already present."
    return
  fi

  echo "Installing jq for all users..."

  if command -v brew >/dev/null 2>&1; then
    if ! brew list jq >/dev/null 2>&1; then
      brew install jq
    fi
  fi

  if command -v jq >/dev/null 2>&1; then
    echo "jq installed via Homebrew."
    return
  fi

  local ARCH
  local JQ_URL=""
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64)
      JQ_URL="https://github.com/stedolan/jq/releases/download/jq-1.7.1/jq-macos-arm64"
      ;;
    x86_64)
      JQ_URL="https://github.com/stedolan/jq/releases/download/jq-1.7.1/jq-macos-amd64"
      ;;
    *)
      echo "Unsupported architecture ${ARCH} for automatic jq installation."
      return 1
      ;;
  esac

  local TMP_FILE
  TMP_FILE="$(mktemp)"
  curl -fsSL "${JQ_URL}" -o "${TMP_FILE}"
  sudo mkdir -p /usr/local/bin
  sudo install -m 0755 "${TMP_FILE}" /usr/local/bin/jq
  rm -f "${TMP_FILE}"

  if command -v jq >/dev/null 2>&1; then
    echo "jq installed via direct download."
  else
    echo "Failed to install jq automatically. Please install jq manually before continuing."
    exit 1
  fi
}

ensure_jq_available

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

# Install Rust toolchain if absent
if ! command -v rustc >/dev/null 2>&1; then
  echo "Installing Rust toolchain for \$USERNAME..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
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

  sudo chmod +x /Users/$USERNAME/setup.sh
  sudo chown $USERNAME:staff /Users/$USERNAME/setup.sh
}

create_user_setup_script "rocket"
create_user_setup_script "sloth"

# 1. Enable Remote Management (Screen Sharing)
echo "Enabling Screen Sharing..."
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -clientopts -setvnclegacy -vnclegacy yes \
  -restart -agent -privs -all

# 2. Prevent iCloud syncing and Messages integration (partial CLI automation)
echo "Limiting Apple ID integrations — Please ensure the following are OFF:"
echo "- Messages"
echo "- FaceTime"
echo "- iCloud Drive sync"
echo "- Handoff & Continuity"
echo "Run System Preferences manually and disable where required."

# 3. Suppress system crash dialogs
sudo defaults write /Library/Preferences/com.apple.CrashReporter DialogType none

# 4. Disable password hints
sudo defaults write /Library/Preferences/com.apple.loginwindow RetriesUntilHint -int 0

# 5. Disable automatic Time Machine prompts
sudo defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true

# 6. Mark system as ephemeral/safe to wipe
echo "🧼 Note: This system is considered safe-to-wipe. All AI training data syncs hourly to GitHub."

echo "🚀 Setup complete. Now login as 'rocket' and 'sloth' and run '~/setup.sh' to create their SSH keys!"
# 
