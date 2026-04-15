# Pedal Scroll

A tiny macOS menu bar app that lets you scroll any application with an Elgato Stream Deck Pedal.

- **Left pedal:** hold to scroll up
- **Right pedal:** hold to scroll down
- **Middle pedal:** tap to cycle scroll speed (Slow / Medium / Fast)

Releasing a pedal stops the scroll instantly. Works in any app — browsers, PDF viewers, code editors, anything that accepts mouse-wheel input.

## How it works

A single ~300-line Swift app reads the Stream Deck Pedal directly via macOS's IOKit HID framework and emits native scroll-wheel events through CoreGraphics.

```
Pedal hardware → Pedal Scroll.app → CGEvent → focused app
```

That's the whole stack. No Stream Deck app, no Hammerspoon, no plugins, no HTTP, no Node.js. The app runs as a menu bar item (no Dock icon, no app switcher entry).

## Requirements

- macOS 13 (Ventura) or later
- Elgato Stream Deck Pedal (USB)
- Xcode command line tools (for `swiftc`) — `xcode-select --install`

## Install

```
cd app
./build.sh install
```

This compiles the app, copies it to `/Applications/Pedal Scroll.app`, and launches it.

The first time it runs, macOS will prompt for two permissions:

1. **Input Monitoring** — required to read the pedal's HID input
2. **Accessibility** — required to post scroll-wheel events

Click **Allow** on each prompt. The app stores its preferences (current speed, enabled state) in standard `UserDefaults`.

## Use

Once installed, look for the small `↕` icon in the right side of your menu bar. Click it for:

- **Status indicator** — green dot = pedal connected and active, yellow = paused, red = pedal not detected
- **Speed** — pick Slow / Medium / Fast, or use the middle pedal to cycle
- **Enabled** — toggle pedal scrolling without quitting
- **Start at Login** — register the app to launch automatically (uses `SMAppService`)
- **Quit Pedal Scroll**

## Speed presets

| Preset | Pixels per tick | Tick interval |
|---|---|---|
| Slow   | 2  | 20 ms |
| Medium | 4  | 20 ms |
| Fast   | 8  | 15 ms |

Tweak these in [`app/main.swift`](app/main.swift) (search for `let speeds:`) and rebuild.

## Build

```
cd app
./build.sh
```

This produces `app/build/Pedal Scroll.app`. Use `./build.sh install` to also copy it to `/Applications` and launch it.

The build is unsigned (uses Swift's automatic linker-signed identity). Suitable for personal use; if you want to distribute it you'll need an Apple Developer ID.

## Project layout

```
.
├── app/
│   ├── main.swift     # The entire app: HID reader, scroll engine, menu bar UI
│   ├── Info.plist     # Bundle metadata, including LSUIElement (no Dock icon)
│   └── build.sh       # Compile + bundle script
├── README.md
└── LICENSE
```

## Why this exists

Earlier iterations of this project ran the pedal through Stream Deck → Stream Deck plugin (Node.js) → HTTP → Hammerspoon → CGEvent. Five hops. Every layer occasionally failed: lost stop commands, hung HTTP servers, runaway scroll states, Stream Deck app freezes. Rewriting it as a single native binary that owns the pedal directly eliminated every one of those failure modes.

## Troubleshooting

**Pedal not connected (red dot):** Check the pedal is plugged in. If it is, the app likely needs Input Monitoring permission — look in System Settings → Privacy & Security → Input Monitoring and confirm "Pedal Scroll" is enabled.

**Pedal connected (green) but no scrolling:** The app needs Accessibility permission to post scroll events. Open System Settings → Privacy & Security → Accessibility and enable "Pedal Scroll."

**Permissions seem stuck after rebuilding:** macOS caches Privacy decisions per code-signature hash, so a rebuild can confuse it. Reset with:

```
tccutil reset ListenEvent com.chuckconway.pedal-scroll
tccutil reset Accessibility com.chuckconway.pedal-scroll
```

Then relaunch and re-grant when prompted. If grants still get rejected, log out and back in (or reboot) — the TCC daemon refreshes its cache on login.

## License

MIT — see [LICENSE](LICENSE).
