# WhoopBar

Live WHOOP heart rate in your Mac menu bar, plus a local history you own.

## What it does

- Shows your **live heart rate** in the menu bar, read over Bluetooth straight from the strap (read-only, does not disturb your phone).
- Click it for a clean popover: today's recovery / sleep / strain, a **Day view** of today's intraday heart rate, and 7/30/90-day trends. Hover any chart to read the exact value.
- Logs every heart-rate sample to a **local SQLite** database, so you keep an intraday record the WHOOP API never exposes.

## Setup

Needs a Mac (macOS 14+) with Bluetooth and a WHOOP strap worn nearby.

### Option A — Download (no Terminal)

1. Download `WhoopBar.zip` from the [releases page](../../releases).
2. Unzip, drag **WhoopBar.app** to Applications.
3. **Right-click it → Open** (once; it's free and unsigned, so macOS asks the first time).
4. On first launch it asks **"Start automatically at login?"** and sets it for you. Click **Allow** for Bluetooth. A heart appears in your menu bar.

### Option B — Build from source

Needs Xcode tools (`xcode-select --install`).

```bash
git clone <this repo> && cd whoop-menubar && ./install.sh
```

Allow Bluetooth when asked. Installs as a login item that auto-starts.

### Add the daily trends (Recovery / HRV / Strain / Sleep)

These live in WHOOP's cloud, so you make a free **WHOOP developer app**. ~5 minutes, once.

1. Open **https://developer.whoop.com** and sign in with your normal WHOOP login.
2. Click **Create App** and fill in:
   - **Name:** anything, e.g. `WhoopBar`
   - **Redirect URIs:** `http://localhost:8973/callback`
   - **Scopes:** tick `read:recovery`, `read:cycles`, `read:sleep`, `read:workout`, `read:profile`, `offline`
   - **Privacy policy / contacts:** any valid URL / your email (required by the form, not used)
3. Click **Create**. Copy the **Client ID** and **Client Secret** it shows you.
4. In Terminal, from the project folder:

```bash
export WHOOP_CLIENT_ID=paste-id  WHOOP_CLIENT_SECRET=paste-secret
python3 collector/whoop_auth.py        # a browser opens — click Approve, once
python3 collector/whoop_collector.py   # pulls your history; trends appear in WhoopBar
./collector/schedule.sh                # keeps them fresh (runs every 30 min)
```

That's it. No re-typing later, `schedule.sh` handles the refresh for you.

## Where your data lives

`~/Library/Application Support/WhoopBar/`

- `whoop-local.db` - SQLite: live HR samples + daily history.
- `history.json` - daily series for the charts.

Everything stays on your machine. Nothing is uploaded.

## Notes

- Capture pauses while the Mac sleeps (Bluetooth suspends), so the intraday trace has gaps overnight.
- To rename for yourself, change the bundle id in `Info.plist`; you will grant Bluetooth once on first launch.

## License

MIT
