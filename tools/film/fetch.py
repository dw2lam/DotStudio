#!/usr/bin/env python3
"""Fetches a scene's CC0 assets into the cache (no Blender needed).

    python3 -I tools/film/fetch.py commute          # scenes/commute/assets.json
    python3 -I tools/film/fetch.py --licences       # print the licence log

run.py also fetches anything missing before it builds.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dsfilm import assets  # noqa: E402

if __name__ == "__main__":
    if not sys.argv[1:]:
        raise SystemExit(__doc__)
    if sys.argv[1] == "--licences":
        p = assets.cache("LICENSES.tsv")
        print(open(p).read() if os.path.exists(p) else "(nothing fetched yet)")
        raise SystemExit
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenes", sys.argv[1], "assets.json")) as f:
        refs = json.load(f)
    assets.fetch_all(refs)
    print("ok:", assets.CACHE)
