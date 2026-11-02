"""Prints the UDID of an available iPhone simulator with the newest iOS runtime."""
import json
import re
import subprocess
import sys

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
best = None
for runtime, devices in data["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if not name.startswith("iPhone"):
            continue
        rank = (version, "Pro" in name and "Max" not in name, name)
        if best is None or rank > best[0]:
            best = (rank, d["udid"], name, runtime)
if best is None:
    sys.exit("no iPhone simulator found")
print(best[1])
print(f"{best[2]} on {best[3]}", file=sys.stderr)
