# WhoopBar

Live WHOOP heart rate in your Mac menu bar, plus a local history you own.

## What it does

- Shows your **live heart rate** in the menu bar, read over Bluetooth straight from the strap (read-only, does not disturb your phone).
- Click it for a clean popover: today's recovery / sleep / strain, a **Day view** of today's intraday heart rate, and 7/30/90-day trends. Hover any chart to read the exact value.
- Logs every heart-rate sample to a **local SQLite** database, so you keep an intraday record the WHOOP API never exposes.

## Setup

Needs a Mac (macOS 14+) with Bluetooth and a WHOOP strap worn nearby.

> **Wear the strap and turn on Heart Rate Broadcast.** WhoopBar reads heart rate over Bluetooth, but a WHOOP strap doesn't broadcast by default — it only transmits while worn and with broadcast enabled. On your phone, open the **WHOOP app → enable Heart Rate Broadcast** (the Bluetooth-broadcast toggle meant for gym equipment and third-party apps). That's the step that makes the strap show up over Bluetooth; without it WhoopBar has nothing to connect to. Broadcast streams to one device at a time, so free it from any gym equipment or other app first.

WhoopBar is free and open source but **not notarized** (that needs a paid $99/yr Apple account), so macOS adds one small first-launch step. Easiest first:

### Option A — Homebrew (cleanest, opens with no warning)

```bash
brew install --cask Mahir-Isikli/tap/whoopbar
```

The tap clears the macOS quarantine flag for you, so it just opens. Then allow Bluetooth.

### Option B — Download (no Terminal needed)

1. Download `WhoopBar.dmg` from the [releases page](../../releases).
2. Open it, drag **WhoopBar.app** to Applications, then open WhoopBar.
3. macOS blocks it the first time. Get past it **once**, either way:
   - **No Terminal:** after the warning, go to System Settings → Privacy & Security → scroll down → **Open Anyway** → confirm.
   - **One command:** `xattr -dr com.apple.quarantine /Applications/WhoopBar.app`, then open it.
4. It asks **"Start automatically at login?"** and sets it for you. Allow Bluetooth. A heart appears in your menu bar.

> Note: macOS Sequoia (15) removed the old "right-click → Open" shortcut, so the steps above are the current ones.

### Option C — Build from source

Needs Xcode tools (`xcode-select --install`).

```bash
git clone <this repo> && cd whoop-menubar && ./install.sh
```

Allow Bluetooth when asked. Installs as a login item that auto-starts.

### Add the daily trends (Recovery / HRV / Strain / Sleep)

These live in WHOOP's cloud, so you make a free **WHOOP developer app** (their rule, ~2 min, once).

**Easiest: in the app.** Open the menu → **Connect Whoop** and follow the two steps. It opens the page, shows you the exact Redirect URL to copy, and does the login for you. No Terminal.

What you do on Whoop's site (the in-app screen walks you through it):

1. Open **https://developer-dashboard.whoop.com/apps/create** (the app's button does this).
2. Name it anything, paste `http://localhost:8973/callback` as the **Redirect URL**, and tick the read scopes (`read:recovery`, `read:sleep`, `read:cycles`, `read:workout`, `read:profile`). A privacy-policy URL + contact email are required by the form.
3. Click **Create**, then copy the **Client ID** and **Client Secret** into the app and hit Connect.

More background in [Whoop's setup guide](https://developer.whoop.com/docs/developing/getting-started).

<details><summary>Advanced: headless / scripted (no GUI)</summary>

For a server or cron, use the Python collector instead:

```bash
export WHOOP_CLIENT_ID=...  WHOOP_CLIENT_SECRET=...
python3 collector/whoop_auth.py        # browser login, once
python3 collector/whoop_collector.py   # pulls history
./collector/schedule.sh                # refresh every 30 min
```
</details>

## Updating

WhoopBar checks GitHub once a day and shows a small **Update** pill in the popover when a newer version is out. To update:

```bash
brew upgrade --cask whoopbar
```

(Downloaded directly instead? Just grab the latest `WhoopBar.dmg` from the [releases page](../../releases) and replace the app.)

## Where your data lives

`~/Library/Application Support/WhoopBar/`

- `whoop-local.db` - SQLite: live HR samples + daily history.
- `history.json` - daily series for the charts.
- `credentials.json` - your WHOOP API tokens (private to your user account, `0600`).

Everything stays on your machine. Nothing is uploaded.

## Notes

- Capture pauses while the Mac sleeps (Bluetooth suspends), so the intraday trace has gaps overnight.
- To rename for yourself, change the bundle id in `Info.plist`; you will grant Bluetooth once on first launch.

## Releasing (maintainer)

Bump `CFBundleShortVersionString` + `CFBundleVersion` in `Info.plist`, commit, then:

```bash
./ship.sh
```

One command builds the universal DMG, pushes the tag, publishes the GitHub release, and bumps + pushes the Homebrew cask. Users then get it via `brew upgrade` or the in-app pill.

## License

MIT
