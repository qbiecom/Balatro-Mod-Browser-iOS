# Balatro Mod Browser

Balatro Mod Browser (BMB) is an iPad-friendly mod manager for Balatro. It lets you browse the Balatro Mod Index, install and update mods, enable or disable installed mods, and view mod information.

## Demo

[![Balatro Mod Browser introduction video](https://vumbnail.com/1210836337.jpg)](https://vimeo.com/1210836337)

Watch the [Balatro Mod Browser introduction on Vimeo](https://vimeo.com/1210836337).

## Important

This app only works with the **Lovely Mobile Maker** version of Balatro. It does not support the official App Store version of Balatro.

## Compatibility

Balatro Mod Browser requires iOS or iPadOS 17 or later. It has been tested on iPadOS 26 and iPadOS 27.

## Features

- Browse and search mods from the Balatro Mod Index
- Filter the catalog by category and sort by name, author, update date, or downloads
- Download, install, update, enable, disable, and remove mods
- View thumbnails, descriptions, requirements, categories, version details, download counts, and repository links
- Cache catalog data, full descriptions, and thumbnails to reduce network use

## Installing

Balatro Mod Browser is intended for sideloading on iOS and iPadOS. Download the unsigned IPA and sideload it with an app such as Sideloadly.

After opening the app, choose the Lovely Mobile Maker game folder. Balatro Mod Browser manages its `Mods` directory.

## Development checks

Run `swift test` on macOS with Swift 6.2 or later. The tests exercise the app's model, trusted networking, archive extraction, and transaction recovery code, using temporary folders and synthetic archives. The unsigned IPA workflow runs them before archiving the iOS app. An iOS device smoke test is still needed for the document picker, security-scoped folder access, and SwiftUI interactions.

Normal Steamodded installations use the latest published release from the official `Steamodded/smods` GitHub repository. The development-build option explicitly installs its `main` branch instead.

## Notes

Mod data is provided by the [Balatro Mod Index](https://api-bmi.dasguney.com). Mod downloads and their contents are supplied by the individual mod authors; install mods you trust.

This is an unofficial community project and is not affiliated with Playstack, LocalThunk, or the official Balatro App Store release.
