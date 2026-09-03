#!/usr/bin/env python3
"""Fetch CI .deb artifacts for a given commit via the GitHub *contents* API.

In this environment urllib cannot do HTTPS (no _ssl) and raw.githubusercontent.com
is unreachable, so we route everything through api.github.com (which works), using
curl as the HTTPS transport. CI force-pushes artifacts onto the ci-artifacts-<scheme>
branches at path artifacts/<name>; the contents API returns base64 we decode locally.
"""
import base64
import json
import os
import subprocess
import sys
import time

REPO = "yxh41/dyluckybag"
SHA = sys.argv[1] if len(sys.argv) > 1 else "c102821"
OUT = sys.argv[2] if len(sys.argv) > 2 else "output/" + SHA
MAX_WAIT = 40 * 60
POLL = 20
os.makedirs(OUT, exist_ok=True)


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=90)


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)


def api_get(path):
    """GET a GitHub API path via curl, return parsed JSON (or None)."""
    url = "https://api.github.com/repos/%s/%s" % (REPO, path)
    r = sh('curl -s -m 60 "%s"' % url)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


def find_run():
    d = api_get("actions/runs?per_page=20")
    if not d:
        return None
    for run in d.get("workflow_runs", []):
        if run["head_sha"].startswith(SHA):
            return run
    return None


def download(scheme, name):
    path = "contents/artifacts/%s?ref=ci-artifacts-%s" % (name, scheme)
    d = api_get(path)
    if not isinstance(d, dict) or "content" not in d:
        log("  FAILED  %s (no content field)" % name)
        return False
    data = base64.b64decode("".join(d["content"].split()))
    dest = os.path.join(OUT, name)
    with open(dest, "wb") as fh:
        fh.write(data)
    log("  fetched %-38s %7d bytes" % (name, len(data)))
    return True


def main():
    log("waiting for run of %s" % SHA)
    started = time.time()
    run = None
    while time.time() - started < MAX_WAIT:
        run = find_run()
        if run and run["status"] == "completed":
            break
        log("run status=%s" % (run["status"] if run else "not visible"))
        time.sleep(POLL)

    if not run:
        log("TIMEOUT: run never appeared")
        return 2
    log("run #%s %s -> %s" % (run["run_number"], run["status"], run.get("conclusion")))
    if run.get("conclusion") != "success":
        log("BUILD NOT SUCCESSFUL - aborting download")
        return 1

    ok = True
    for scheme in ("roothide", "rootless"):
        ok &= download(scheme, "DYLuckyBag-%s.deb" % scheme)
        ok &= download(scheme, "DYLuckyBag-%s-debug.deb" % scheme)
        ok &= download(scheme, "SUMMARY-%s.txt" % scheme)

    for scheme in ("roothide", "rootless"):
        p = os.path.join(OUT, "SUMMARY-%s.txt" % scheme)
        if os.path.exists(p):
            log("SUMMARY-%s: %s" % (scheme, open(p, encoding="utf-8").read().strip()))

    log("DONE ok=%s" % ok)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
