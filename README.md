# Port Menu

**localhost, organized.**

A tiny macOS menu bar app that tracks your dev servers across projects.

No config. No setup. It just works.

---

## What it does

Port Menu sits in your menu bar and automatically detects local development servers running on your machine. One click to see what's running, which project it belongs to, and on which port.

- **Auto-detection** — scans for running dev servers every few seconds
- **Project context** — shows Git repo name, current branch, port, and uptime
- **Kill or open** — stop a server or open it in your browser directly from the menu
- **Copy URL** — right-click to copy the localhost URL

## Download

**[Download for macOS →](https://github.com/wieandteduard/Porter/releases/latest)**

Requires macOS 13 (Ventura) or later.

1. Download and unzip
2. Move `Porter.app` to your Applications folder
3. Open it — Port Menu appears in your menu bar

> On first launch macOS may ask you to confirm opening an app from the internet. Right-click → Open to proceed. The app is notarized by Apple.

## Build from source

```bash
git clone https://github.com/wieandteduard/Porter.git
cd Porter
open Porter.xcodeproj
```

Requires Xcode 15+.

## License

MIT
