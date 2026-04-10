# MacEdits

**Local-first macOS reel editor built with SwiftUI + AVFoundation.**

I use Instagram Edits-style workflows a lot, but I wanted the same speed + control on Mac.  
So I started building this for myself first. Then I thought: why not open source it and build it in public?

Thoda sa creator pain, thoda sa engineering madness, full dil se project.

## Why this exists

Most options are either:
- phone-only flow (fast, but limited when edits get serious), or
- pro editing tools (powerful, but heavy for quick reels).

MacEdits tries to sit in the middle:
- fast recording/import
- timeline editing that feels snappy
- captions/text/transitions/audio controls
- local export, no backend dependency

## Screenshots

### Home
![MacEdits Home](assets/screenshots/home-full.png)

### Recording Studio
![MacEdits Recording Studio](assets/screenshots/recording-full.png)

### Main Editor
![MacEdits Editor](assets/screenshots/editor-full.png)

## Current Feature Set (Public Alpha)

- Recording studio (camera / screen / screen+cam modes)
- Multi-track timeline editing
- Split, trim, reorder, ripple/non-ripple editing
- Transition controls (type + duration)
- Text overlays and caption generation fallback flow
- Audio controls (mute/solo/volume/voiceover path)
- Export pipeline with retry/fallback behavior
- Autosave + recovery mechanics

## What is still cooking

- Transition preview parity edge cases
- Screen+camera composited preview/export polish
- Caption QA across long clips/locales
- More accessibility polish

## Tech Stack

- Swift 6.2
- SwiftUI
- AVFoundation
- ScreenCaptureKit
- Speech framework

## Run Locally

### Requirements

- macOS 14+
- Xcode 16+ (or Swift 6.2 toolchain)

### Commands

```bash
swift build
swift test
./scripts/run-dev-app.sh
```

The run script launches `MacEdits Dev.app` in `~/Applications`.

## Project Structure

```text
Sources/MacEdits/
  Core/
  Features/
    Home/
    Recording/
    Editor/
    Export/
    Text/
Tests/MacEditsTests/
scripts/
```

## Contributing

If you like this and want to contribute, you’re most welcome.

Best places to help right now:
- timeline UX polish
- export stability edge cases
- caption reliability tests
- accessibility fixes

Open an issue with reproducible steps, or send a PR directly if scope is clear.

## Roadmap vibe

The goal is simple:  
**creator speed + desktop control + minimal friction**.

No bloated workflow, no unnecessary clicks, just “record -> edit -> export”.

## Star this repo?

If you find this useful, drop a star.  
That gives motivation and also helps contributors discover the project faster.

## Disclaimer

This is an independent open-source project and is not affiliated with Meta/Instagram.
