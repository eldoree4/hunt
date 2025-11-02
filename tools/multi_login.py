#!/usr/bin/env python3
"""
multi_login.py
Basic multi-step login helper with CSRF extraction (Author: JFlow)

Usage:
  python3 multi_login.py <login_page_url> <username> <password> [--action=<action_url>]

Returns:
  On success prints "OK cookie=<cookie-string>" to stdout so caller can parse cookie.
  On failure exits non-zero and prints reason to stderr.

Notes:
  - Lightweight: uses requests + bs4 for form parsing. Not a full browser automation.
  - For JS-heavy login flows, use headless renderer + manual steps or Selenium/Puppeteer scripts.
"""

import sys
import requests
from bs4 import BeautifulSoup
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("login_page")
parser.add_argument("username")
parser.add_argument("password")
parser.add_argument("--action", help="Explicit form action URL", default=None)
args = parser.parse_args()

session = requests.Session()
session.headers.update({"User-Agent": "Hunt-Scanner/2.1-prod (JFlow)"})

try:
    r = session.get(args.login_page, timeout=15, allow_redirects=True)
except Exception as e:
    print("ERROR: Failed to fetch login page: {}".format(e), file=sys.stderr)
    sys.exit(2)

soup = BeautifulSoup(r.text, "html.parser")
form = soup.find("form")
if not form:
    print("ERROR: No form found on login page", file=sys.stderr)
    sys.exit(3)

action = args.action or form.get("action") or args.login_page
method = form.get("method", "post").lower()
inputs = {}
for inp in form.find_all("input"):
    name = inp.get("name")
    if not name:
        continue
    val = inp.get("value", "")
    inputs[name] = val

# Attempt to find CSRF token names commonly used
csrf_name_candidates = ['csrf', 'csrf_token', '_csrf', 'authenticity_token', 'token']
for k in csrf_name_candidates:
    if k in inputs:
        csrf_name = k
        break
else:
    csrf_name = None

# Insert credentials to common field names
common_user_fields = ['username', 'user', 'email', 'login']
common_pass_fields = ['password', 'pass', 'pwd']
for u_field in common_user_fields:
    if u_field in inputs:
        inputs[u_field] = args.username
        break
else:
    # fallback: try to find input type text with no name mapping - skip
    pass

for p_field in common_pass_fields:
    if p_field in inputs:
        inputs[p_field] = args.password
        break

# If no recognized username/password fields, try some heuristics
if not any(k in inputs for k in common_user_fields):
    # find first text input and set
    text_inputs = form.find_all("input", {"type": "text"})
    if text_inputs:
        name = text_inputs[0].get("name")
        inputs[name] = args.username
if not any(k in inputs for k in common_pass_fields):
    pass_inputs = form.find_all("input", {"type": "password"})
    if pass_inputs:
        name = pass_inputs[0].get("name")
        inputs[name] = args.password

# Submit
try:
    if method == 'post':
        resp = session.post(action, data=inputs, timeout=15, allow_redirects=True)
    else:
        resp = session.get(action, params=inputs, timeout=15, allow_redirects=True)
except Exception as e:
    print("ERROR: Login submission failed: {}".format(e), file=sys.stderr)
    sys.exit(4)

# Heuristic success: presence of session cookies or HTTP 200 vs redirect
cookies = session.cookies.get_dict()
if cookies:
    cookie_str = "; ".join([f"{k}={v}" for k, v in cookies.items()])
    print(f"OK cookie={cookie_str}")
    sys.exit(0)
else:
    # Look for common phrases indicating logged-in (logout, dashboard)
    if "logout" in resp.text.lower() or "dashboard" in resp.text.lower():
        # If cookies absent but body contains login markers, return ok
        print("OK cookie=")
        sys.exit(0)
    print("ERROR: Login likely failed", file=sys.stderr)
    sys.exit(5)
