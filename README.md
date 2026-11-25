# Caves of Qud Apple Silicon Launcher

This unofficial launcher creates a private Apple Silicon copy of Caves of Qud for running Harmony-dependent mods. It targets **Caves of Qud 1.0.5, build 2.0.211.57** (Steam build ID `26370970`) and does not patch the Steam-installed game.

## Start here

Open **Caves of Qud Apple Silicon Launcher.app**. The window shows the supported game build, preparation activity, Steam connection, Workshop subscriptions, and Pets of Harvest Dawn checks. Keep Steam open and signed in while playing so Steam can provide subscribed Workshop mods and DLC entitlements.

On first launch, choose whether to copy your existing saves and settings into the launcher's separate profile. The launcher does not alter your Steam saves. New saves in this profile are separate and do not sync through Steam Cloud. Mods still need to be enabled from the game's Mods menu.

The `.command` script is included as a terminal-based fallback. The `Build Launcher App.command` script rebuilds the native GUI from source on an Apple Silicon Mac with Xcode Command Line Tools installed.

## Download a release

Download the latest macOS ZIP from [GitHub Releases](https://github.com/moonsuncrab/caves-of-qud-apple-silicon-launcher/releases/latest), extract it, and open **Caves of Qud Apple Silicon Launcher.app**. Each push to `main` builds a versioned Apple Silicon app and publishes it with a SHA-256 checksum. The release contains the app bundle; repository guidance files are not included.

The app is ad hoc signed and is not notarized with an Apple Developer ID. macOS may ask you to approve it the first time you open it.

## What the launcher prepares

1. Finds the Steam game and checks its Steam build ID against the supported build.
2. Copies both `CoQ.app` and its sibling `CoQ_Data` folder into `~/Library/Application Support/Caves of Qud Apple Silicon Launcher/`. The data folder contains DLC assets such as Pets of Harvest Dawn.
3. Replaces `0Harmony.dll` only in the private game copy with the official Harmony 2.4.2.0 package. The original DLL is backed up inside that copy. The first launch downloads Harmony from its upstream release page.
4. Launches the private ARM64 executable with a separate save profile. Steam remains responsible for Workshop subscriptions; this avoids duplicate local copies of subscribed Workshop mods.

When Steam updates the game, the launcher checks the source files and refreshes its private copy. If the detected Steam build ID differs from `26370970`, it stops before changing the private copy.

## Logs and troubleshooting

The GUI includes an **Open full log** button. The log is saved at `~/Library/Application Support/Caves of Qud Apple Silicon Launcher/launcher.log`. The game log is at `~/Library/Logs/Freehold Games/CavesOfQud/Player.log`.

Review logs before sharing them in a public issue. Remove usernames, local paths, account details, and any other private information.

If Pets of Harvest Dawn is not reported, check that Steam is open and signed in, the game is installed from the account that owns the DLC, and the Steam game folder contains `CoQ_Data/StreamingAssets/DLC/PetsPack1`. The launcher copies that entire data folder beside its private `CoQ.app`.
