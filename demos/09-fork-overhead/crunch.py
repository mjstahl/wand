#!/usr/bin/env python3
"""Idiomatic Python: one pass, counting as it goes."""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wand-demo.log"
counts = {"ERROR": 0, "WARN": 0, "INFO": 0}
error_components = set()

with open(path) as fh:
    for line in fh:
        parts = line.split()
        if len(parts) < 3:
            continue
        level, component = parts[1], parts[2]
        if level in counts:
            counts[level] += 1
        if level == "ERROR":
            error_components.add(component)

for level in ("ERROR", "WARN", "INFO"):
    print(level, counts[level])
print("components-with-errors", len(error_components))
