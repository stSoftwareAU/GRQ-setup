# GRQ-setup
1. [Create SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
2. ssh-copy-id nigel@10.0.0.11
3. mkdir ~/src && cd ~/src
4. git clone git@github.com:stSoftwareAU/GRQ-setup.git
5. GRQ-setup/MacOS/setup.sh XX
6. git clone git@github.com:stSoftwareAU/GRQ.git
7. vi GRQ/.option.txt
8. GRQ/worker/upgrade.sh
  
# GRQ-setup for Mac Mini Cluster Nodes

## 🚀 Automated Setup

Run the primary setup script with your node number:

```bash
./setup.sh 21
```
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

![image](https://github.com/user-attachments/assets/ce95f587-5478-4089-b919-f95006f2fe12)
