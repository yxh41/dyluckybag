#!/usr/bin/env python3
"""Poll the GitHub Actions run for a given commit, then fetch its .deb artifacts.

No API token is available in this environment, so the run status comes from the
public REST API and the artifacts come from raw.githubusercontent.com (CI
force-pushes them onto the ci-artifacts-<scheme> branches).
"""
import json
import os
import sys
import time
import urllib.request

REPO = "yxh41/dyluckybag"
SHA = sys.argv[1] if len(sys.argv) > 1 else "f4651be"
OUT = sys.argv[2] if len(sys.argv) > 2 else "output/" + SHA
MAX_WAIT = 40 * 60          # 40 minutes
POLL = 30                   # seconds

LOG = os.path.join(OUT, "poll.log")
os.makedirs(OUT, exist_ok=True)


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def get(url, tries=5):
    for attempt in range(tries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "poll-build", "Accept": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read()
        except Exception as exc:                      # transient resets happen
            if attempt == tries - 1:
                raise
            time.sleep(2 + attempt)
    return None


def find_run():
    data = json.loads(get("https://api.github.com/repos/%s/actions/runs?per_page=10" % REPO))
    for run in data.get("workflow_runs", []):
        if run["head_sha"].startswith(SHA):
            return run
    return None


def download(scheme, name):
    url = "https://raw.githubusercontent.com/%s/ci-artifacts-%s/artifacts/%s" % (REPO, scheme, name)
    dest = os.path.join(OUT, name)
    for attempt in range(6):
        try:
            data = get(url)
            if data:
                with open(dest, "wb") as fh:
                    fh.write(data)
                log("  fetched %-38s %7d bytes" % (name, len(data)))
                return True
        except Exception as exc:
            log("  retry %d for %s (%s)" % (attempt + 1, name, exc))
            time.sleep(3)
    log("  FAILED  %s" % name)
    return False


def main():
    log("waiting for run of %s on %s" % (SHA, REPO))
    started = time.time()
    run = None
    while time.time() - started < MAX_WAIT:
        try:
            run = find_run()
        except Exception as exc:
            log("poll error: %s" % exc)
        if run:
            if run["status"] == "completed":
                break
            log("run #%s status=%s" % (run["run_number"], run["status"]))
        else:
            log("run not visible yet")
        time.sleep(POLL)

    if not run:
        log("TIMEOUT: run never appeared")
        return 2

    log("run #%s %s -> %s" % (run["run_number"], run["status"], run.get("conclusion")))
    if run.get("conclusion") != "success":
        log("BUILD NOT SUCCESSFUL - skipping download")
        return 1

    log("fetching artifacts into %s" % OUT)
    ok = True
    for scheme in ("roothide", "rootless"):
        ok &= download(scheme, "DYLuckyBag-%s.deb" % scheme)
        ok &= download(scheme, "DYLuckyBag-%s-debug.deb" % scheme)
        ok &= download(scheme, "SUMMARY-%s.txt" % scheme)

    # Confirm the artifacts really belong to this commit.
    for scheme in ("roothide", "rootless"):
        path = os.path.join(OUT, "SUMMARY-%s.txt" % scheme)
        if os.path.exists(path):
            log("SUMMARY-%s: %s" % (scheme, open(path, encoding="utf-8").read().strip()))

    log("DONE ok=%s" % ok)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
