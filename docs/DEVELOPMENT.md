# Development

## Requirements
- Xcode 26+ (built with Xcode 26.5 / Swift 6.3), macOS 14.0+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — build tool only, not an app dependency
- Signing team `NB6868HT2X` (set in `project.yml`)

## Project generation
`Orbi.xcodeproj` is generated from `project.yml`. **Edit `project.yml`, not the project**, then:

```sh
xcodegen generate
```

Re-run it after adding/removing source files (sources are folder-based, so new files in `Orbi/` are picked up on regeneration).

## Install (daily use)
```sh
scripts/install.sh   # Release build → /Applications/Orbi.app → quits old copy → relaunches
```
Use this instead of running from Xcode, so there's only ever one copy (one menu bar icon) and launch-at-login points at /Applications.

## Build, test, run
```sh
# Tests (Swift Testing, hosted in the app)
xcodebuild -project Orbi.xcodeproj -scheme Orbi -destination 'platform=macOS' \
  -derivedDataPath build -allowProvisioningUpdates test

# Build + run
xcodebuild -project Orbi.xcodeproj -scheme Orbi -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build
open build/Build/Products/Debug/Orbi.app
```

Or open `Orbi.xcodeproj` in Xcode and press ⌘R.

## Where data lives
- App Group: `NB6868HT2X.com.berke.orbi`
- Store: `~/Library/Group Containers/NB6868HT2X.com.berke.orbi/Library/Application Support/Orbi/Orbi.store`
- Status file: `~/Library/Application Support/Orbi/status.json` (outside the group container on purpose, see DECISIONS)

Reset all data: quit Orbi, then delete `~/Library/Group Containers/NB6868HT2X.com.berke.orbi`.

## Logs
```sh
log stream --predicate 'subsystem == "com.berke.Orbi"' --level info
```

## Launch at login
The toggle uses `SMAppService.mainApp`, which registers the app *at its current path*. Toggle it from a copy in `/Applications`, not from `build/`, or the login item will point at a build folder that gets wiped.

## URL scheme (manual testing)
```sh
open "orbi://water/add"
open "orbi://water/undo"
open "orbi://task/add?title=API%20docs&min=25"
open "orbi://task/add?title=Plan%20sprint&date=tomorrow"
open "orbi://task/start-next"
open "orbi://task/complete"
open "orbi://reading/save?url=https%3A%2F%2Fexample.com&title=Example"
open "orbi://reading/open-next"

cat ~/Library/Application\ Support/Orbi/status.json
log stream --predicate 'subsystem == "com.berke.Orbi" AND category == "URLRouter"' --level info
```

## Releasing
Releases are signed with **Developer ID** and **notarized**, so a downloaded Orbi opens without Gatekeeper warnings.

One-time setup:
1. Xcode → Settings → Accounts → (team) → Manage Certificates → **+** → *Developer ID Application* (Account Holder only).
2. Create an app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords.
3. `xcrun notarytool store-credentials orbi-notary --apple-id <apple id> --team-id <team id>` (asks for the password, stores it in the keychain).

Each release: bump `MARKETING_VERSION` in `project.yml`, commit, then `scripts/release.sh` (or `--no-upload` to only build + notarize into `dist/`).

## README screenshots
Debug builds have a screenshot mode with sample data (never your real tasks or agent history):
```sh
osascript -e 'tell application id "com.berke.Orbi" to quit'   # only one Orbi at a time
build/Build/Products/Debug/Orbi.app/Contents/MacOS/Orbi -OrbiScreenshots
```
It shows the permission and reply bubbles and opens the panel in a plain window. Capture each window with `screencapture -o -l <window id>` (ids from `CGWindowListCopyWindowInfo`), save to `docs/assets/`, then quit it and reopen the installed Orbi.
