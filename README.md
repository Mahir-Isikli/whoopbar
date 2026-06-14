# WhoopBar

Live WHOOP heart rate in your Mac menu bar, plus a local history you own.

## What it does

- Shows your **live heart rate** in the menu bar, read over Bluetooth straight from the strap (read-only, does not disturb your phone).
- Click it for a clean popover: today's recovery / sleep / strain, a **Day view** of today's intraday heart rate, and 7/30/90-day trends. Hover any chart to read the exact value.
- Logs every heart-rate sample to a **local SQLite** database, so you keep an intraday record the WHOOP API never exposes.

## Setup

You need: a Mac (macOS 14+) with Bluetooth, a WHOOP strap worn nearby, and Xcode tools (`xcode-select --install`).

### 1. Heart rate, Day view, local history (no account)

```bash
git clone <this repo> && cd whoop-menubar && ./install.sh
```

Click **Allow** when macOS asks for Bluetooth. A heart appears in your menu bar. Done.

### 2. Add daily trends (Recovery / HRV / Strain / Sleep)

These live in WHOOP's cloud, so this part needs a free **WHOOP developer app** (one-time):

1. Go to https://developer.whoop.com, sign in, **Create App**.
2. Redirect URI: `http://localhost:8080/callback`. Enable scopes: recovery, cycles, sleep, workout, profile, offline.
3. Copy the **Client ID** and **Client Secret**, then:

```bash
export WHOOP_CLIENT_ID=...  WHOOP_CLIENT_SECRET=...
python3 collector/whoop_auth.py        # browser consent, once
python3 collector/whoop_collector.py   # pulls your history
```

4. Keep trends fresh, run the collector on a schedule:

```bash
crontab -e
# */30 * * * * cd /ABSOLUTE/path/to/whoop-menubar && WHOOP_CLIENT_ID=xxx WHOOP_CLIENT_SECRET=yyy python3 collector/whoop_collector.py
```

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
