#!/usr/bin/env python3
"""Summarises tools/perf/ab.sh output: per row, BASE → NEW (lowest CPU of the rounds; allocation,
file-system and wake-up figures from the same round). usage: abtable.py ab-output.txt"""
import re, sys

rows = {}
which = None
order = []
pat = re.compile(r"^(.{24}) +(\d+) fps +(\d+) fr \| call +([\d.]+) ms +main +([\d.]+) ms +proc +([\d.]+) ms \| "
                 r"allocs +([\w.]+) / +([\d.]+) \| fs +([\d.]+) stat/s +([\d.]+) io/s \| wk +([\d.]+)/s")
for line in open(sys.argv[1]):
    if line.startswith("== "):
        which = line.split()[1]
        continue
    m = pat.match(line)
    if not m:
        continue
    key = (m.group(1).strip(), int(m.group(2)))
    if key not in order:
        order.append(key)
    v = dict(call=float(m.group(4)), main=float(m.group(5)), proc=float(m.group(6)),
             tallocs=m.group(7), allocs=float(m.group(8)), stat=float(m.group(9)), io=float(m.group(10)),
             wk=float(m.group(11)))
    best = rows.setdefault(key, {}).get(which)
    if best is None or v["call"] < best["call"]:
        rows[key][which] = v

def f(b, n, k, fmt="%.3f"):
    if b is None or n is None:
        return "-"
    return (fmt % b[k]) + " → " + (fmt % n[k])

print("| style | fps | frame call CPU ms | process CPU ms/frame | allocs/frame (frame thread) | allocs/frame (process) | stat/s | reads+opens/s |")
print("|---|---|---|---|---|---|---|---|")
for key in order:
    b, n = rows[key].get("BASE"), rows[key].get("NEW")
    ta = "%s → %s" % (b["tallocs"] if b else "-", n["tallocs"] if n else "-")
    print("| %s | %d | %s | %s | %s | %s | %s | %s |" % (key[0], key[1], f(b, n, "call"), f(b, n, "proc"), ta,
          f(b, n, "allocs", "%.1f"), f(b, n, "stat", "%.1f"), f(b, n, "io", "%.1f")))
