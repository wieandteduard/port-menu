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

**[Download for macOS →](https://portmenu.dev)**

Requires macOS 14 (Sonoma) or later.

1. Download and unzip
2. Open `Port Menu.app` — it will offer to move itself to your Applications folder
3. Click the icon in your menu bar to get started

## Build from source

```bash
git clone https://github.com/wieandteduard/port-menu.git
cd Porter
open Porter.xcodeproj
```

Requires Xcode 15+.

## Release

Signed and notarized macOS builds are published on the [GitHub Releases](https://github.com/wieandteduard/port-menu/releases) page.

Maintainers can follow the release process in `docs/releasing.md`.

## Testing

```bash
xcodebuild test -project "Porter.xcodeproj" -scheme "Porter" -destination "platform=macOS"
```

## License

MIT
