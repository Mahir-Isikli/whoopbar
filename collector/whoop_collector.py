#!/usr/bin/env python3
"""Fetch your WHOOP daily history into history.json for WhoopBar's trend charts.

Refreshes the access token itself (it is the only consumer of the token file), pulls
recovery / sleep / cycles / workouts, and writes <OUT_DIR>/history.json + latest.json.
Run on a schedule (launchd/cron). Env:
  WHOOP_CLIENT_ID, WHOOP_CLIENT_SECRET   from your WHOOP developer app
  WHOOP_TOKEN_FILE  default ~/.whoop/whoop_tokens.json        (created by whoop_auth.py)
  WHOOP_OUT_DIR     default ~/Library/Application Support/WhoopBar
"""
import json, os, pathlib, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

CLIENT_ID = os.environ["WHOOP_CLIENT_ID"]
CLIENT_SECRET = os.environ["WHOOP_CLIENT_SECRET"]
TOKEN_FILE = pathlib.Path(os.environ.get("WHOOP_TOKEN_FILE", os.path.expanduser("~/.whoop/whoop_tokens.json")))
OUT_DIR = pathlib.Path(os.environ.get("WHOOP_OUT_DIR", os.path.expanduser("~/Library/Application Support/WhoopBar")))
API = "https://api.prod.whoop.com/developer"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"
UA = "whoopbar-collector/1.0"

def refresh_token():
    tok = json.load(open(TOKEN_FILE))
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
        "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET, "scope": "offline"}).encode()
    req = urllib.request.Request(TOKEN_URL, data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA})
    new = json.load(urllib.request.urlopen(req, timeout=30))
    tok["access_token"] = new["access_token"]
    if new.get("refresh_token"):
        tok["refresh_token"] = new["refresh_token"]   # single-use tokens rotate; save the new one
    TOKEN_FILE.write_text(json.dumps(tok))
    return tok["access_token"]

def api_get(url, at):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + at, "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def fetch_all(path, at):
    out, url = [], API + path + "?limit=25"
    while url:
        d = api_get(url, at)
        out.extend(d.get("records", []))
        nt = d.get("next_token")
        url = API + path + "?limit=25&nextToken=" + nt if nt else None
        time.sleep(0.3)
    return out

def write_atomic(path, obj):
    tmp = str(path) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)

def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    at = refresh_token()
    recovery = fetch_all("/v2/recovery", at)
    sleep    = fetch_all("/v2/activity/sleep", at)
    cycles   = fetch_all("/v2/cycle", at)
    workouts = fetch_all("/v2/activity/workout", at)

    rec_by_cycle = {r["cycle_id"]: (r.get("score") or {}) for r in recovery if r.get("score_state") == "SCORED"}
    sleeps_by_cycle = {}
    for s in sleep:
        if s.get("score_state") != "SCORED" or s.get("nap"):
            continue
        cur = sleeps_by_cycle.get(s.get("cycle_id"))
        ss = (s.get("score") or {}).get("stage_summary") or {}
        if not cur or (ss.get("total_in_bed_time_milli") or 0) > (cur[1] or 0):
            sleeps_by_cycle[s.get("cycle_id")] = (s.get("score") or {}, ss.get("total_in_bed_time_milli"), ss)

    days = []
    for c in sorted([c for c in cycles if c.get("score_state") == "SCORED"], key=lambda x: x.get("start") or ""):
        cs = c.get("score") or {}
        r = rec_by_cycle.get(c["id"], {})
        sc = sleeps_by_cycle.get(c["id"])
        sleep_hours = None
        if sc:
            in_bed, awake = (sc[2].get("total_in_bed_time_milli") or 0), (sc[2].get("total_awake_time_milli") or 0)
            sleep_hours = round((in_bed - awake) / 3.6e6, 2)
        days.append({
            "date": (c.get("start") or "")[:10],
            "strain": round(cs["strain"], 2) if cs.get("strain") is not None else None,
            "avg_hr": cs.get("average_heart_rate"), "max_hr": cs.get("max_heart_rate"),
            "recovery": r.get("recovery_score"),
            "hrv": round(r["hrv_rmssd_milli"], 1) if r.get("hrv_rmssd_milli") is not None else None,
            "rhr": r.get("resting_heart_rate"), "spo2": r.get("spo2_percentage"),
            "sleep_perf": (sc[0].get("sleep_performance_percentage") if sc else None),
            "sleep_hours": sleep_hours,
        })

    now = datetime.now(timezone.utc).isoformat()
    write_atomic(OUT_DIR / "history.json", {"generated_at": now, "days": days})
    latest = {
        "generated_at": now,
        "latest_recovery": max(recovery, key=lambda r: r.get("updated_at") or "", default=None),
        "latest_sleep": max([s for s in sleep if not s.get("nap")], key=lambda s: s.get("start") or "", default=None),
        "current_cycle": max(cycles, key=lambda c: c.get("start") or "", default=None),
        "latest_workout": max(workouts, key=lambda w: w.get("start") or "", default=None),
        "totals": {"recovery": len(recovery), "sleep": len(sleep), "cycle": len(cycles), "workout": len(workouts)},
    }
    write_atomic(OUT_DIR / "latest.json", latest)
    print(f"{now} wrote {len(days)} days to {OUT_DIR/'history.json'}")

if __name__ == "__main__":
    main()
