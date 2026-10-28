"""
Search the public-apis catalogue (https://github.com/public-apis/public-apis) from the command line.
The upstream repo is a Markdown list, not a package, so we download its README once, cache it,
and parse the tables into records.

  python apifinder.py gold                      keyword search (name + description)
  python apifinder.py -c finance -c "currency exchange" --no-auth
  python apifinder.py --categories              list categories with counts
  python apifinder.py --preset gold             curated categories/keywords for this bot
  python apifinder.py forex --json > forex.json
  python apifinder.py --refresh ...             re-download the list
"""
import argparse
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

README_URL = "https://raw.githubusercontent.com/public-apis/public-apis/master/README.md"
CACHE = Path(__file__).with_name(".cache") / "public-apis.md"
CACHE_TTL = 7 * 86400

# Categories and keywords that matter for gold / BTC scalping signals
PRESETS = {
    "gold": {
        "categories": ["finance", "currency exchange", "cryptocurrency"],
        "keywords": ["gold", "xau", "metal", "commodit", "forex", "fx ", "market data",
                     "intraday", "real-time", "realtime", "historical", "futures", "cfd"],
    },
    "macro": {
        "categories": ["finance", "government", "open data", "news", "calendar"],
        "keywords": ["econom", "macro", "fed", "treasury", "cpi", "inflation", "rates", "sentiment", "news"],
    },
    "crypto": {
        "categories": ["cryptocurrency", "blockchain"],
        "keywords": ["bitcoin", "btc", "exchange", "candle", "ohlc", "market", "price"],
    },
}

_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def load_readme(refresh: bool = False) -> str:
    if refresh or not CACHE.exists() or time.time() - CACHE.stat().st_mtime > CACHE_TTL:
        CACHE.parent.mkdir(exist_ok=True)
        with urllib.request.urlopen(README_URL, timeout=30) as r:
            CACHE.write_bytes(r.read())
    return CACHE.read_text(encoding="utf-8")


def parse(md: str) -> list[dict]:
    apis, category = [], None
    for line in md.splitlines():
        if line.startswith("### "):
            category = line[4:].strip()
            continue
        if not category or not line.startswith("| [") or "APILayer" in category:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        m = _LINK.match(cells[0])
        if not m or len(cells) < 5:
            continue
        auth = cells[2].strip("`")
        apis.append({
            "category": category,
            "name": m.group(1),
            "url": m.group(2),
            "description": cells[1],
            "auth": "" if auth.lower() == "no" else auth,
            "https": cells[3].lower() == "yes",
            "cors": cells[4].lower(),
        })
    return apis


def search(apis, keywords=(), categories=(), no_auth=False, https_only=False):
    cats = {c.lower() for c in categories}
    kws = [k.lower() for k in keywords]
    out = []
    for a in apis:
        if cats and a["category"].lower() not in cats:
            continue
        if no_auth and a["auth"]:
            continue
        if https_only and not a["https"]:
            continue
        hay = f"{a['name']} {a['description']}".lower()
        if kws and not any(k in hay for k in kws):
            continue
        out.append(a)
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description="Search the public-apis catalogue")
    p.add_argument("keywords", nargs="*", help="match any keyword in name/description")
    p.add_argument("-c", "--category", action="append", default=[], help="filter by category (repeatable)")
    p.add_argument("--preset", choices=sorted(PRESETS), help="curated categories + keywords")
    p.add_argument("--no-auth", action="store_true", help="only APIs that need no key")
    p.add_argument("--https", action="store_true", help="only HTTPS APIs")
    p.add_argument("--categories", action="store_true", help="list categories and exit")
    p.add_argument("--json", action="store_true", help="output JSON")
    p.add_argument("--refresh", action="store_true", help="re-download the catalogue")
    args = p.parse_args(argv)

    apis = parse(load_readme(args.refresh))

    if args.categories:
        counts = {}
        for a in apis:
            counts[a["category"]] = counts.get(a["category"], 0) + 1
        for cat, n in sorted(counts.items()):
            print(f"{n:4d}  {cat}")
        print(f"{len(apis):4d}  total")
        return

    keywords, categories = list(args.keywords), list(args.category)
    if args.preset:
        keywords += PRESETS[args.preset]["keywords"]
        categories += PRESETS[args.preset]["categories"]

    hits = search(apis, keywords, categories, args.no_auth, args.https)
    if args.json:
        json.dump(hits, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return
    for a in hits:
        auth = a["auth"] or "no key"
        print(f"[{a['category']}] {a['name']}  ({auth})\n    {a['description']}\n    {a['url']}")
    print(f"\n{len(hits)} match(es)", file=sys.stderr)


if __name__ == "__main__":
    main()
