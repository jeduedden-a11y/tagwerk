"""Prints the UDID of an available iPhone (or, with argument "ipad", iPad) simulator with the newest iOS runtime."""
import json
import re
import subprocess
import sys

family = "iPad" if len(sys.argv) > 1 and sys.argv[1] == "ipad" else "iPhone"
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
best = None
for runtime, devices in data["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if not name.startswith(family):
            continue
        preferred = ("Pro" in name and "Max" not in name) if family == "iPhone" else ("Air" in name or "Pro" in name)
        rank = (version, preferred, name)
        if best is None or rank > best[0]:
            best = (rank, d["udid"], name, runtime)
if best is None:
    sys.exit(f"no {family} simulator found")
print(best[1])
print(f"{best[2]} on {best[3]}", file=sys.stderr)
