#!/bin/bash
set -eo pipefail

APP_ID="333640"
EXPECTED_GAME_VERSION="1.0.5"
EXPECTED_GAME_BUILD="2.0.211.57"
EXPECTED_STEAM_BUILD_ID="26370970"
HARMONY_VERSION="2.4.2.0"
HARMONY_URL="https://github.com/pardeike/Harmony/releases/download/v2.4.2.0/Harmony-Fat.2.4.2.0.zip"
GAME_RELATIVE_PATH="steamapps/common/Caves of Qud/CoQ.app"

STEAM_ROOT="$HOME/Library/Application Support/Steam"
SUPPORT_DIR="$HOME/Library/Application Support/Caves of Qud Apple Silicon Launcher"
APP_COPY="$SUPPORT_DIR/CoQ.app"
PROFILE_DIR="$SUPPORT_DIR/Profile"
PROFILE_MODS="$PROFILE_DIR/Mods"
SOURCE_MARKER="$SUPPORT_DIR/source-fingerprint"
MANAGED_MODS_FILE="$SUPPORT_DIR/managed-workshop-ids.txt"
PROFILE_MARKER="$SUPPORT_DIR/profile-initialized"
LOG_FILE="$SUPPORT_DIR/launcher.log"
HARMONY_ZIP="$SUPPORT_DIR/downloads/Harmony-Fat.$HARMONY_VERSION.zip"
HARMONY_DLL="$SUPPORT_DIR/downloads/net48-0Harmony.dll"
ARCHIVED_WORKSHOP_DIR="$SUPPORT_DIR/Archived Workshop Copies"

GUI_MODE=0
PROFILE_COPY_CHOICE=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --gui) GUI_MODE=1 ;;
    --copy-profile) PROFILE_COPY_CHOICE="copy" ;;
    --skip-profile-copy) PROFILE_COPY_CHOICE="skip" ;;
  esac
  shift
done

mkdir -p "$SUPPORT_DIR" "$SUPPORT_DIR/downloads" "$PROFILE_DIR" "$PROFILE_MODS"
exec > >(tee -a "$LOG_FILE") 2>&1

say() { printf '\n[Qud Apple Silicon Launcher] %s\n' "$*"; }
fail() { say "ERROR: $*"; say "Details were saved to: $LOG_FILE"; exit 1; }

if [[ "$(uname -m)" != "arm64" ]]; then
  fail "This launcher targets Apple Silicon Macs."
fi

if ! command -v ditto >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1 || \
   ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || \
   ! command -v codesign >/dev/null 2>&1 || ! command -v lipo >/dev/null 2>&1; then
  fail "A required macOS system tool is missing. Update macOS and try again."
fi

STEAM_LIBRARIES=("$STEAM_ROOT")
LIBRARY_FILE="$STEAM_ROOT/steamapps/libraryfolders.vdf"
if [[ -f "$LIBRARY_FILE" ]]; then
  while IFS= read -r library; do
    [[ -n "$library" ]] || continue
    already_added=0
    for existing in "${STEAM_LIBRARIES[@]}"; do
      [[ "$existing" == "$library" ]] && already_added=1
    done
    [[ "$already_added" -eq 1 ]] || STEAM_LIBRARIES+=("$library")
  done < <(sed -nE 's/^[[:space:]]*"path"[[:space:]]*"([^"]+)".*/\1/p' "$LIBRARY_FILE")
fi

SOURCE_APP=""
GAME_LIBRARY=""
GAME_ROOT=""
for library in "${STEAM_LIBRARIES[@]}"; do
  GAME_ROOT="$library/steamapps/common/Caves of Qud"
  candidate="$GAME_ROOT/CoQ.app"
  if [[ -d "$candidate" ]]; then
    SOURCE_APP="$candidate"
    GAME_LIBRARY="$library"
    break
  fi
done

if [[ -z "$SOURCE_APP" ]]; then
  say "I couldn't find CoQ.app in Steam's standard library locations."
  read -r -p "Paste the full path to your Steam-installed CoQ.app: " SOURCE_APP
  SOURCE_APP="${SOURCE_APP#\"}"
  SOURCE_APP="${SOURCE_APP%\"}"
  SOURCE_APP="${SOURCE_APP//\\ / }"
  [[ -d "$SOURCE_APP" ]] || fail "That path is not a CoQ.app bundle."
  GAME_LIBRARY="$(dirname "$(dirname "$(dirname "$(dirname "$SOURCE_APP")")")")"
  GAME_ROOT="$(dirname "$SOURCE_APP")"
  STEAM_LIBRARIES+=("$GAME_LIBRARY")
fi

GAME_EXECUTABLE="$SOURCE_APP/Contents/MacOS/CoQ"
SOURCE_DATA="$GAME_ROOT/CoQ_Data"
DATA_COPY="$SUPPORT_DIR/CoQ_Data"
STEAM_MANIFEST="$GAME_LIBRARY/steamapps/appmanifest_$APP_ID.acf"
MANAGED_DIR="$SOURCE_APP/Contents/Resources/Data/Managed"
[[ -x "$GAME_EXECUTABLE" ]] || fail "The game executable was not found inside CoQ.app."
[[ -f "$MANAGED_DIR/0Harmony.dll" ]] || fail "The game's Managed folder does not contain 0Harmony.dll."
[[ -f "$STEAM_MANIFEST" ]] || fail "The Steam app manifest was not found next to this game library."

ARCHS="$(lipo -archs "$GAME_EXECUTABLE" 2>/dev/null || true)"
[[ " $ARCHS " == *" arm64 "* ]] || fail "This Steam game build does not contain an arm64 executable."

STEAM_BUILD_ID="$(sed -nE 's/^[[:space:]]*"buildid"[[:space:]]*"([^"]+)".*/\1/p' "$STEAM_MANIFEST" | sed -n '1p')"
[[ -n "$STEAM_BUILD_ID" ]] || fail "Couldn't read the installed Steam build ID."
[[ "$STEAM_BUILD_ID" == "$EXPECTED_STEAM_BUILD_ID" ]] || \
  fail "This launcher is verified for Caves of Qud $EXPECTED_GAME_VERSION build $EXPECTED_GAME_BUILD (Steam build $EXPECTED_STEAM_BUILD_ID). Steam reports build $STEAM_BUILD_ID, so no game files were changed."
say "Found Caves of Qud $EXPECTED_GAME_VERSION build $EXPECTED_GAME_BUILD (Steam build $STEAM_BUILD_ID)."

if [[ -e "$APP_COPY" && ! -f "$SOURCE_MARKER" ]]; then
  fail "A CoQ.app already exists in the launcher folder but is not managed by this launcher. Move it before continuing: $APP_COPY"
fi
if [[ -e "$DATA_COPY" && ! -f "$SOURCE_MARKER" ]]; then
  fail "A CoQ_Data folder already exists in the launcher folder but is not managed by this launcher. Move it before continuing: $DATA_COPY"
fi

fingerprint_source() {
  if [[ -d "$SOURCE_DATA" ]]; then
    find "$SOURCE_APP" "$SOURCE_DATA" -type f -exec stat -f '%N|%z|%m' {} + 2>/dev/null
  else
    find "$SOURCE_APP" -type f -exec stat -f '%N|%z|%m' {} + 2>/dev/null
  fi | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

SOURCE_FINGERPRINT="$(fingerprint_source)"
[[ -n "$SOURCE_FINGERPRINT" ]] || fail "Couldn't identify the installed game files."

if [[ ! -s "$HARMONY_ZIP" ]]; then
  say "Downloading the official Harmony $HARMONY_VERSION package."
  DOWNLOAD_TMP="$HARMONY_ZIP.tmp.$$"
  trap 'rm -f "$DOWNLOAD_TMP"; rm -rf "${TEMP_APP:-}"' EXIT
  curl --fail --location --retry 2 --connect-timeout 20 "$HARMONY_URL" --output "$DOWNLOAD_TMP"
  unzip -tq "$DOWNLOAD_TMP" >/dev/null || fail "The Harmony download is not a valid ZIP archive."
  mv "$DOWNLOAD_TMP" "$HARMONY_ZIP"
fi

if [[ ! -s "$HARMONY_DLL" ]]; then
  unzip -p "$HARMONY_ZIP" 'net48/0Harmony.dll' > "$HARMONY_DLL"
fi
[[ -s "$HARMONY_DLL" ]] || fail "Harmony $HARMONY_VERSION did not contain net48/0Harmony.dll."

CURRENT_FINGERPRINT=""
[[ -f "$SOURCE_MARKER" ]] && CURRENT_FINGERPRINT="$(cat "$SOURCE_MARKER")"
if [[ ! -d "$APP_COPY" || ! -d "$DATA_COPY" || "$CURRENT_FINGERPRINT" != "$SOURCE_FINGERPRINT" ]]; then
  if pgrep -x CoQ >/dev/null 2>&1; then
    fail "Caves of Qud is currently running. Quit it before the launcher refreshes its private copy."
  fi

  say "Preparing private copies of CoQ.app and CoQ_Data. The Steam installation will remain untouched."
  TEMP_APP="$SUPPORT_DIR/CoQ.app.building.$$"
  OLD_APP="$SUPPORT_DIR/CoQ.app.previous.$$"
  TEMP_DATA="$SUPPORT_DIR/CoQ_Data.building.$$"
  OLD_DATA="$SUPPORT_DIR/CoQ_Data.previous.$$"
  rm -rf "$TEMP_APP" "$OLD_APP" "$TEMP_DATA" "$OLD_DATA"
  trap 'rm -rf "${TEMP_APP:-}" "${OLD_APP:-}" "${TEMP_DATA:-}" "${OLD_DATA:-}"; rm -f "${DOWNLOAD_TMP:-}"' EXIT
  ditto "$SOURCE_APP" "$TEMP_APP"
  if [[ -d "$SOURCE_DATA" ]]; then
    ditto "$SOURCE_DATA" "$TEMP_DATA"
  else
    mkdir -p "$TEMP_DATA"
  fi
  if [[ -f "$SOURCE_DATA/StreamingAssets/DLC/PetsPack1/manifest.json" ]]; then
    say "Pets of Harvest Dawn files are present in the Steam install and will be included."
  else
    say "Pets of Harvest Dawn files were not found in the Steam install."
  fi

  TEMP_MANAGED_DIR="$TEMP_APP/Contents/Resources/Data/Managed"
  [[ -f "$TEMP_MANAGED_DIR/0Harmony.dll" ]] || fail "The copied game is missing 0Harmony.dll."
  cp -p "$TEMP_MANAGED_DIR/0Harmony.dll" "$TEMP_MANAGED_DIR/0Harmony.dll.stock"
  ditto "$HARMONY_DLL" "$TEMP_MANAGED_DIR/0Harmony.dll"
  printf '%s\n' "$APP_ID" > "$TEMP_APP/Contents/MacOS/steam_appid.txt"

  codesign --force --deep --sign - "$TEMP_APP" >/dev/null || fail "macOS couldn't sign the private game copy after the Harmony update."

  if [[ -e "$APP_COPY" ]]; then mv "$APP_COPY" "$OLD_APP"; fi
  if [[ -e "$DATA_COPY" ]]; then mv "$DATA_COPY" "$OLD_DATA"; fi
  if ! mv "$TEMP_APP" "$APP_COPY"; then
    [[ -e "$OLD_APP" ]] && mv "$OLD_APP" "$APP_COPY"
    [[ -e "$OLD_DATA" ]] && mv "$OLD_DATA" "$DATA_COPY"
    fail "Couldn't install the refreshed private game copy."
  fi
  if ! mv "$TEMP_DATA" "$DATA_COPY"; then
    rm -rf "$APP_COPY"
    [[ -e "$OLD_APP" ]] && mv "$OLD_APP" "$APP_COPY"
    [[ -e "$OLD_DATA" ]] && mv "$OLD_DATA" "$DATA_COPY"
    fail "Couldn't install the refreshed private DLC data folder."
  fi
  printf '%s\n' "$SOURCE_FINGERPRINT" > "$SOURCE_MARKER.tmp"
  mv "$SOURCE_MARKER.tmp" "$SOURCE_MARKER"
  rm -rf "$OLD_APP" "$OLD_DATA"
fi

copy_current_profile_once() {
  [[ -f "$PROFILE_MARKER" ]] && return
  DEFAULT_DATA="$HOME/Library/Application Support/com.FreeholdGames.CavesOfQud"
  if [[ -d "$DEFAULT_DATA" ]]; then
    say "The launcher uses its own profile so regular Steam launches stay separate."
    say "Steam Cloud will not sync saves made in this profile."
    if [[ "$PROFILE_COPY_CHOICE" == "copy" ]]; then
      answer="y"
    elif [[ "$PROFILE_COPY_CHOICE" == "skip" ]]; then
      answer="n"
    else
      read -r -p "Copy your current Caves of Qud data into this profile once? [y/N] " answer
    fi
    case "$answer" in
      y|Y|yes|YES)
        rsync -a --exclude='Mods/' "$DEFAULT_DATA/" "$PROFILE_DIR/"
        mkdir -p "$PROFILE_MODS"
        for local_mod_dir in "$DEFAULT_DATA/Mods" "$DEFAULT_DATA/Local/Mods"; do
          [[ -d "$local_mod_dir" ]] || continue
          if [[ "$local_mod_dir" == "$DEFAULT_DATA/Local/Mods" ]]; then
            profile_mod_dir="$PROFILE_DIR/Local/Mods"
          else
            profile_mod_dir="$PROFILE_MODS"
          fi
          mkdir -p "$profile_mod_dir"
          for local_mod in "$local_mod_dir"/*; do
            [[ -d "$local_mod" ]] || continue
            local_mod_name="${local_mod##*/}"
            [[ "$local_mod_name" =~ ^[0-9]+$ ]] && continue
            ditto "$local_mod" "$profile_mod_dir/$local_mod_name"
          done
        done
        say "Copied your saves and settings, plus local non-Workshop mods. Workshop subscriptions remain managed by Steam. Future saves in this profile won't sync back to Steam."
        ;;
      *)
        say "Starting with an empty profile. Your regular Steam saves remain untouched."
        ;;
    esac
  else
    say "Starting with a new profile. Your regular Steam saves remain untouched."
  fi
  touch "$PROFILE_MARKER"
}

copy_current_profile_once

archive_legacy_workshop_copies() {
  [[ -f "$MANAGED_MODS_FILE" ]] || return
  local managed_id relative source destination
  while IFS= read -r managed_id; do
    [[ "$managed_id" =~ ^[0-9]+$ ]] || continue
    for relative in "Mods/$managed_id" "Local/Mods/$managed_id"; do
      source="$PROFILE_DIR/$relative"
      [[ -d "$source" ]] || continue
      destination="$ARCHIVED_WORKSHOP_DIR/$relative"
      if [[ -e "$destination" ]]; then
        destination="$destination.$(date +%s)"
      fi
      mkdir -p "$(dirname "$destination")"
      mv "$source" "$destination"
      say "Moved a cached copy of Workshop item $managed_id into a backup folder. Steam will provide the active Workshop copy."
    done
  done < "$MANAGED_MODS_FILE"
}

archive_legacy_workshop_copies

say "Launching the patched copy with an isolated profile."
say "Steam must be open and signed in for Workshop subscriptions and DLC entitlements."
say "Your subscribed Workshop mods will load through Steam. Enable them from the game's Mods menu."
say "To play the unmodified Steam version, launch Caves of Qud normally from Steam."

export SteamAppId="$APP_ID"
export SteamGameId="$APP_ID"
cd "$APP_COPY/Contents/MacOS"
PLAYER_LOG="$HOME/Library/Logs/Freehold Games/CavesOfQud/Player.log"
if /usr/bin/arch -arm64 "$APP_COPY/Contents/MacOS/CoQ" -savepath "$PROFILE_DIR"; then
  GAME_EXIT=0
else
  GAME_EXIT=$?
fi

if [[ -f "$PLAYER_LOG" ]]; then
  while IFS= read -r line; do
    case "$line" in
      *"SteamAPI_Init(): Loaded"*) say "Game log confirms the Steam API connected." ;;
      *"INFO - has Pets Pack 1"*) say "Game log confirms the Pets of Harvest Dawn entitlement." ;;
      *"INFO - does not have Pets Pack 1"*) say "Game log reports no Pets of Harvest Dawn entitlement." ;;
      *"Subscribed workshop items:"*) say "$line" ;;
      *"RefreshModDirectory "*"/CoQ_Data/StreamingAssets/DLC"*) say "Game log confirms it scanned the private DLC data folder." ;;
    esac
  done < <(tail -n 300 "$PLAYER_LOG")
fi

exit "$GAME_EXIT"
