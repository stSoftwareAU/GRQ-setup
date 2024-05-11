#!/bin/bash
set -ex
BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${BASE_DIR}"

mkdir -p ~/Library/LaunchAgents

if [ -f ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist ]; then
  launchctl unload ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
fi

cp plist.xml ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
CURRENT_USER=$(whoami)
sed -i '' "s|USERNAME|$CURRENT_USER|g" ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist

launchctl load ~/Library/LaunchAgents/com.lecklogic.highprioritytask.plist
