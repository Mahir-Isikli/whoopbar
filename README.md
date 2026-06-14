# WhoopBar

Live WHOOP heart rate in your Mac menu bar, plus a local history you own.

## What it does

- Shows your **live heart rate** in the menu bar, read over Bluetooth straight from the strap (read-only, does not disturb your phone).
- Click it for a clean popover: today's recovery / sleep / strain, a **Day view** of today's intraday heart rate, and 7/30/90-day trends. Hover any chart to read the exact value.
- Logs every heart-rate sample to a **local SQLite** database, so you keep an intraday record the WHOOP API never exposes.

## Requirements

- A Mac with Bluetooth (macOS 14+).
- A WHOOP strap (4.0 or 5.0), worn and within range.
- Xcode command line tools (`xcode-select --install`).

## Install (live HR, no account needed)

```bash
git clone <this repo> && cd whoop-menubar
./install.sh
```

A heart appears in your menu bar. Click **Allow** when macOS asks for Bluetooth. Done. Live HR, the Day view, and the local database work immediately.

## Optional: daily trends (Recovery / HRV / Strain / Sleep)

These come from the WHOOP cloud API, so you need your own developer app:

1. Create one at https://developer.whoop.com with redirect URI `http://localhost:8080/callback`.
2. Authorize once and pull your history:

```bash
export WHOOP_CLIENT_ID=...  WHOOP_CLIENT_SECRET=...
python3 collector/whoop_auth.py          # opens browser, saves a token
python3 collector/whoop_collector.py     # writes history.json the app reads
```

3. Re-run the collector on a schedule (cron / launchd) to keep trends fresh.

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
