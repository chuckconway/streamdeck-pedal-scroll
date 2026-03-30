# Stream Deck Pedal Scroll

Control browser scrolling (or any app) with your Elgato Stream Deck Pedal. Hold a pedal to scroll continuously; release to stop. A third pedal cycles through speed presets.

**macOS only.** Requires a Stream Deck Pedal and the Elgato Stream Deck app.

## How It Works

Two components work together:

```
┌─────────────┐  SDK events   ┌──────────────────┐  HTTP POST   ┌──────────────┐  CGEvent   ┌─────────┐
│ Stream Deck │ ────────────► │ Stream Deck      │ ───────────► │ Hammerspoon  │ ─────────► │ Focused │
│   Pedal     │  keyDown/Up   │ Plugin (Node.js) │  localhost   │ HTTP Server  │  scroll    │   App   │
└─────────────┘               └──────────────────┘              └──────────────┘            └─────────┘
```

1. **Stream Deck Plugin** — A custom plugin built with the Elgato Stream Deck SDK v2. It registers three actions (Scroll Up, Scroll Down, Cycle Speed) and listens for pedal `keyDown`/`keyUp` events. On press, it sends an HTTP request to localhost. On release, it sends a stop command.

2. **Hammerspoon HTTP Server** — A Lua script running in [Hammerspoon](https://www.hammerspoon.org/) that listens on port 27183. When it receives a scroll command, it starts a timer that generates native `CGEvent` scroll wheel events at a configurable rate. These are OS-level events — the focused app (browser, PDF reader, anything) receives them exactly like mouse wheel input.

### Why This Architecture?

**Why not just map pedals to keyboard shortcuts?**

We tried this first. The Stream Deck's Hotkey action simulates key presses, which means key repeat. macOS key repeat generates unreliable `keyDown`/`keyUp` sequences — phantom `keyUp` events mid-hold, stale `keyDown` events after release. This causes scrolling to get "stuck on" or stop unexpectedly. The Stream Deck SDK gives clean, single `keyDown` on press and `keyUp` on release with no repeat noise.

**Why Hammerspoon?**

The Stream Deck plugin runs inside the Stream Deck process and can't generate OS-level scroll events. Something needs to bridge HTTP requests to `CGEvent` scroll wheel events. Hammerspoon is a free, lightweight macOS automation tool that does exactly this in ~30 lines of Lua. The alternative would be writing a standalone Swift or Python app — more code for the same result.

**Why not a browser extension?**

A browser extension could use `window.scrollBy()`, but it would only work inside the browser, require a WebSocket bridge, and need to be installed per-browser. The Hammerspoon approach works in every app — browsers, PDF readers, code editors, anything with a scrollable window.

## Pedal Layout

| Pedal | Action | Behavior |
|-------|--------|----------|
| Left | Scroll Up | Hold to scroll up, release to stop |
| Middle | Cycle Speed | Tap to cycle: Slow → Medium → Fast |
| Right | Scroll Down | Hold to scroll down, release to stop |

## Speed Presets

| Preset | Pixels/tick | Tick interval | Feel |
|--------|------------|---------------|------|
| Slow | 2 | 20ms | Reading pace, like a teleprompter |
| Medium | 5 | 15ms | Comfortable browsing |
| Fast | 15 | 10ms | Scanning/skimming |

Edit `hammerspoon/init.lua` to customize these values.

## Quick Install

```bash
git clone https://github.com/chuckconway/streamdeck-pedal-scroll.git
cd streamdeck-pedal-scroll
./install.sh
```

The install script handles everything automated, then prints the manual steps you need to complete.

## Manual Install

### Prerequisites

- macOS 10.15+
- [Elgato Stream Deck app](https://www.elgato.com/downloads) v6.4+
- [Homebrew](https://brew.sh/)

### Step 1: Install Hammerspoon

```bash
brew install --cask hammerspoon
```

Launch Hammerspoon from `/Applications/Hammerspoon.app`. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility).

### Step 2: Deploy Hammerspoon Config

```bash
# Back up existing config if you have one
cp ~/.hammerspoon/init.lua ~/.hammerspoon/init.lua.backup 2>/dev/null

# Copy the scroll control config
cp hammerspoon/init.lua ~/.hammerspoon/init.lua
```

Reload the config from the Hammerspoon menu bar icon, or restart Hammerspoon. You should see "Pedal scroll ready (port 27183)" on screen.

> **If you already have a Hammerspoon config**: Append the contents of `hammerspoon/init.lua` to your existing `~/.hammerspoon/init.lua` instead of overwriting it.

### Step 3: Build and Install the Stream Deck Plugin

```bash
# Install dependencies
npm install

# Build the plugin
npm run build

# Copy to Stream Deck plugins directory
cp -R com.chuckconway.pedal-scroll.sdPlugin \
  ~/Library/Application\ Support/com.elgato.StreamDeck/Plugins/
```

Restart the Stream Deck app to load the plugin.

### Step 4: Assign Actions to Pedals

1. Open the Stream Deck app
2. Find **"Pedal Scroll"** in the action list on the right
3. Drag **Scroll Up** to the left pedal
4. Drag **Cycle Speed** to the middle pedal
5. Drag **Scroll Down** to the right pedal

### Step 5: Test

Open a browser with a long page. Hold the right pedal — the page should scroll down. Release — it stops. Tap the middle pedal to cycle speed.

## Updating

After pulling changes:

```bash
npm run build
cp -R com.chuckconway.pedal-scroll.sdPlugin \
  ~/Library/Application\ Support/com.elgato.StreamDeck/Plugins/
```

Then restart the Stream Deck app, or use:

```bash
npx streamdeck restart com.chuckconway.pedal-scroll
```

## Project Structure

```
streamdeck-pedal-scroll/
├── src/
│   ├── plugin.ts                  # Entry point — registers actions with SDK
│   └── actions/
│       └── scroll.ts              # Three actions: ScrollUp, ScrollDown, CycleSpeed
├── hammerspoon/
│   └── init.lua                   # Hammerspoon HTTP server config
├── com.chuckconway.pedal-scroll.sdPlugin/
│   ├── manifest.json              # Stream Deck plugin manifest
│   ├── imgs/
│   │   └── icon.png               # Plugin icon (placeholder)
│   └── bin/                       # Built output (gitignored)
│       └── plugin.js
├── install.sh                     # Automated install script
├── rollup.config.mjs              # Bundler config
├── tsconfig.json
└── package.json
```

## How the Plugin Communicates

The Stream Deck plugin sends HTTP GET requests to Hammerspoon:

| Pedal Event | HTTP Request | Hammerspoon Action |
|-------------|-------------|-------------------|
| Left pedal pressed | `GET http://127.0.0.1:27183/scroll/up` | Start scroll timer (direction: up) |
| Left pedal released | `GET http://127.0.0.1:27183/scroll/stop` | Stop scroll timer |
| Middle pedal pressed | `GET http://127.0.0.1:27183/scroll/speed` | Cycle to next speed preset |
| Right pedal pressed | `GET http://127.0.0.1:27183/scroll/down` | Start scroll timer (direction: down) |
| Right pedal released | `GET http://127.0.0.1:27183/scroll/stop` | Stop scroll timer |

Port 27183 is only bound to localhost — no external network access.

## FAQ

### Does this only work in browsers?

No. It works in any application that accepts scroll wheel input — browsers, PDF viewers, code editors, Slack, Terminal, etc. Hammerspoon generates OS-level scroll events that macOS delivers to whatever window is focused.

### Can I use this with a regular Stream Deck (not the Pedal)?

Yes. The actions use the `Keypad` controller type, which works with any Stream Deck button. Assign Scroll Up and Scroll Down to two buttons. The hold-to-scroll behavior works the same way — press and hold the button, release to stop.

### Can I change the scroll speed without the middle pedal?

Yes. Edit the `speeds` table in `hammerspoon/init.lua` and set the default speed by changing `local currentSpeed = 1` to your preferred index (1 = Slow, 2 = Medium, 3 = Fast). Reload the Hammerspoon config.

### Does Hammerspoon need to be running?

Yes. Hammerspoon runs as a menu bar app and provides the HTTP server that converts pedal commands into scroll events. Set it to launch at login: Hammerspoon menu bar icon → Preferences → "Launch Hammerspoon at login".

### Does the Stream Deck app need to be running?

Yes. The Stream Deck app hosts the plugin runtime. It normally launches at login automatically.

### Can I customize which pedal does what?

Yes. In the Stream Deck app, you can drag any action to any pedal slot. You could put Scroll Down on the left and Scroll Up on the right if you prefer.

## Troubleshooting

### Plugin doesn't appear in Stream Deck action list

**Symptom**: You installed the plugin but "Pedal Scroll" doesn't show up in the Stream Deck app.

**Causes and fixes**:

1. **Missing category icon** — The Stream Deck app silently rejects plugins without a `CategoryIcon` field in `manifest.json`. The error in the logs reads: `Plugin invalid 'com.chuckconway.pedal-scroll': (category icon not defined)`. This plugin includes the icon, but if you modify the manifest, ensure `CategoryIcon` and `Icon` fields point to valid image paths.

2. **Developer mode not enabled (symlinked plugins only)** — If you installed via `streamdeck link` (symlink), the Stream Deck app requires developer mode. The log shows: `Feature only enabled in developer mode`. Fix:
   ```bash
   defaults write com.elgato.StreamDeck developerMode -bool YES
   ```
   Then restart the Stream Deck app. The `install.sh` script copies the plugin directly (not symlink) to avoid this issue.

3. **Plugin not in the right directory** — Verify it's at:
   ```
   ~/Library/Application Support/com.elgato.StreamDeck/Plugins/com.chuckconway.pedal-scroll.sdPlugin/
   ```
   Check with: `ls ~/Library/Application\ Support/com.elgato.StreamDeck/Plugins/ | grep pedal`

4. **Stream Deck app needs restart** — After installing a new plugin, the Stream Deck app must be fully restarted (quit and reopen, not just the plugin).

### Stream Deck app shows no window / UI doesn't appear

**Symptom**: The Stream Deck process is running (visible in Activity Monitor) but no window appears.

**Fix**: Run this in Terminal:
```bash
osascript -e 'tell application "Elgato Stream Deck" to activate'
```

This forces the app to bring its window to the foreground. If this happens after clearing preferences, the "show window on launch" setting was lost.

You can also check the menu bar for a Stream Deck icon (small grid of squares) and click it to open the window.

### Scrolling doesn't work after pressing pedal

**Symptom**: You assigned the actions to pedals but nothing happens when you press them.

**Check in order**:

1. **Is Hammerspoon running?** Look for its icon in the menu bar. If not running, launch it from `/Applications/Hammerspoon.app`.

2. **Is the HTTP server active?** You should have seen "Pedal scroll ready (port 27183)" when Hammerspoon loaded. Test manually:
   ```bash
   curl http://127.0.0.1:27183/scroll/down
   ```
   If this returns "ok", Hammerspoon is working. If it fails, reload the Hammerspoon config.

3. **Does Hammerspoon have Accessibility permission?** Check System Settings → Privacy & Security → Accessibility. Hammerspoon must be enabled. Without it, the Hammerspoon console shows: `Unable to create eventtap. Is Accessibility enabled?`

4. **Is the Stream Deck plugin running?** Check in Terminal:
   ```bash
   ps aux | grep "pedal-scroll" | grep -v grep
   ```
   You should see a Node.js process running `plugin.js`. If not, restart the Stream Deck app.

### Scrolling gets stuck (if using Hotkey approach)

This issue occurs when using the Stream Deck's built-in Hotkey action instead of this custom plugin. The Hotkey action simulates keyboard presses, which produces unreliable key repeat behavior — phantom `keyUp` events during a hold, and stale `keyDown` events after release.

**Fix**: Use this custom plugin instead of the Hotkey action. The Stream Deck SDK provides clean `keyDown`/`keyUp` events without key repeat, which is why this plugin exists.

### Hammerspoon shows errors in console

**`Unable to create eventtap`** — Grant Accessibility permission (see above).

**`attempt to call a nil value`** — If you see this for `stopScrolling`, ensure that `stopScrolling` is defined *before* `startScrolling` in the Lua file. Lua resolves functions in order.

### How to check Stream Deck logs

Stream Deck logs are at:
```
~/Library/Logs/ElgatoStreamDeck/StreamDeck.log
```

Search for plugin-related entries:
```bash
grep -i "pedal\|chuckconway" ~/Library/Logs/ElgatoStreamDeck/StreamDeck.log
```

### Port 27183 is already in use

If another service uses port 27183, change it in both files:
- `hammerspoon/init.lua` — `server:setPort(27183)` line
- `src/actions/scroll.ts` — `HAMMERSPOON_URL` constant

Rebuild and redeploy the plugin after changing the port.

## Development

### Building

```bash
npm install
npm run build          # One-time build
npm run watch          # Rebuild on file changes
```

### Testing Changes

After rebuilding:
```bash
# Copy updated plugin
cp -R com.chuckconway.pedal-scroll.sdPlugin \
  ~/Library/Application\ Support/com.elgato.StreamDeck/Plugins/

# Restart just the plugin (requires developer mode)
npx streamdeck restart com.chuckconway.pedal-scroll

# Or restart the entire Stream Deck app
killall "Stream Deck"; sleep 2; open -a "Elgato Stream Deck"
```

### Plugin Logs

```bash
# View plugin logs (requires @elgato/cli)
npx streamdeck log com.chuckconway.pedal-scroll

# Or check directly
ls ~/Library/Logs/ElgatoStreamDeck/com.chuckconway.pedal-scroll*
```

## License

MIT
