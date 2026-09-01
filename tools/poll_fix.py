import sys, time, json, urllib.request, os

REPO = "yxh41/dyluckybag"
SHA = sys.argv[1]
OUT = sys.argv[2]
os.makedirs(OUT, exist_ok=True)

def api(path, attempts=6):
    """GitHub API call with retry.

    The sandbox reaches the network through a proxy that intermittently returns
    "502 Bad Gateway" on CONNECT. A single failure used to abort a 10-minute
    poll, so transient transport errors are retried while real API responses
    (including error statuses) are returned immediately.
    """
    url = f"https://api.github.com/repos/{REPO}/{path}"
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "poll", "Accept": "application/vnd.github+json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            # A real API response (rate limit, 404, ...) - retrying will not help.
            raise
        except Exception as e:
            last = e
            print(f"  api retry {attempt + 1}/{attempts}: {e}", flush=True)
            time.sleep(5 * (attempt + 1))
    raise last

def raw_get(url):
    last = None
    for _ in range(8):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "poll"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception as e:
            last = e
            time.sleep(2)
    raise last

print("waiting for run for", SHA, flush=True)
run = None
for _ in range(180):
    runs = api("actions/runs?per_page=20")
    for r in runs.get("workflow_runs", []):
        if r["head_sha"].startswith(SHA) or r["head_sha"] == SHA:
            run = r
            break
    if run:
        break
    time.sleep(10)
if not run:
    print("NO RUN FOUND", flush=True)
    sys.exit(2)
print("run", run["run_number"], run["id"], run["status"], run["conclusion"], flush=True)

for _ in range(180):
    run = api(f"actions/runs/{run['id']}")
    print("status", run["status"], "conclusion", run["conclusion"], flush=True)
    if run["status"] == "completed":
        break
    time.sleep(10)

if run["conclusion"] != "success":
    print("BUILD NOT SUCCESS:", run["conclusion"], flush=True)
    sys.exit(3)

base = f"https://raw.githubusercontent.com/{REPO}"
for scheme in ("rootless", "roothide"):
    for f in (f"DYLuckyBag-{scheme}.deb", f"DYLuckyBag-{scheme}-debug.deb", f"SUMMARY-{scheme}.txt"):
        url = f"{base}/ci-artifacts-{scheme}/artifacts/{f}"
        try:
            data = raw_get(url)
            open(os.path.join(OUT, f), "wb").write(data)
            print("OK", f, len(data), flush=True)
        except Exception as e:
            print("FAIL", f, e, flush=True)

# verify roothide control no longer depends on libroothide
import lzma, tarfile, io
def members(path):
    d = open(path, "rb").read()
    assert d[:8] == b"!<arch>\n"
    off = 8
    out = {}
    while off < len(d):
        h = d[off:off+60]; off += 60
        n = h[0:16].decode().strip(); s = int(h[48:58].decode().strip())
        c = d[off:off+s]; off += s + (s % 2)
        out[n] = c
    return out

for scheme in ("roothide", "rootless"):
    fn = os.path.join(OUT, f"DYLuckyBag-{scheme}.deb")
    if not os.path.exists(fn):
        print("MISSING", fn, flush=True); continue
    m = members(fn)
    ctl = tarfile.open(fileobj=io.BytesIO(m["control.tar.gz"]), mode="r:gz")
    for t in ctl.getmembers():
        if t.name.endswith("control"):
            txt = ctl.extractfile(t).read().decode()
            has_lib = "libroothide" in txt
            print(f"{scheme}: Depends line present={'libroothide' in txt}", "->",
                  [l for l in txt.splitlines() if l.startswith("Depends")], flush=True)
            print(f"  -> libroothide in Depends? {has_lib}", flush=True)
print("DONE", flush=True)
