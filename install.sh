#!/bin/bash
set -e

PLUGIN_DIR="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins"
PLUGIN_NAME="com.chuckconway.pedal-scroll.sdPlugin"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

echo "=== Stream Deck Pedal Scroll Installer ==="
echo ""

# --- Hammerspoon ---
if [ -d "/Applications/Hammerspoon.app" ]; then
    echo "[OK] Hammerspoon is installed"
else
    echo "[INSTALL] Installing Hammerspoon via Homebrew..."
    brew install --cask hammerspoon
    echo "[OK] Hammerspoon installed"
fi

# Deploy Hammerspoon config
mkdir -p "$HAMMERSPOON_DIR"
if [ -f "$HAMMERSPOON_DIR/init.lua" ]; then
    echo "[WARN] Existing Hammerspoon config found at $HAMMERSPOON_DIR/init.lua"
    echo "       Backing up to $HAMMERSPOON_DIR/init.lua.backup"
    cp "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.backup"
fi
cp hammerspoon/init.lua "$HAMMERSPOON_DIR/init.lua"
echo "[OK] Hammerspoon config deployed"

# --- Stream Deck Plugin ---
if ! command -v npm &> /dev/null; then
    echo "[ERROR] npm is not installed. Install Node.js first: brew install node"
    exit 1
fi

echo "[BUILD] Installing dependencies..."
npm install --silent

echo "[BUILD] Building plugin..."
npm run build --silent

# Copy plugin (not symlink — avoids developer mode requirement)
if [ -d "$PLUGIN_DIR/$PLUGIN_NAME" ]; then
    echo "[UPDATE] Removing existing plugin..."
    rm -rf "$PLUGIN_DIR/$PLUGIN_NAME"
fi

echo "[DEPLOY] Copying plugin to Stream Deck..."
cp -R "$PLUGIN_NAME" "$PLUGIN_DIR/"
echo "[OK] Plugin deployed"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Manual steps required:"
echo ""
echo "1. LAUNCH HAMMERSPOON"
echo "   Open /Applications/Hammerspoon.app"
echo "   Grant Accessibility permission when prompted:"
echo "   System Settings > Privacy & Security > Accessibility > enable Hammerspoon"
echo "   Set it to launch at login: menu bar icon > Preferences > Launch at login"
echo ""
echo "2. RESTART STREAM DECK APP"
echo "   Quit and reopen the Elgato Stream Deck app to load the new plugin."
echo "   If the window doesn't appear, run:"
echo "   osascript -e 'tell application \"Elgato Stream Deck\" to activate'"
echo ""
echo "3. ASSIGN PEDALS"
echo "   In the Stream Deck app:"
echo "   - Find 'Pedal Scroll' in the action list"
echo "   - Drag 'Scroll Up' to the left pedal"
echo "   - Drag 'Cycle Speed' to the middle pedal"
echo "   - Drag 'Scroll Down' to the right pedal"
echo ""
echo "4. TEST"
echo "   Open a browser with a long page. Hold the right pedal to scroll down."
echo "   Tap the middle pedal to cycle speed (Slow / Medium / Fast)."
echo ""
