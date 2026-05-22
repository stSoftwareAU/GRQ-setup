#!/bin/bash
set -e

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "${BASE_DIR}/.." && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
cd "${BASE_DIR}"

# Supply-chain hardening (issue #16): pin every external installer to a
# specific commit SHA / version and verify SHA-256 before executing.
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/verify_installer.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/pinned_versions.sh"

# Validate arguments
if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
  echo "Usage: $0 <mode> <node_number> <automated_password> [create_elephant]"
  echo "  mode: 'local' or 'remote' - local sets static IP, remote uses DHCP"
  echo "  create_elephant: optional 'true' to create elephant user for heavy lift tasks"
  exit 1
fi

MODE="$1"
NODE_NUMBER="$2"
AUTOMATED_PASSWORD="$3"
CREATE_ELEPHANT="$4"

# Validate mode parameter
if [[ "$MODE" != "local" && "$MODE" != "remote" ]]; then
  echo "ERROR: mode must be 'local' or 'remote'"
  exit 1
fi

HOSTNAME="GRQ-${NODE_NUMBER}"
IP_ADDRESS="10.0.0.${NODE_NUMBER}"
CURRENT_USER=$(whoami)

# Set hostname
echo "Setting hostname to ${HOSTNAME}"
sudo scutil --set HostName "${HOSTNAME}"
sudo scutil --set LocalHostName "${HOSTNAME}"
sudo scutil --set ComputerName "${HOSTNAME}"
dscacheutil -flushcache

# Setup network configuration
echo "Configuring network (mode: ${MODE})"
ETHERNET=$(networksetup -listallnetworkservices | grep -Ei 'ethernet|lan' | sed 's/^\*//;s/^ //' | head -n1 || true)
WIFI=$(networksetup -listallnetworkservices | grep -Ei 'wi[- ]?fi|airport' | sed 's/^\*//;s/^ //' | head -n1 || true)

if [[ "$MODE" == "local" ]]; then
  # Local mode: static IP on one interface, DHCP on the other
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
else
  # Remote mode: use DHCP on all interfaces
  echo "🔧 Remote mode: Configuring all interfaces for DHCP"
  if [[ -n "$ETHERNET" ]]; then
    echo "🔧 Configuring DHCP on $ETHERNET"
    sudo networksetup -setdhcp "$ETHERNET"
    sudo networksetup -setdnsservers "$ETHERNET" empty
  fi
  if [[ -n "$WIFI" ]]; then
    echo "🔧 Configuring DHCP on $WIFI"
    sudo networksetup -setdhcp "$WIFI"
    sudo networksetup -setdnsservers "$WIFI" empty
  fi
  if [[ -z "$ETHERNET" && -z "$WIFI" ]]; then
    echo "⚠️ No network interfaces found — skipping network configuration."
  fi
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

# Ensure Homebrew is installed
ensure_brew_available() {
  if command -v brew >/dev/null 2>&1; then
    echo "Homebrew already present."
    return
  fi

  echo "Installing Homebrew (pinned commit ${HOMEBREW_INSTALL_SHA})..."
  local brew_installer
  brew_installer=$(mktemp -t brew-install.XXXXXX)
  if ! download_and_verify "${HOMEBREW_INSTALL_URL}" "${HOMEBREW_INSTALL_SHA256}" "${brew_installer}"; then
    echo "Refusing to install Homebrew: pinned SHA-256 verification failed." >&2
    rm -f "${brew_installer}"
    exit 1
  fi
  /bin/bash "${brew_installer}"
  rm -f "${brew_installer}"

  # Add Homebrew to PATH for current session
  if [[ -f /opt/homebrew/bin/brew ]]; then
    export PATH="/opt/homebrew/bin:${PATH}"
  elif [[ -f /usr/local/bin/brew ]]; then
    export PATH="/usr/local/bin:${PATH}"
  fi

  if command -v brew >/dev/null 2>&1; then
    echo "Homebrew installed successfully."
  else
    echo "Failed to install Homebrew. Please install Homebrew manually before continuing."
    exit 1
  fi
}

ensure_brew_available

# Ensure jq is available for subsequent provisioning steps
ensure_jq_available() {
  if command -v jq >/dev/null 2>&1; then
    echo "jq already present."
    return
  fi

  echo "Installing jq via Homebrew..."
  if ! brew list jq >/dev/null 2>&1; then
    brew install jq
  fi

  if command -v jq >/dev/null 2>&1; then
    echo "jq installed via Homebrew."
  else
    echo "Failed to install jq via Homebrew. Please install jq manually before continuing."
    exit 1
  fi
}

ensure_jq_available

# Ensure AWS CLI is available for subsequent provisioning steps
ensure_aws_cli_available() {
  if command -v aws >/dev/null 2>&1; then
    echo "AWS CLI already present."
    return
  fi

  echo "Installing AWS CLI via Homebrew..."
  if ! brew list awscli >/dev/null 2>&1; then
    brew install awscli
  fi

  if command -v aws >/dev/null 2>&1; then
    echo "AWS CLI installed via Homebrew."
  else
    echo "Failed to install AWS CLI via Homebrew. Please install AWS CLI manually before continuing."
    exit 1
  fi
}

ensure_aws_cli_available

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

# Create elephant user if requested
ELEPHANT_HOME=""
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  echo "Creating elephant user for heavy lift tasks"
  if ! id -u "elephant" &>/dev/null; then
    create_automated_user "elephant" "Heavy lift Automated User"
    ELEPHANT_HOME="/Users/elephant"
  else
    echo "User elephant already exists"
    # Get the actual home directory (may be on removable drive like /Volumes/sudo or /Volumes/GRQ/Elephant)
    ELEPHANT_HOME=$(dscl . -read /Users/elephant NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    if [[ -z "$ELEPHANT_HOME" ]]; then
      # Fallback method
      ELEPHANT_HOME=$(eval echo ~elephant)
    fi
    
    # Validate that we got a valid home directory
    if [[ -z "$ELEPHANT_HOME" ]]; then
      echo "ERROR: Could not determine elephant user's home directory"
      exit 1
    fi
    
    echo "Detected elephant home directory: $ELEPHANT_HOME"
    
    # Verify the home directory exists
    if [[ ! -d "$ELEPHANT_HOME" ]]; then
      echo "WARNING: Home directory $ELEPHANT_HOME does not exist or is not mounted"
      echo "         The daemon will be configured, but ensure the drive is mounted before use"
    fi
    
    # Update password in case it changed
    sudo sysadminctl -resetPasswordFor "elephant" -newPassword "$AUTOMATED_PASSWORD" -adminUser "$CURRENT_USER"
    # Ensure logs directory exists in the actual home directory
    sudo -u elephant mkdir -p "$ELEPHANT_HOME/logs"
  fi
fi

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

# Install and bootstrap Elephant Daemon (only if elephant user exists)
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  # If ELEPHANT_HOME is not set, get it (should be set above, but fallback just in case)
  if [[ -z "$ELEPHANT_HOME" ]]; then
    if id -u "elephant" &>/dev/null; then
      ELEPHANT_HOME=$(dscl . -read /Users/elephant NFSHomeDirectory 2>/dev/null | awk '{print $2}')
      if [[ -z "$ELEPHANT_HOME" ]]; then
        ELEPHANT_HOME=$(eval echo ~elephant)
      fi
    else
      ELEPHANT_HOME="/Users/elephant"
    fi
  fi
  
  # Validate ELEPHANT_HOME is set
  if [[ -z "$ELEPHANT_HOME" ]]; then
    echo "ERROR: ELEPHANT_HOME is not set. Cannot install daemon."
    exit 1
  fi
  
  echo ""
  echo "Installing Elephant Daemon..."
  echo "Using detected home directory: $ELEPHANT_HOME"
  
  # Generate daemon plist with actual home directory paths (supports removable drives)
  sudo tee /Library/LaunchDaemons/com.lecklogic.heavylifttask.plist > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lecklogic.heavylifttask</string>
    <key>ProgramArguments</key>
    <array>
        <string>${ELEPHANT_HOME}/GRQ/elephant.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>Nice</key>
    <integer>20</integer> <!-- Low CPU priority for heavy disk I/O tasks -->
    <key>UserName</key>
    <string>elephant</string>
    <key>WorkingDirectory</key>
    <string>${ELEPHANT_HOME}</string>
    <key>StandardOutPath</key>
    <string>${ELEPHANT_HOME}/logs/elephant.out.log</string>
    <key>StandardErrorPath</key>
    <string>${ELEPHANT_HOME}/logs/elephant.err.log</string>
</dict>
</plist>
EOF
  
  sudo chown root:wheel /Library/LaunchDaemons/com.lecklogic.heavylifttask.plist
  sudo chmod 644 /Library/LaunchDaemons/com.lecklogic.heavylifttask.plist
  sudo launchctl bootout system /Library/LaunchDaemons/com.lecklogic.heavylifttask.plist || true
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.lecklogic.heavylifttask.plist
  echo "Elephant daemon installed and started with paths pointing to $ELEPHANT_HOME"
fi

# Create per-user setup scripts for SSH key generation
create_user_setup_script() {
  local USERNAME=$1
  local USER_HOME=${2:-/Users/$USERNAME}

  # Ensure the home directory exists (important for removable drives)
  if [[ ! -d "$USER_HOME" ]]; then
    echo "WARNING: Home directory $USER_HOME does not exist. Attempting to create it..."
    sudo mkdir -p "$USER_HOME"
    sudo chown $USERNAME:staff "$USER_HOME"
  fi

  echo "Creating setup script for $USERNAME at $USER_HOME/setup.sh"
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
  sudo chown $USERNAME:staff "$USER_HOME/setup.sh"
  echo "Setup script created for $USERNAME at $USER_HOME/setup.sh"
}

create_user_setup_script "rocket"
create_user_setup_script "sloth"

if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  # Use detected home directory for elephant (may be on removable drive)
  # ELEPHANT_HOME should already be set above, but verify it's set here
  if [[ -z "$ELEPHANT_HOME" ]]; then
    echo "ELEPHANT_HOME not set, detecting elephant user's home directory..."
    if id -u "elephant" &>/dev/null; then
      ELEPHANT_HOME=$(dscl . -read /Users/elephant NFSHomeDirectory 2>/dev/null | awk '{print $2}')
      if [[ -z "$ELEPHANT_HOME" ]]; then
        ELEPHANT_HOME=$(eval echo ~elephant)
      fi
    else
      ELEPHANT_HOME="/Users/elephant"
    fi
  fi
  
  # Validate ELEPHANT_HOME is set
  if [[ -z "$ELEPHANT_HOME" ]]; then
    echo "ERROR: Could not determine elephant user's home directory for setup script"
    exit 1
  fi
  
  echo "Creating setup script for elephant at: $ELEPHANT_HOME/setup.sh"
  create_user_setup_script "elephant" "$ELEPHANT_HOME"
  
  # Verify the setup script was created in the correct location
  if [[ -f "$ELEPHANT_HOME/setup.sh" ]]; then
    echo "✅ Verified: Setup script created at $ELEPHANT_HOME/setup.sh"
  else
    echo "❌ ERROR: Setup script was not created at $ELEPHANT_HOME/setup.sh"
    echo "   Please check that the home directory exists and is writable"
    exit 1
  fi
fi

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

# Final setup message
if [[ "$CREATE_ELEPHANT" == "true" ]]; then
  echo "🚀 Setup complete. Now login as 'rocket', 'sloth', and 'elephant' and run '~/setup.sh' to create their SSH keys!"
else
  echo "🚀 Setup complete. Now login as 'rocket' and 'sloth' and run '~/setup.sh' to create their SSH keys!"
fi 
