#!/bin/bash
set -e

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
cd "${BASE_DIR}"

# Validate arguments
if [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: $0 <node_number> <automated_password>"
  echo "  This script adds the elephant user to an existing Mac setup"
  exit 1
fi

NODE_NUMBER="$1"
AUTOMATED_PASSWORD="$2"
CURRENT_USER=$(whoami)

echo "🐘 Adding Elephant user to existing Mac setup..."

# Create elephant user or detect existing one
ELEPHANT_HOME=""
if ! id -u "elephant" &>/dev/null; then
  echo "Creating user elephant"
  sudo sysadminctl -addUser "elephant" -fullName "Heavy lift Automated User" -password "$AUTOMATED_PASSWORD" -home "/Users/elephant" -adminUser "$CURRENT_USER"
  sudo createhomedir -c -u "elephant"
  ELEPHANT_HOME="/Users/elephant"
  echo "User elephant created successfully"
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
  echo "Password updated for elephant"
fi

# Ensure logs directory exists in the actual home directory
sudo -u elephant mkdir -p "$ELEPHANT_HOME/logs"
echo "Logs directory ensured at $ELEPHANT_HOME/logs"

# Create per-user setup script for SSH key generation
create_user_setup_script() {
  local USERNAME=$1
  local USER_HOME=$2

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

  sudo chmod +x "$USER_HOME/setup.sh"
  sudo chown $USERNAME:staff "$USER_HOME/setup.sh"
  echo "Setup script created for $USERNAME at $USER_HOME/setup.sh"
}

create_user_setup_script "elephant" "$ELEPHANT_HOME"

# Install and bootstrap Elephant Daemon with correct home directory paths
echo ""
echo "Installing Elephant Daemon..."
echo "Using detected home directory: $ELEPHANT_HOME"

# Validate ELEPHANT_HOME is set
if [[ -z "$ELEPHANT_HOME" ]]; then
  echo "ERROR: ELEPHANT_HOME is not set. Cannot install daemon."
  exit 1
fi

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

echo ""
echo "✅ Elephant user setup complete!"
if [[ -n "$ELEPHANT_HOME" ]]; then
  echo "   - User 'elephant' home directory: $ELEPHANT_HOME"
fi
echo "   - Setup script created at $ELEPHANT_HOME/setup.sh"
echo "   - Elephant daemon installed and started (running $ELEPHANT_HOME/GRQ/elephant.sh)"
echo ""
echo "🔧 Next steps:"
echo "   1. Login as 'elephant' user"
echo "   2. Run '~/setup.sh' to create SSH keys and set up GRQ repository"
echo "   3. Ensure removable drives are mounted for large disk tasks"

