# PRAG

**Park, Retrieve, Act & Go** — a zero-bloat drag-and-drop shelf that lives in your MacBook's notch.
Drop files, text or screenshots on the notch, pipe them through one-tap or chained actions, and drag the result straight out — with a clear before/after badge (`-64% · 5.1 MB → 1.8 MB`) so you always see what a pipeline bought you.

Originals are never touched. Every result is a new file in PRAG's own workspace.

## Features

- **Notch shelf** — a staging area that appears at the notch when you drag, hover, or press a hotkey. Items stay across restarts and can be dragged out to any app.
- **Non-destructive pipelines** — one-tap actions or chained presets (e.g. *Web Ready*: strip EXIF → fit 2400 px → compress → WebP). Per-file steps map over your selection; aggregating steps (merge PDFs, zip) collapse many files into one.
- **Delta badges** — each result shows the percentage saved and the exact before → after size.
- **Images** — strip metadata, compress, resize, convert (PNG / JPG / WebP / HEIC / AVIF where the system encoder allows), OCR to clipboard (Apple Vision, on-device).
- **PDFs** — merge, compress, extract text, extract images.
- **Video** — compress to 720p / 1080p, extract audio, convert to GIF.
- **Zip anything** — single item → `<name>.zip`, several → `Archive.zip`.
- **Text pipes** — pretty-print JSON, decode JWTs, decode Base64 / Base64URL, strip tracking parameters (`utm_*`, `fbclid`, `gclid`, …) from URLs.
- **Screenshot catcher** — new screenshots land on the shelf automatically (event-driven, zero CPU when idle).

## Build & run

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+ or matching Command Line Tools).

```sh
make run        # build, bundle PRAG.app, launch
make test       # run the test suite
make dmg        # build/PRAG.dmg
```

Or with plain SwiftPM: `swift build` / `swift test`.

The package has two targets: `PRAGCore` (models and file-transformation services, no UI — fully unit-tested) and `PRAG` (window server plumbing, input monitors, SwiftUI).

## Triggers

The shelf opens when you:

- **drag** something toward the notch (drag proximity),
- **hover** the notch (optional),
- **shake** the pointer while dragging (optional),
- press the global hotkey **⌘⇧Space**.

Toggle them in the settings page of the shelf.

## Privacy

PRAG is local-only. It makes **no network requests**, has no analytics and no accounts. OCR runs through Apple's on-device Vision framework. Files are read from where you dropped them; processed outputs are written to `~/Library/Application Support/PRAG/Workspace` and cleaned up when you remove them. The only other thing stored is the shelf list (`shelf.json`) next to it.

## License

[MIT](LICENSE) © PRAG contributors
