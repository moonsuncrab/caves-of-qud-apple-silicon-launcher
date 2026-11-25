# Instructions for coding agents

## Project map

- `Sources/LauncherApp.swift` contains the native SwiftUI and AppKit interface.
- `Launch Caves of Qud (Apple Silicon).command` discovers Steam, prepares the private game copy and profile, stages Workshop mods, and launches the game.
- `AppTemplate/Info.plist` contains the app metadata.
- `Build Launcher App.command` compiles the Swift source and packages the `.app` bundle.
- The checked-in `.app` is a ready-to-open build snapshot. The authoritative distributable for each main-branch push is the versioned ZIP created by `.github/workflows/release.yml`.

## Required behavior and safety rules

- Never modify files in the Steam installation. Make changes only to the launcher's private copy under `~/Library/Application Support/Caves of Qud Apple Silicon Launcher/`.
- Keep the supported game version and Steam build checks. Change them only after validating the new build and updating the README.
- Copy both `CoQ.app` and its sibling `CoQ_Data` folder. The data folder includes DLC assets such as Pets of Harvest Dawn.
- Download Harmony from the upstream URL in the helper. Do not commit Harmony archives, DLLs, game files, DLC files, or Workshop content.
- Let Steam provide Workshop subscriptions and DLC entitlements. Do not bundle or duplicate subscribed Workshop mods.
- Keep the launcher's save profile separate from the normal Steam profile. Describe Steam Cloud behavior accurately.
- Never commit user-specific paths, credentials, logs, save data, Steam files, or local Application Support contents.

## Building and changing features

- Build on an Apple Silicon Mac with Xcode Command Line Tools installed by running `./Build Launcher App.command`. It recreates the `.app` in the repository root and applies an ad hoc signature.
- Every push to `main` runs the release workflow. It derives the version from the base version in `AppTemplate/Info.plist` and the workflow run number, then publishes the `.app` ZIP and a SHA-256 checksum as a GitHub Release.
- Keep `AGENTS.md` out of the app and release ZIP. The release workflow packages only the `.app` bundle.
- The app targets `arm64` and macOS 13.0 or later, with no third-party build dependencies.
- Implement interface changes in `Sources/LauncherApp.swift` and launch or game-preparation changes in the helper script. Keep status text and activity details consistent with the work the helper actually performs.
- Preserve the main page's vertical scrolling and the activity panel's own scrolling so the footer and expanded activity remain reachable in a compact window.
- Update `README.md` when supported builds, installation behavior, profile handling, or user-visible features change.
- Do not claim Steam, Workshop, DLC, or in-game behavior was verified unless it was exercised against a real Steam installation. If that is unavailable, state the validation limit.
- Before finishing, review the changed files and ensure no local game data, credentials, or generated user data entered the change.

## Distribution boundary

`AGENTS.md` is repository guidance for maintainers and coding agents. The build script does not copy it into the `.app` bundle. If the source repository is made public, this file is public along with the rest of the repository source.
