<p align="center">
  <img src="docs/icon.png" width="112" alt="Konverter icon"><br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/wordmark-dark.png">
    <img src="docs/wordmark-light.png" width="240" alt="Konverter">
  </picture>
</p>

<p align="center">
  Hold <b>⇧ Shift</b> while dragging a file to convert it, <b>⌘ Command</b> to compress or strip metadata.<br>
  Lives in your menu bar. The result is saved next to the original.
</p>

<p align="center">
  <a href="https://github.com/davidpraznik/Konverter/releases/latest"><img src="https://img.shields.io/github/v/release/davidpraznik/Konverter?color=6D4AFF&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14.6%2B-6D4AFF" alt="macOS 14.6+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-6D4AFF" alt="MIT licence"></a>
</p>

## Formats

| Input | Output |
| --- | --- |
| Images | PNG, WEBP, JPG, AVIF, HEIC, PDF |
| Video | MP4, GIF, M4A (audio only) |

Several files can be dropped at once. If a file with the same name exists, a number is added (`photo (1).webp`).

## Usage

1. Start Konverter. It lives in the menu bar.
2. Drag one or more files from Finder.
3. While dragging, hold **⇧ Shift** for the conversion wheel, or **⌘ Command** for the image tools wheel (images only). The wheel opens at the cursor.
4. Drop the files on a segment. The result is saved next to the original.

Dropping on the centre or between segments does nothing. The segment with the file's own format is dimmed.

## Image tools

The **⌘ Command** wheel has two tools for images:

| Tool | Formats | What it does |
| --- | --- | --- |
| Compress | PNG, JPG, WEBP, HEIC | Makes the file smaller and saves `name-compressed.ext`. PNG uses its own colour quantization (up to 256 colours, transparency kept). Files that cannot get smaller are skipped. |
| Strip metadata | JPG, PNG, HEIC, WEBP | Removes EXIF, location and other metadata. Saves `name-clean.ext`. |

Settings (menu bar icon, Settings…): launch at login, check for updates (GitHub releases), with an optional automatic check once a day.

## Requirements

- macOS 14.6 or later (tested on macOS 27 only)
- Xcode to build from source

## Build

1. Clone the repository and open `Konverter.xcodeproj`.
2. Xcode resolves the `libwebp` Swift package on first open.
3. Select the **Release** scheme for the best conversion speed and run.

The app does not use the App Sandbox. Detecting a file drag needs no special permissions.

## Opening a downloaded build

Builds from GitHub are not notarized. On first launch, right-click the app, choose **Open**, then confirm.

## About

I am a UX/UI and product designer. I made Konverter for my own needs, as a tool I use every day while working on design and product projects. Many open source tools have helped me deliver my work over the years, so I am sharing this one publicly to give something back. It is free and MIT licensed. Bug reports and ideas are welcome in [Issues](https://github.com/davidpraznik/Konverter/issues).

## Third-party components

- [libwebp](https://chromium.googlesource.com/webm/libwebp) (BSD 3-Clause), WebP encoding.
- [Inter](https://rsms.me/inter/) (SIL Open Font License 1.1), interface typeface. The licence is included as `Inter-LICENSE.txt`.

## Licence

MIT, see [LICENSE](LICENSE). © 2026 David Praznik.
