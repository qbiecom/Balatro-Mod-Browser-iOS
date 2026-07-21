# BMM Mobile Agent Guide

## Project

BMM Mobile is a SwiftUI iPad/iOS mod manager for the **Lovely Mobile Maker** version of Balatro only. It does not support the App Store version.

- Bundle identifier: `com.qbie.bmm-mobile`
- Deployment target: iOS 17
- External package: ZIPFoundation
- BMI API: `https://api-bmi.dasguney.com`

## Code Layout

- `BMM-Mobile/ContentView.swift`: app navigation, dialogs, folder picker, installed-mod grid.
- `BMM-Mobile/Views/`: catalog, details, settings, tiles, and typography.
- `BMM-Mobile/Services/ModFolderStore.swift`: app state, BMI catalog, caching, dependency flow, folder access.
- `BMM-Mobile/Services/ModFileService.swift`: downloads, archive extraction, transactional file operations, and registry access.
- `BMM-Mobile/Services/TrustedDownloadSession.swift`: approved download hosts and redirect validation.
- `BMM-Mobile/Models/ModModels.swift`: API and app data models.

## Lovely Mobile Maker Folder Rules

The selected folder must be the `game` directory. Validate only its name when selecting it; do not require `config` or `Mods` to exist at selection time.

- Do not create `Mods` or `Disabled Mods`.
- Do not write outside the selected `Mods` directory.
- Disabled mods use a `.lovelyignore` marker inside their own folder.
- Keep security-scoped bookmark access balanced: stop access when abandoning or replacing a selected folder.

## Installation Safety

- Validate catalog folder names before using them as paths.
- Keep ZIP path-traversal checks, archive size/file-count limits, and single-top-level-folder unwrapping.
- Preserve disabled state during updates.
- Do not retain successful-update backups indefinitely.
- Treat the installation registry and the filesystem as separate sources of truth.
- Keep download hosts explicitly allowlisted; audit BMI `download_url` values before adding new domains.

## Dependencies

- Steamodded is installed from the latest GitHub release, not BMI's generic mod download endpoint.
- Talisman requirements can be satisfied by Talisman or Amulet; offer a choice when neither is installed.
- Keep dependency installation and removal dependency-aware.

## UI

- Use `.balatroChrome(...)` for app copy and headings unless a native system style is clearly needed.
- Preserve fixed tile dimensions, readable coloured stripe backgrounds, and restrained press states.
- Do not regress the iPad three-column default layout.
- Keep loading, error, confirmation, disabled, and no-folder states actionable and clear.

## Verification

Compile without code signing after Swift changes:

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build \
  -project BMM-Mobile.xcodeproj \
  -scheme BMM-Mobile \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Create an IPA only when requested. Build an unsigned Release archive, place `BMM-Mobile.app` inside a `Payload` directory, then package it as `BMM-Mobile-unsigned.ipa` for Sideloadly.

## Working Rules

- Use `apply_patch` for source edits.
- Preserve unrelated worktree changes.
- Keep changes scoped; avoid drive-by refactors.
- Do not commit, reset, or overwrite user work unless explicitly asked.
