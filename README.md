# GRQ-setup
1. [Create SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
3. mkdir ~/src && cd ~/src
4. git clone git@github.com:stSoftwareAU/GRQ-setup.git
   
# Ubuntu server setup
1. sudo apt update
2. sudo apt install git
   
# GRQ-setup for Mac Mini Cluster Nodes

## 🚀 Automated Setup

Run the primary setup script with your node number:

```bash
~/GRQ-setup/MacOS/setup.sh <node_number> <automated_password> [create_elephant]
```

**Parameters:**
- `node_number`: The node number (e.g., 21)
- `automated_password`: Password for automated users (rocket, sloth, optional elephant)
- `create_elephant`: Optional 'true' to create elephant user for heavy lift tasks with large removable drives

**Examples:**
```bash
# Standard setup (rocket and sloth only)
~/GRQ-setup/MacOS/setup.sh 21 "your_password"

# Setup with elephant user for heavy disk tasks
~/GRQ-setup/MacOS/setup.sh 21 "your_password" true
```

### 👤 Adding Users to Existing Machines

If you need to add a user to an existing Mac setup (useful for users with home directories on removable drives):

```bash
~/GRQ-setup/MacOS/add-user.sh <username> <node_number> <automated_password>
```

**Parameters:**
- `username`: The username to create/add (e.g., "elephant", "worker")
- `node_number`: The node number (e.g., 21)
- `automated_password`: Password for the user

**Examples:**
```bash
# Add elephant user for heavy disk tasks
~/GRQ-setup/MacOS/add-user.sh elephant 21 "your_password"

# Add any other user
~/GRQ-setup/MacOS/add-user.sh worker 21 "your_password"
```

This script will:
- Create the user (or detect if they already exist)
- Read the user's actual home directory (supports removable drives like `/Volumes/GRQ/Username`)
- Set up the user's environment script
- Install and start a daemon that runs `<username>.sh` from the user's GRQ directory

**Note:** The daemon will run a script named after the user (e.g., `elephant.sh` for user "elephant", `worker.sh` for user "worker") from `$HOME/GRQ/`.
## 🛠 Manual Tasks (one-time setup)

After running setup.sh, you must manually enable SSH (Remote Login):

To enable SSH manually:
Open System Settings → General → Sharing.
Enable Remote Login.
If prompted, allow access for "All Users" (or restrict it to the users you prefer).
📣 Note: On macOS Ventura/Sonoma and later, enabling Remote Login requires Full Disk Access privileges for Terminal (this is Apple's security feature). This manual step ensures that SSH is enabled correctly.

![image](https://github.com/user-attachments/assets/d6b039fc-2926-4999-bfa1-e9c7e67b60e8)

![image](https://github.com/user-attachments/assets/7c7d3348-fe7b-4e77-b1be-6fb2d1729b3d)

![image](https://github.com/user-attachments/assets/373f0363-392d-4a86-9aef-6ee4c707a013)

![image](https://github.com/user-attachments/assets/a9f51f59-926d-48cf-879b-3aa4250da6e5)

![image](https://github.com/user-attachments/assets/16b3e7f2-33b8-46d4-a3e1-bd2470116a76)

![image](https://github.com/user-attachments/assets/8bf357ca-841f-46bd-a4bd-877b3d4c526b)

## Remote Management & Apple ID Precautions

Each Mac is set up using your Apple ID but does not retain any personal services like Messages, iCloud Drive, or FaceTime. These should be disabled manually after initial setup:

1. Open **System Settings > Apple ID**.
2. Sign out of Messages, FaceTime, and iCloud Drive.
3. Disable Handoff, Continuity, and Apple Watch unlock.

### Remote Access

- **Screen Sharing** is enabled and available through your Apple ID or local network.
- If a password reset is needed, machines may be wiped and re-setup using `setup.sh`.

These systems are designed to be **self-healing and ephemeral** — only syncing training data hourly.
