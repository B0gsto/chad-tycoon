#!/usr/bin/env python3
"""Badges of this game's universe: list them, or create the ones in Theme.Badges that do not exist yet.

usage:
  tools/badges.py list
  tools/badges.py ensure [--icons DIR] [--dry-run]

ensure reads the keys, names and descriptions of Theme.Badges (src/themes/chad/Theme.luau), reuses a badge whose
name already exists on the universe and creates the others with the icon DIR/<Key>.png (default art/out/badges).
It prints one JSON line per badge {"key", "id", "name", "created"} and then the Theme.Badges ids to paste in.
Roblox creates up to 5 badges per universe per day for free; ensure always sends expectedCost=0, so a create that
would cost Robux fails instead of spending.

The universe comes from deploy/target.json. The API key is read like tools/assets.py (never printed); creating
needs the permission legacy-universe.badge:manage-and-spend-robux with the universe added. Listing is public.
Exit codes: 0 ok, 1 API or usage error."""
import argparse, json, os, re, sys, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import assets  # noqa: E402  (shared key handling, HTTP retries and multipart encoding)

THEME = os.path.join(assets.ROOT, "src", "themes", "chad", "Theme.luau")


def universe():
    u = assets.target(assets.ROOT).get("universeId")
    if not u:
        raise SystemExit("deploy/target.json has no universeId")
    return int(u)


def theme_badges():
    text = open(THEME).read()
    block = re.search(r"^Theme\.Badges = \{\n(.*?)^\}", text, re.S | re.M)
    if not block:
        raise SystemExit("Theme.Badges not found in " + THEME)
    out = []
    for m in re.finditer(r'^\t(\w+) = \{ Id = (\d+), Name = "([^"]*)", Desc = "([^"]*)" \},$', block.group(1), re.M):
        out.append({"key": m.group(1), "id": int(m.group(2)), "name": m.group(3), "desc": m.group(4)})
    return out


def list_badges(u):
    out, cursor = [], ""
    for _ in range(50):
        q = urllib.parse.urlencode({"limit": 100, "sortOrder": "Asc", **({"cursor": cursor} if cursor else {})})
        status, raw = assets._http("GET", f"https://badges.roblox.com/v1/universes/{u}/badges?{q}", auth=False)
        if status >= 400:
            raise SystemExit(f"list badges -> HTTP {status}: {raw[:300]!r}")
        body = json.loads(raw)
        out += body.get("data", [])
        cursor = body.get("nextPageCursor")
        if not cursor:
            break
    return out


def create(u, name, desc, icon):
    with open(icon, "rb") as f:
        blob = f.read()
    body, ctype = assets._multipart(
        {"name": name, "description": desc, "paymentSourceType": "1", "expectedCost": "0", "isActive": "true"},
        {"files": (os.path.basename(icon), "image/png", blob)},
    )
    status, raw = assets._http("POST", f"/legacy-badges/v1/universes/{u}/badges", body, ctype)
    if status >= 400:
        raise SystemExit(f"create badge {name!r} -> HTTP {status}: {raw[:500].decode(errors='replace')}")
    return json.loads(raw)["id"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    e = sub.add_parser("ensure")
    e.add_argument("--icons", default=os.path.join(assets.ROOT, "art", "out", "badges"))
    e.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    u = universe()
    existing = list_badges(u)
    if args.cmd == "list":
        for b in existing:
            print(json.dumps({"id": b["id"], "name": b["name"], "enabled": b.get("enabled")}))
        return
    by_name = {b["name"]: b for b in existing}
    ids = {}
    for b in theme_badges():
        found = by_name.get(b["name"])
        icon = os.path.join(args.icons, b["key"] + ".png")
        if found:
            ids[b["key"]] = found["id"]
            print(json.dumps({"key": b["key"], "id": found["id"], "name": b["name"], "created": False}))
        elif args.dry_run:
            print(json.dumps({"key": b["key"], "name": b["name"], "icon": icon, "exists": os.path.isfile(icon)}))
        else:
            if not os.path.isfile(icon):
                raise SystemExit(f"missing icon {icon}")
            ids[b["key"]] = create(u, b["name"], b["desc"], icon)
            print(json.dumps({"key": b["key"], "id": ids[b["key"]], "name": b["name"], "created": True}))
    if ids:
        print("\nTheme.Badges ids:")
        for key, i in ids.items():
            print(f"  {key} = {i}")


if __name__ == "__main__":
    main()
