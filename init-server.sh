#!/bin/bash

CS2_DIR="/cs2-data"
GAME_DIR="$CS2_DIR/game/csgo"
STEAMCMD_DIR="/home/steam/Steam"

if [ "$(id -u)" -eq 0 ]; then
  echo "Container started as root. Applying PUID/PGID and dropping privileges..."
  
  PUID=${PUID:-1000}
  PGID=${PGID:-1000}
  
  groupmod -o -g "$PGID" steam
  usermod -o -u "$PUID" steam
  
  mkdir -p /cs2-data /home/steam/.fex-emu
  chown -R steam:steam /cs2-data /home/steam
  
  exec gosu steam "$0" "$@"
fi

# downloading fex and setting it up for usage
setup_fex() {
  echo "Setting up FEX"
  rm -f /tmp/*FEXServer.Socket*

  if [ ! -d "/home/steam/.fex-emu/RootFS/Ubuntu_22_04" ]; then
    echo "RootFS not found, grabbing Ubuntu 22.04 RootFS"
    mkdir -p /home/steam/.fex-emu/RootFS
    rm -f /home/steam/.fex-emu/RootFS/*.sqsh

    ROOTFS_URL=$(curl -s https://rootfs.fex-emu.gg/RootFS_links.json | jq -r '.v1["Ubuntu 22.04 (SquashFS)"].URL')

    if [ "$ROOTFS_URL" == "null" ] || [ -z "$ROOTFS_URL" ]; then
      echo "ERROR: Could not locate the URL for Ubuntu 22.04 (SquashFS)"
      exit 1
    fi

    # download rootfs
    echo "Downloading and extracting RootFS from: $ROOTFS_URL"
    curl -L "$ROOTFS_URL" -o /home/steam/.fex-emu/RootFS/Ubuntu_22_04.sqsh

    # extract rootfs
    unsquashfs -f -d /home/steam/.fex-emu/RootFS/Ubuntu_22_04 /home/steam/.fex-emu/RootFS/Ubuntu_22_04.sqsh

    # remove sqsh file
    rm /home/steam/.fex-emu/RootFS/Ubuntu_22_04.sqsh
  else
    echo "FEX RootFS found. Skipping installation"
  fi
}

#steamcmd initialization
setup_steamcmd() {
  echo "Initializing SteamCMD"
  cd "$STEAMCMD_DIR" || exit 1

  FEXBash './steamcmd.sh +quit'


}

main() {
  setup_fex
}

main



# function installServer() {
#   # Add '-beta experimental' before 'validate' if you want to play on the experimental branch (check if CSS has updated the branch first!!!)
#   FEXBash './steamcmd.sh +@sSteamCmdForcePlatformBitness 64 +force_install_dir "/cs2-data" +login anonymous +app_update 730 validate +quit'
# }

# # LAST URL UPDATE: 1/23/2026
# function installModding() {
#   # leave as is until something breaks, idk if i should make it grab latest releases tho
#   MMS_URL="https://mms.alliedmods.net/mmsdrop/2.0/mmsource-2.0.0-git1383-linux.tar.gz"
#   CSS_URL="https://github.com/roflmuffin/CounterStrikeSharp/releases/download/v1.0.359/counterstrikesharp-with-runtime-linux-1.0.359.zip"

#   if [ ! -f "/cs2-data/game/csgo/addons/metamod.vdf" ]; then
#     echo "Downloading Metamod"
#     mkdir -p /cs2-data/game/csgo/addons
#     curl -L "$MMS_URL" | tar zx -C /cs2-data/game/csgo/
#   else
#     echo "Metamod found, skipping download."
#   fi

#   if [ ! -f "/cs2-data/game/csgo/addons/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so" ]; then
#     echo "Downloading CounterStrikeSharp"
#     curl -L "$CSS_URL" -o /tmp/css.zip
#     unzip -o -q /tmp/css.zip -d /cs2-data/game/csgo/
#     rm /tmp/css.zip
#   else
#     echo "CounterStrikeSharp found, skipping download."
#   fi

#   if grep -q "Game_LowViolence" "/cs2-data/game/csgo/gameinfo.gi"; then
#     if ! grep -q "addons/metamod" "/cs2-data/game/csgo/gameinfo.gi"; then
#       echo "Patching gameinfo.gi"
#       # lol idk if i should keep this or find a different way
#       sed -i '/Game_LowViolence/a \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ Game\tcsgo/addons/metamod' "/cs2-data/game/csgo/gameinfo.gi"
#     fi
#   else
#     echo "Cannot find Game_LowViolence"
#   fi
# }

# function main() {
#   rm -f /tmp/*FEXServer.Socket*

#   if [ ! -d "/home/steam/.fex-emu/RootFS/Ubuntu_22_04" ]; then
#     echo "RootFS not found. Cleaning RootFS and running FEXRootFSFetcher."
#     mkdir -p /home/steam/.fex-emu/RootFS

#     # Clean up potential stale/corrupted downloads
#     rm -f /home/steam/.fex-emu/RootFS/*.sqsh

#     echo "9" | FEXRootFSFetcher -y -x # should be ubuntu 22.04
#   else
#     echo "FEX RootFS detected. Skipping download."
#   fi

#   # Fix for steamclient.so not being found
#   mkdir -p /home/steam/.steam/sdk64
#   ln -sfn /home/steam/Steam/linux64/steamclient.so /home/steam/.steam/sdk64/steamclient.so

#   cd /home/steam/Steam

#   # Check if we have proper read/write permissions to /cs2-data
#   if [ ! -r "/cs2-data" ] || [ ! -w "/cs2-data" ]; then
#     echo 'ERROR: I do not have read/write permissions to /cs2-data! Please run "sudo chown -R 1000:1000 cs2-data/" on host machine, then try again.'
#     exit 1
#   fi

#   # FEX cache system doesn't work right now, maybe enabled in future
#   # same permission check for ~/.cache
#   #if [ ! -r "/home/steam/.cache/fex-emu" ] || [ ! -w "/home/steam/.cache/fex-emu" ]; then
#   #  echo 'ERROR: I do not have read/write permissions to ~/.cache/fex-emu! Please run "sudo chown -R 1000:1000 fex-cache/" on host machine, then try again.'
#   #  #exit 1
#   #fi

#   # legacy, replaced by RootFS check above
#   # same permission check for ~/.local/share/fex-emu/Config.json
#   #if [ ! -r "/home/steam/.fex-emu/Config.json" ]; then
#   #  echo 'WARNING: I cannot read ~/.fex-emu/Config.json! Please run "sudo chown -R 1000:1000 fex-config/" on host machine.'
#   #fi

#   # Check for SteamCMD updates
#   echo 'Checking for SteamCMD updates...'
#   FEXBash './steamcmd.sh +quit'

#   # Check if the server is installed
#   if [ ! -f "/cs2-data/game/bin/linuxsteamrt64/cs2" ]; then
#     echo 'Server not found! Installing...'
#     installServer
#   fi

#   # If auto updates are enabled, try updating
#   if [ "$ALWAYS_UPDATE_ON_START" == "true" ]; then
#     echo 'Checking for updates...'
#     installServer
#   fi

#   if [ "$INSTALL_MODDING" == "true" ]; then
#     echo 'Installing mods...'
#     installModding
#   fi

#   echo 'Starting server...'

#   cd /cs2-data
#   # fix for cs2 not able to find linuxsteamrt64
#   export LD_LIBRARY_PATH="/cs2-data/game/bin/linuxsteamrt64:$LD_LIBRARY_PATH"

#   # priority leak fix
#   pkill -9 FEXServer || true
#   # Start server
#   export CORES=$CPU_CORE_COUNT

#   # nice makes the server of high importance, higher is more important and lower is less important
#   # taskset dedicates specific cores to the emulator, else the docker container will default to using all cores
#   if [ -z "$STEAM_GAMESERVER_API" ]; then
#     echo "WARNING: STEAM_GAMESERVER_API is empty!"
#     exec nice -n -10 taskset -c 0-$((CORES-1)) FEXBash "./game/bin/linuxsteamrt64/cs2 -dedicated -usercon -threads $((CORES)) $EXTRA_PARAMS"
#   else
#     echo "Starting server with all features..."
#     exec nice -n -10 taskset -c 0-$((CORES-1)) FEXBash "./game/bin/linuxsteamrt64/cs2 -dedicated -usercon +sv_setsteamaccount $STEAM_GAMESERVER_API -threads $((CORES)) $EXTRA_PARAMS"
#   fi
# }

# main
