#!/usr/bin/env python3
"""Reads `xcrun simctl list devices available -j` from stdin and prints the UDID of the best iPhone.

Prefers the largest current iPhone (needed for 6.9" App Store screenshots) on the newest iOS runtime.
"""
import json
import re
import sys

PREFERRED = ["iPhone 17 Pro Max", "iPhone 16 Pro Max", "iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16"]


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)", identifier)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


def main():
    devices = json.load(sys.stdin)["devices"]
    runtimes = sorted((r for r in devices if "iOS" in r), key=runtime_version, reverse=True)
    for runtime in runtimes:
        available = {d["name"]: d["udid"] for d in devices[runtime] if d.get("isAvailable", True)}
        for name in PREFERRED:
            if name in available:
                print(available[name])
                return
        for name, udid in available.items():
            if name.startswith("iPhone"):
                print(udid)
                return
    sys.exit("Kein iPhone-Simulator gefunden")


if __name__ == "__main__":
    main()
