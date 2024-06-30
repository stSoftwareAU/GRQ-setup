#!/bin/bash
set -e
BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${BASE_DIR}"

if [[ $EUID -eq 0 ]]; then
  echo "Don't run this as root!"
  exit 1
fi

crontab < crontab.txt
if [[ -n "$(which apt-get)" ]]; then
  set +e
  # sudo dpkg --purge ` dpkg -l | grep 'linux-modules-5'|cut -c 5-45| xargs`
  sudo dpkg --purge $(dpkg -l | grep -E 'linux-modules-[0-9]' | awk '{print $2}' | sort -V | head -n -2)
  sudo dpkg --purge $(dpkg -l | grep -E 'linux-modules-extra' | awk '{print $2}' | sort -V | head -n -2)
  sudo dpkg --purge $(dpkg -l | grep -E 'linux-image-' | awk '{print $2}' | sort -V | head -n -2)

  sudo apt update
  sudo apt upgrade -y
  sudo apt install -y jq curl zip
  sudo apt autoremove --purge -y
fi
if [[ ! -d ~/.deno/bin ]]; then
   curl -fsSL https://deno.land/install.sh | sh
fi
