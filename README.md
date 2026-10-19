# Konverter

A small macOS menu bar app for converting files. Hold **Shift** while dragging a file, a wheel appears around the cursor, and dropping the file on a segment converts it. The result is saved next to the original.

## Formats

| Input | Output |
| --- | --- |
| Images | PNG, WEBP, JPG, AVIF, HEIC, PDF |
| Video | MP4, GIF, M4A |

Several files can be dropped at once. If a file with the same name exists, a number is added (`photo (1).webp`).

## Usage

1. Start Konverter. It lives in the menu bar.
2. Start dragging one or more files from Finder.
3. Hold **Shift**. The wheel opens at the cursor.
4. Drop the files on a format. Dropping on the centre or between segments does nothing.

## Image tools

Hold **⌘ Command** instead of Shift while dragging an image to open a second wheel:

| Tool | Formats | What it does |
| --- | --- | --- |
| Compress | PNG, JPG, WEBP, HEIC | Makes the file smaller and saves `name-compressed.ext`. PNG uses its own colour quantization (up to 256 colours, transparency kept). Files that cannot get smaller are skipped. |
| Strip metadata | JPG, PNG, HEIC, WEBP | Removes EXIF, location and other metadata. Saves `name-clean.ext`. |

Settings (menu bar icon, Settings…): launch at login, check for updates (GitHub releases).

## Requirements

- macOS 15 or later (check the deployment target in the project)
- Xcode to build from source

## Build

1. Clone the repository and open `Konverter.xcodeproj`.
2. Xcode resolves the `libwebp` Swift package on first open.
3. Select the **Release** scheme for the best conversion speed and run.

The app does not use the App Sandbox. Detecting a file drag needs no special permissions.

## Opening a downloaded build

Builds from GitHub are not notarized. On first launch, right-click the app, choose **Open**, then confirm.

## Third-party components

- [libwebp](https://chromium.googlesource.com/webm/libwebp) (BSD 3-Clause), WebP encoding.
- [Inter](https://rsms.me/inter/) (SIL Open Font License 1.1), interface typeface. The licence is included as `Inter-LICENSE.txt`.

## Licence

MIT, see [LICENSE](LICENSE). © 2026 David Praznik.
