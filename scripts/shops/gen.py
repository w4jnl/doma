#!/usr/bin/env python3
"""Writes app/shared/Resources/shops.json, the bundled shop table the apps suggest names from
when a card is added: for each chain the name, the website's domain and the countries it trades
in, for the EU, EFTA and the UK. The source is OpenStreetMap's Name Suggestion Index
(BSD-3-Clause, named in NOTICE), from its npm package: the brands of the kinds of shop a family
holds a card of, and its cache of Wikidata for the websites. Names and websites only; no logo is bundled.

    python3 scripts/shops/gen.py            # fetches the pinned version and writes the file
    python3 scripts/shops/gen.py 6.0.20250817

Needs only the standard library and the network.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

VERSION = "6.0.20250817"
BASE = "https://cdn.jsdelivr.net/npm/name-suggestion-index@{v}/"
OUT = Path(__file__).resolve().parents[2] / "app" / "shared" / "Resources" / "shops.json"

# the kinds of shop a loyalty card is for
SHOPS = """supermarket convenience chemist variety_store department_store clothes shoes sports
furniture doityourself hardware electronics books pet garden_centre toys cosmetics perfumery
optician alcohol beverages bakery butcher kiosk mall bicycle outdoor stationery houseware kitchen
baby_goods jewelry mobile_phone frozen_food health_food coffee tea fashion_accessories bag
car_parts tyres paint lighting bed interior_decoration greengrocer deli cheese video_games
computer hifi appliance music party gift craft florist travel_agency second_hand tobacco
newsagent""".split()
AMENITIES = "fuel pharmacy cafe fast_food restaurant cinema car_wash ice_cream".split()

# EU, EFTA and the UK, as the index spells them (fx is metropolitan France)
COUNTRIES = set("""at be bg hr cy cz dk ee fi fr fx de gr hu ie it lv lt lu mt nl pl pt ro sk si es se
is li no ch gb gi""".split())
# the index's codes for everywhere and for Europe
REGIONS = {"001", "150", "eu"}


def fetch(path, v):
    with urllib.request.urlopen(BASE.format(v=v) + path, timeout=120) as r:
        return json.load(r)


def domain(url):
    """ah.nl from https://www.ah.nl/bonus: the registrable host, as logo.dev wants it."""
    m = re.match(r"^(?:https?://)?([^/?#]+)", url.strip())
    if not m:
        return None
    host = m.group(1).lower().split("@")[-1].split(":")[0]
    if host.startswith("www."):
        host = host[4:]
    return host if "." in host else None


def countries(item):
    inc = [c for c in item.get("locationSet", {}).get("include", []) if isinstance(c, str)]
    if any(c in REGIONS for c in inc):
        return ["eu"]
    out = sorted({"fr" if c == "fx" else c for c in inc if c in COUNTRIES})
    return out


def main():
    v = sys.argv[1] if len(sys.argv) > 1 else VERSION
    wikidata = fetch("dist/wikidata.min.json", v)["wikidata"]
    # the whole index in one file, keyed by its tree path
    nsi = fetch("dist/nsi.min.json", v)["nsi"]
    shops = {}
    for group, kinds in (("shop", SHOPS), ("amenity", AMENITIES)):
        for kind in kinds:
            data = nsi.get(f"brands/{group}/{kind}")
            if data is None:
                print(f"skip {group}/{kind}: not in the index", file=sys.stderr)
                continue
            for item in data.get("items", []):
                cs = countries(item)
                if not cs:
                    continue
                tags = item.get("tags", {})
                name = tags.get("brand") or tags.get("name") or item.get("displayName")
                if not name:
                    continue
                d = None
                q = tags.get("brand:wikidata")
                if q and q in wikidata:
                    w = wikidata[q]
                    site = (w.get("identities") or {}).get("website") or next(iter(w.get("officialWebsites") or []), None)
                    if site:
                        d = domain(site)
                key = (name.lower(), d)
                have = shops.get(key)
                if have:
                    if cs != ["eu"] and have["c"] != ["eu"]:
                        have["c"] = sorted(set(have["c"]) | set(cs))
                    elif cs == ["eu"]:
                        have["c"] = ["eu"]
                    continue
                entry = {"n": name, "c": cs}
                if d:
                    entry["d"] = d
                shops[key] = entry
    rows = sorted(shops.values(), key=lambda s: (s["n"].lower(), s.get("d", "")))
    out = {"_source": f"name-suggestion-index {v}, BSD-3-Clause; names and websites only, see scripts/shops/gen.py", "shops": rows}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    with_site = sum(1 for s in rows if "d" in s)
    print(f"{len(rows)} shops, {with_site} with a website, {OUT.stat().st_size // 1024} KB -> {OUT}")


if __name__ == "__main__":
    main()
