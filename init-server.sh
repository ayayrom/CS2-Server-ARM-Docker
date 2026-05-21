#!/bin/bash

CS2_DIR="/cs2-data"
GAME_DIR="$CS2_DIR/game/csgo"
STEAMCMD_DIR="/home/steam/Steam"
export FEX_ROOTFS="/home/steam/.fex-emu/RootFS/Ubuntu_22_04"

if [ "$(id -u)" -eq 0 ]; then
  echo "Container started as root. Applying PUID/PGID and dropping privileges..."
  
  PUID=${PUID:-1001}
  PGID=${PGID:-1001}
  
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

  mkdir -p /home/steam/.steam/sdk64
  ln -sfn "$STEAMCMD_DIR/linux64/steamclient.so" /home/steam/.steam/sdk64/steamclient.so
}

# helper function to update game files
update_game_files() {
  echo "Running SteamCMD update for 730 (CS2)"
  cd "$STEAMCMD_DIR" || exit 1

  rm -rf "$CS2_DIR/steamapps/downloading"
  rm -f "$STEAMCMD_DIR/appcache/appinfo.vdf"

  local max_retries=3
  local attempt=1
  
  while [ $attempt -le $max_retries ]; do
    echo "SteamCMD Update attempt $attempt of $max_retries..."
    
    # Check the exit code of SteamCMD
    if FEXBash './steamcmd.sh +@sSteamCmdForcePlatformBitness 64 +force_install_dir "/cs2-data" +login anonymous +app_update 730 validate +quit'; then
      echo "SteamCMD update successful."
      return 0
    else
      echo "WARNING: SteamCMD failed with state 0x6 or connection error. Retrying in 5s"
      rm -rf "$CS2_DIR/steamapps/downloading"
      sleep 5
      attempt=$((attempt + 1))
    fi
  done
  
  echo "ERROR: SteamCMD failed to update after $max_retries attempts. The server will attempt to boot with the existing files."
}

# makes sure the server is up to date
manage_game_server() {
  echo "Checking server files"
  export SERVER_JUST_UPDATED='false'
  local appmanifest="$CS2_DIR/steamapps/appmanifest_730.acf"
  local gameinfo_path="$GAME_DIR/gameinfo.gi"

  # checking if the game files exist
  if [ ! -f "$CS2_DIR/game/bin/linuxsteamrt64/cs2" ] || [ ! -f "$appmanifest" ] || [ ! -f "$gameinfo_path" ]; then
    echo "Server executable, appmanifest, or gameinfo.gi not found! Installing fresh server..."
    update_game_files
    export SERVER_JUST_UPDATED="true"
    return
  fi

  if [ "$ALWAYS_UPDATE_ON_START" == "true" ]; then
    echo "Querying Steam API for CS2 build ID"
    local local_build
    local_build=$(grep -Po '"buildid"\s+"\K[0-9]+' "$appmanifest")

    local remote_build
    remote_build=$(curl -s https://api.steamcmd.net/v1/info/730 | jq -r '.data["730"].depots.branches.public.buildid')

    # if the remote build cannot be found, force a check with steamcmd
    if [ -z "$remote_build" ] || [ "$remote_build" == "null" ]; then
      echo "WARNING: Failed to fetch remote Build ID. Using SteamCMD to check for updates"
      # update_game_files
      # export SERVER_JUST_UPDATED="true"
    # if the local build is different from the remote build, update
    elif [ "$local_build" != "$remote_build" ]; then
      echo "Updating: Local Build: $local_build | Remote Build: $remote_build"

      patch_gameinfo "remove"
      pkill -9 FEXServer || true
      rm -f /tmp/*FEXServer.Socket*

      update_game_files
      export SERVER_JUST_UPDATED="true"
    else
      echo "Server is up to date: $local_build"
    fi
  fi
}

# patch the gameinfo file for either installation or removal of metamod
patch_gameinfo() {
  local action=$1 # arg for "install" or "remove"
  local gameinfo_path="$GAME_DIR/gameinfo.gi"

  if [ -f "$gameinfo_path" ]; then
    if [ "$action" == "install" ] && ! grep -q "addons/metamod" "$gameinfo_path"; then
      echo "Patching gameinfo.gi for Metamod"
      sed -i '/Game_LowViolence/a \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ Game\tcsgo/addons/metamod' "$gameinfo_path"
    elif [ "$action" == "remove" ] && grep -q "addons/metamod" "$gameinfo_path"; then
      echo "Removing Metamod hook from gameinfo.gi"
      sed -i '/addons\/metamod/d' "$gameinfo_path"
    fi
  fi
}

enable_mods() {
  echo "Enabling mods"
  
  fetch_mod_versions
  
  install_and_update_mods
}

# disables modding on the server and reverts to vanilla state
disable_mods() {
  echo "Disabling mods and reverting server to vanilla"
  if [ -d "$CSS_DIR" ] || [ -d "$MMS_DIR" ]; then
    echo "Found mods, creating backup"
    local backup_dir
    backup_dir="/cs2-data/mod_backups/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir/counterstrikesharp" "$backup_dir/metamod"

    # backup CounterStrikeSharp
    [ -d "$CSS_DIR/plugins" ] && cp -r "$CSS_DIR/plugins" "$backup_dir/counterstrikesharp/"
    [ -d "$CSS_DIR/configs" ] && cp -r "$CSS_DIR/configs" "$backup_dir/counterstrikesharp/"

    # backup metamod
    if [ -d "$MMS_DIR" ]; then
      for item in "$MMS_DIR"/*; do
        if [ -e "$item" ] && [ "$(basename "$item")" != "bin" ]; then
          cp -r "$item" "$backup_dir/metamod/"
        fi
      done
    fi

    echo "Backup saved to $backup_dir"
    echo "Wiping mod files from server"
    rm -rf "$CSS_DIR" "$MMS_DIR"
    rm -f "$GAME_DIR/addons/metamod.vdf"
  else
    echo "No mods detected, skipping removal"
  fi

  patch_gameinfo "remove"
  echo "Server is now vanilla"
}

# fetches remote versions and url for comparison later
fetch_mod_versions() {
  echo "Fetching remote version info"

  if [ -z "$MMS_CUSTOM_URL" ]; then
    echo "Querying GitHub API for latest Metamod pre-release..."
    # Fetch the full releases array from GitHub
    local mms_api_response
    mms_api_response=$(curl -s https://api.github.com/repos/alliedmodders/metamod-source/releases)
    
    # forcing prereleases (only dev builds are compatible)
    MMS_LATEST_FILE=$(echo "$mms_api_response" | jq -r 'map(select(.prerelease == true)) | .[0].tag_name')
    
    MMS_TARGET_URL=$(echo "$mms_api_response" | jq -r 'map(select(.prerelease == true)) | .[0].assets[] | select(.name | contains("linux") and endswith(".tar.gz")) | .browser_download_url')

    if [ "$MMS_TARGET_URL" == "null" ] || [ -z "$MMS_TARGET_URL" ]; then
       echo "ERROR: Failed to fetch MMS from GitHub API. You might be rate-limited by GitHub."
    fi
  else
    MMS_LATEST_FILE="custom-url-defined"
    MMS_TARGET_URL="$MMS_CUSTOM_URL"
  fi

  if [ -z "$CSS_CUSTOM_URL" ]; then
    CSS_LATEST_TAG=$(curl -s https://api.github.com/repos/roflmuffin/CounterStrikeSharp/releases/latest | jq -r '.tag_name')
    CSS_TARGET_URL=$(curl -s "https://api.github.com/repos/roflmuffin/CounterStrikeSharp/releases/tags/$CSS_LATEST_TAG" | jq -r '.assets[] | select(.name | startswith("counterstrikesharp-with-runtime-linux")) | .browser_download_url')

    # fallback if instance has been restarted too many times
    if [ "$CSS_TARGET_URL" == "null" ] || [ -z "$CSS_TARGET_URL" ]; then
       echo "ERROR: Failed to fetch CSS from GitHub API. Falling back to stable build..."
       CSS_LATEST_TAG="v1.0.368"
       CSS_TARGET_URL="https://github.com/roflmuffin/CounterStrikeSharp/releases/download/v1.0.368/counterstrikesharp-with-runtime-linux-1.0.368.zip"
    fi
  else
    CSS_LATEST_TAG="custom-url-defined"
    CSS_TARGET_URL="$CSS_CUSTOM_URL"
  fi
}

# checks local mod platforms, then 
install_and_update_mods() {
  local update_mms=false
  local update_css=false

  # checks if metamod is missing
  if [ ! -f "$GAME_DIR/addons/metamod.vdf" ] || [ ! -f "$MMS_VERSION_FILE" ]; then
    update_mms=true
  # checks if metamod version is outdated/weird
  elif [ "$(cat "$MMS_VERSION_FILE")" != "$MMS_LATEST_FILE" ] && [ -z "$MMS_CUSTOM_URL" ]; then
    echo "Metamod update: $(cat "$MMS_VERSION_FILE") ->  $MMS_LATEST_FILE"
    update_mms=true
  fi

  # checks if counterstrikesharp is missing
  if [ ! -f "$CSS_DIR/bin/linuxsteamrt64/counterstrikesharp.so" ] || [ ! -f "$CSS_VERSION_FILE" ]; then
    update_css=true
  # checks if counterstrikesharp is outdated/weird
  elif [ "$(cat "$CSS_VERSION_FILE")" != "$CSS_LATEST_TAG" ] && [ -z "$CSS_CUSTOM_URL" ]; then
    echo "CounterStrikeSharp update: $(cat "$CSS_VERSION_FILE") -> $CSS_LATEST_TAG"
    update_css=true
  fi

  # backing up metamod configs/plugins if there has been an update
  if { [ "$SERVER_JUST_UPDATED" == "true" ] || [ "$update_mms" == "true" ]; } && [ -d "$MMS_DIR" ]; then
    echo "Backing up Metamod configs/plugins to /tmp/mms_backup"
    mkdir -p /tmp/mms_backup/
    for item in "$MMS_DIR"/*; do
      if [ -e "$item" ] && [ "$(basename "$item")" != "bin" ]; then cp -r "$item" /tmp/mms_backup/; fi
    done
    rm -rf "$MMS_DIR"
    update_mms=true
  fi

  # backing up css configs/plugins if there has been an update
  if { [ "$SERVER_JUST_UPDATED" == "true" ] || [ "$update_css" == "true" ]; } && [ -d "$CSS_DIR/plugins" ]; then
    echo "Backing up CounterStrikeSharp plugins to temporary RAM disk..."
    mkdir -p /tmp/css_backup/
    cp -r "$CSS_DIR/plugins" /tmp/css_backup/
    cp -r "$CSS_DIR/configs" /tmp/css_backup/
    rm -rf "$CSS_DIR"
    update_css=true
  fi

  #downloading metamod
  if [ "$update_mms" == "true" ]; then
    echo "Downloading and Installing Metamod"
    mkdir -p "$GAME_DIR/addons"
    curl -sL "$MMS_TARGET_URL" | tar zx -C "$GAME_DIR/"
    echo "$MMS_LATEST_FILE" > "$MMS_VERSION_FILE"
  else
    echo "Metamod is up to date"
  fi

  #downloading css
  if [ "$update_css" == "true" ]; then
    echo "Downloading and Installing CounterStrikeSharp"
    curl -sL "$CSS_TARGET_URL" -o /tmp/css.zip
    unzip -o -q /tmp/css.zip -d "$GAME_DIR/"
    rm /tmp/css.zip
    echo "$CSS_LATEST_TAG" > "$CSS_VERSION_FILE"
  else
    echo "CounterStrikeSharp is up to date"
  fi

  # RESTORING BACKUPS
  if [ -d "/tmp/mms_backup" ]; then
    echo "Restoring Metamod plugins and configs..."
    cp -rf /tmp/mms_backup/* "$MMS_DIR/"
    rm -rf /tmp/mms_backup
  fi

  if [ -d "/tmp/css_backup" ]; then
    echo "Restoring CounterStrikeSharp plugins and configs..."
    cp -rf /tmp/css_backup/plugins "$CSS_DIR/"
    cp -rf /tmp/css_backup/configs "$CSS_DIR/"
    rm -rf /tmp/css_backup
  fi

  patch_gameinfo "install"
}

# manages the modding state of the server
manage_modding() {
  export CSS_DIR="$GAME_DIR/addons/counterstrikesharp"
  export MMS_DIR="$GAME_DIR/addons/metamod"
  export MMS_VERSION_FILE="$MMS_DIR/.mms_version"
  export CSS_VERSION_FILE="$CSS_DIR/.css_version"

  export MMS_CUSTOM_URL="${MMS_URL:-}"
  export CSS_CUSTOM_URL="${CSS_URL:-}"

  if [ "${ENABLE_MODDING:-false}" != "true" ]; then
    disable_mods
  else
    enable_mods
  fi
}

start_server() {
  echo "Starting CS2 Server"
  cd "$CS2_DIR" || exit 1
  
  export LD_LIBRARY_PATH="/cs2-data/game/bin/linuxsteamrt64:$LD_LIBRARY_PATH"
  pkill -9 FEXServer || true

  # export XDG_RUNTIME_DIR=/tmp
  # export SDL_VIDEODRIVER=dummy
  # export SDL_AUDIODRIVER=dummy

  local allowed_cpus
  allowed_cpus=$(taskset -cp $$ | awk -F': ' '{print $2}')
  echo "Server allowed for $allowed_cpus cores"

  local thread_count=${CPU_CORE_COUNT:-$(nproc)}
  echo "Allocating $thread_count threads to CS2"

  local map=${STARTUP_MAP:-de_dust2}
  local priority=${SERVER_NICENESS:-0}

  local cs2_cmd="./game/bin/linuxsteamrt64/cs2 -dedicated -usercon +map $map -threads $thread_count"

  if [ -n "$STEAM_GAMESERVER_API" ]; then
    cs2_cmd="$cs2_cmd +sv_setsteamaccount $STEAM_GAMESERVER_API"
  else
    echo "WARNING: STEAM_GAMESERVER_API is missing"
  fi

  cs2_cmd="$cs2_cmd $EXTRA_PARAMS"

  local exec_string="exec nice -n $priority taskset -c $allowed_cpus FEXBash \"$cs2_cmd\""

  echo "Exec args: $exec_string"
  # eval "$exec_string"

  # CI/CD friendly execute
  if [ "${CI_TEST_MODE:-false}" = "true" ]; then
    echo "CI Test Mode: starting server and looking for pattern"
    eval "$exec_string" > /tmp/server_ci.log 2>&1 &
    SERVER_PID=$!

    pattern="Connection to Steam servers successful."
    timeout=120
    while [ $timeout -gt 0 ]; do
      if grep -q "$pattern" /tmp/server_ci.log 2>/dev/null; then
        echo "SUCCESS: Server started correctly"
        kill $SERVER_PID 2>/dev/null || true
        exit 0
      fi
      sleep 2
      timeout=$((timeout - 2))
    done
    echo "ERROR: Server didn't start within the timeout"
    cat /tmp/server_ci.log
    kill $SERVER_PID 2>/dev/null || true
    exit 1
  else
    eval "$exec_string"
  fi
}

main() {
  setup_fex
  setup_steamcmd
  manage_game_server
  manage_modding
  start_server
}

main