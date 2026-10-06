#!/usr/bin/env python3
"""Developer products and game passes of this game's universe, through Open Cloud.

usage:
  tools/monetization.py list [--json]
  tools/monetization.py ensure-product --name N --description D --price R [--icon PNG] [--off-sale]
  tools/monetization.py ensure-pass    --name N --description D --price R [--icon PNG] [--off-sale]
  tools/monetization.py update-product --id ID [--name N] [--description D]
  tools/monetization.py update-pass    --id ID [--name N] [--description D]

ensure-* is idempotent: it lists the universe's items first and reuses an item whose name matches exactly
(it never changes the price, sale state or icon of an existing item; a mismatch is only reported). Otherwise it
creates the item. It prints one JSON line {"kind", "id", "name", "price", "isForSale", "created"}.
update-* changes only the name and/or description of the item with that id (multipart PATCH), then prints the
item as read back, with its description.

The universe comes from deploy/target.json. The API key is read from ~/RobloxProjects/.roblox-api-key (same
handling as tools/assets.py) and is never printed. Needed key permissions, with the universe added under each:
developer-product:read / developer-product:write and game-pass:read / game-pass:write.
Exit codes: 0 ok, 1 API or usage error, 2 more than one existing item with the same name."""
import argparse, json, os, sys, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import assets  # noqa: E402  (shared key handling, HTTP retries and multipart encoding)

KINDS = {
    "product": ("/developer-products/v2/universes/{u}/developer-products", "productId", "developerProducts"),
    "pass": ("/game-passes/v1/universes/{u}/game-passes", "gamePassId", "gamePasses"),
}


class ApiError(Exception):
    pass


def universe():
    u = assets.target(assets.ROOT).get("universeId")
    if not u:
        raise SystemExit("deploy/target.json has no universeId")
    return int(u)


def call(method, path, fields=None, files=None):
    body = ctype = None
    if fields is not None or files is not None:
        body, ctype = assets._multipart(fields or {}, files or {})
    status, raw = assets._http(method, path, body, ctype)
    text = raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw)
    if status >= 400:
        raise ApiError(f"{method} {path} -> HTTP {status}: {text[:500]}")
    return json.loads(text) if text[:1] in ("{", "[") else {}


def list_items(kind, u):
    base, id_field, list_key = KINDS[kind]
    base = base.format(u=u)
    out, token = [], None
    for _ in range(100):
        params = {"pageSize": 50, **({"pageToken": token} if token else {})}
        body = call("GET", f"{base}/creator?{urllib.parse.urlencode(params)}")
        entries = body.get(list_key) or []
        out += entries
        token = body.get("nextPageToken")
        if not token or not entries:
            return out
    raise ApiError(f"pagination of {base}/creator did not finish")


def summary(kind, e, created=False):
    _, id_field, _ = KINDS[kind]
    price = (e.get("priceInformation") or {}).get("defaultPriceInRobux")
    return {"kind": kind, "id": int(e[id_field]), "name": e.get("name"), "price": price,
            "isForSale": e.get("isForSale"), "created": created}


def ensure(kind, u, name, description, price, icon, for_sale):
    base, id_field, _ = KINDS[kind]
    base = base.format(u=u)
    matches = [e for e in list_items(kind, u) if e.get("name") == name]
    if len(matches) > 1:
        print(f"{len(matches)} existing {kind}s are named {name!r}; resolve on the dashboard first", file=sys.stderr)
        sys.exit(2)
    if matches:
        s = summary(kind, matches[0])
        if s["price"] != price or bool(s["isForSale"]) != for_sale:
            print(f"note: reused {name!r} differs (price {s['price']}, for sale {s['isForSale']}); not changed",
                  file=sys.stderr)
        return s
    fields = {"name": name, "description": description, "price": str(int(price)),
              "isForSale": "true" if for_sale else "false"}
    files = {}
    if icon:
        with open(icon, "rb") as f:
            files["imageFile"] = (os.path.basename(icon), "image/png", f.read())
    try:
        created = call("POST", base, fields, files)
    except ApiError:
        # A create can go through despite an error: look again before reporting failure (never blind-retry).
        time.sleep(3)
        again = [e for e in list_items(kind, u) if e.get("name") == name]
        if again:
            return summary(kind, again[0], created=True)
        raise
    if id_field not in created:
        time.sleep(2)
        again = [e for e in list_items(kind, u) if e.get("name") == name]
        if not again:
            raise ApiError(f"POST {base} returned no {id_field}: {json.dumps(created)[:300]}")
        created = again[0]
    else:
        # the create response may omit price fields: read the item back from the list
        again = [e for e in list_items(kind, u) if e.get("name") == name]
        created = again[0] if again else created
    return summary(kind, created, created=True)


def update(kind, u, item_id, name=None, description=None):
    """Changes only the name and/or description of one existing item, then reads it back."""
    base, id_field, _ = KINDS[kind]
    fields = {k: v for k, v in (("name", name), ("description", description)) if v is not None}
    if not fields:
        raise SystemExit("update: give --name and/or --description")
    call("PATCH", f"{base.format(u=u)}/{int(item_id)}", fields)
    again = [e for e in list_items(kind, u) if int(e[id_field]) == int(item_id)]
    if not again:
        raise ApiError(f"{kind} {item_id} not found after update")
    s = summary(kind, again[0])
    s["description"] = again[0].get("description")
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list")
    ls.add_argument("--json", action="store_true")
    for cmd in ("ensure-product", "ensure-pass"):
        p = sub.add_parser(cmd)
        p.add_argument("--name", required=True)
        p.add_argument("--description", required=True)
        p.add_argument("--price", type=int, required=True)
        p.add_argument("--icon")
        p.add_argument("--off-sale", action="store_true")
    for cmd in ("update-product", "update-pass"):
        p = sub.add_parser(cmd)
        p.add_argument("--id", type=int, required=True)
        p.add_argument("--name")
        p.add_argument("--description")
    a = ap.parse_args()
    u = universe()
    try:
        if a.cmd == "list":
            rows = [summary(k, e) for k in KINDS for e in list_items(k, u)]
            if a.json:
                print(json.dumps(rows, indent=2))
            else:
                print(f"universe {u}: {len(rows)} item(s)")
                for r in rows:
                    print(f"  {r['kind']:<8}{r['id']:<14}R${r['price']!s:<6}{'on sale ' if r['isForSale'] else 'off sale'}  {r['name']}")
            return
        if a.cmd in ("update-product", "update-pass"):
            kind = "product" if a.cmd == "update-product" else "pass"
            print(json.dumps(update(kind, u, a.id, a.name, a.description)))
            return
        if a.icon and not os.path.isfile(a.icon):
            raise SystemExit(f"missing icon {a.icon}")
        kind = "product" if a.cmd == "ensure-product" else "pass"
        print(json.dumps(ensure(kind, u, a.name, a.description, a.price, a.icon, not a.off_sale)))
    except ApiError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
