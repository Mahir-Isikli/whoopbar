#!/usr/bin/env python3
"""One-time WHOOP OAuth. Opens the consent page, catches the code on localhost,
saves tokens to WHOOP_TOKEN_FILE (default ~/.whoop/whoop_tokens.json).

Prereq: create a WHOOP developer app at https://developer.whoop.com with redirect URI
  http://localhost:8080/callback
then set WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET in your environment and run this once.
"""
import http.server, json, os, pathlib, secrets, urllib.parse, urllib.request, webbrowser

CLIENT_ID = os.environ["WHOOP_CLIENT_ID"]
CLIENT_SECRET = os.environ["WHOOP_CLIENT_SECRET"]
REDIRECT = "http://localhost:8080/callback"
TOKEN_FILE = pathlib.Path(os.environ.get("WHOOP_TOKEN_FILE", os.path.expanduser("~/.whoop/whoop_tokens.json")))
SCOPES = "offline read:recovery read:cycles read:sleep read:workout read:profile"
AUTH = "https://api.prod.whoop.com/oauth/oauth2/auth"
TOKEN = "https://api.prod.whoop.com/oauth/oauth2/token"
held = {}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.urlparse(self.path)
        if q.path != "/callback":
            self.send_response(404); self.end_headers(); return
        held["code"] = urllib.parse.parse_qs(q.query).get("code", [None])[0]
        self.send_response(200); self.end_headers()
        self.wfile.write(b"WHOOP connected. You can close this tab.")
    def log_message(self, *a): pass

def main():
    url = AUTH + "?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": CLIENT_ID, "redirect_uri": REDIRECT,
        "scope": SCOPES, "state": secrets.token_urlsafe(8)})
    print("Opening browser for WHOOP consent...\n" + url)
    webbrowser.open(url)
    srv = http.server.HTTPServer(("127.0.0.1", 8080), Handler)
    while "code" not in held:
        srv.handle_request()
    body = urllib.parse.urlencode({
        "grant_type": "authorization_code", "code": held["code"], "redirect_uri": REDIRECT,
        "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET}).encode()
    req = urllib.request.Request(TOKEN, data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "whoopbar/1.0"})
    tok = json.load(urllib.request.urlopen(req, timeout=30))
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(json.dumps({"access_token": tok["access_token"], "refresh_token": tok["refresh_token"]}))
    print("Saved tokens to", TOKEN_FILE)

if __name__ == "__main__":
    main()
