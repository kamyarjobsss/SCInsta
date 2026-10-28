#!/usr/bin/env python3
"""Story-tray admin for the Instagram X panel at /opt/igx.

The app already syncs custom sticker packs from the signed config and, on
tray load, POSTs /api/v1/stickers/defaults. This module stores that report,
the hide/show flags, and the order. merge_into_config() must run inside the
existing signer, before the Ed25519 signature, so hidden_defaults and
default_order are part of the payload the app verifies.

Deploy (the panel host was not reachable for a code drop):
  1. Copy this file to /opt/igx/igx_stickers.py
  2. In the process that builds GET /api/v1/config, before signing:
       from igx_stickers import merge_into_config
       merge_into_config(payload)
  3. Route POST /api/v1/stickers/defaults to handle_defaults(authorization, body).
     Pass the same bearer check register already uses:
       from igx_stickers import set_device_authorizer
       set_device_authorizer(existing_device_ok)
     Until that callback is set, IGX_STICKER_OPEN_BEARER=1 accepts any
     non-empty bearer so a device can report. Turn it off after wiring.
  4. Serve the admin page from admin_html() at a path only the operator
     opens, gated by IGX_ADMIN_TOKEN (header X-Admin-Token or ?token=).
     admin_apply(token, form) saves hide/show, order, and an uploaded file
     into /opt/igx/static/stickers plus data/custom_stickers.json.
  5. Restart the panel process and open the admin page. The next config
     sync carries hidden_defaults and default_order. Custom files must be
     reachable at /static/stickers/<filename>.

Data lives in IGX_DATA (default /opt/igx/data) and IGX_STATIC
(default /opt/igx/static/stickers). A local self-test uses a temp directory
and does not touch /opt/igx.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Callable

_authorizer: Callable[[str], bool] | None = None


def set_device_authorizer(fn: Callable[[str], bool]) -> None:
    global _authorizer
    _authorizer = fn


def data_dir() -> Path:
    path = Path(os.environ.get("IGX_DATA", "/opt/igx/data"))
    path.mkdir(parents=True, exist_ok=True)
    return path


def static_dir() -> Path:
    path = Path(os.environ.get("IGX_STATIC", "/opt/igx/static/stickers"))
    path.mkdir(parents=True, exist_ok=True)
    return path


def _state_path() -> Path:
    return data_dir() / "sticker_tray.json"


def load_state() -> dict:
    path = _state_path()
    if not path.is_file():
        return {"defaults": {}, "custom": []}
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {"defaults": {}, "custom": []}
    if not isinstance(raw, dict):
        return {"defaults": {}, "custom": []}
    raw.setdefault("defaults", {})
    raw.setdefault("custom", [])
    return raw


def save_state(state: dict) -> None:
    _state_path().write_text(json.dumps(state, indent=2, sort_keys=True))


def device_ok(authorization: str) -> bool:
    if _authorizer is not None:
        return bool(_authorizer(authorization or ""))
    if os.environ.get("IGX_STICKER_OPEN_BEARER") != "1":
        return False
    token = (authorization or "").strip()
    return token.lower().startswith("bearer ") and len(token) > 12


def handle_defaults(authorization: str, body: bytes) -> tuple[int, dict]:
    if not device_ok(authorization):
        return 401, {"error": "unauthorized"}
    try:
        payload = json.loads(body.decode() or "{}")
    except json.JSONDecodeError:
        return 400, {"error": "bad json"}
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        return 400, {"error": "items"}
    state = load_state()
    defaults = state["defaults"]
    accepted = 0
    for item in items[:80]:
        if not isinstance(item, dict):
            continue
        ident = item.get("id")
        if not isinstance(ident, str) or not ident or len(ident) > 96:
            continue
        prev = defaults.get(ident) if isinstance(defaults.get(ident), dict) else {}
        thumb = item.get("thumbnail") if isinstance(item.get("thumbnail"), str) else ""
        if len(thumb) > 20000:
            thumb = ""
        defaults[ident] = {
            "id": ident,
            "type": item.get("type") if isinstance(item.get("type"), str) else "",
            "name": item.get("name") if isinstance(item.get("name"), str) else "",
            "thumbnail": thumb or prev.get("thumbnail") or "",
            "hidden": bool(prev.get("hidden")),
            "order": int(prev.get("order") or accepted),
        }
        accepted += 1
    state["defaults"] = defaults
    save_state(state)
    return 200, {"ok": True, "count": accepted}


def merge_into_config(payload: dict) -> None:
    """Insert hidden ids, order, and uploaded packs before the config is signed."""
    if not isinstance(payload, dict):
        return
    state = load_state()
    stickers = payload.get("stickers")
    if not isinstance(stickers, dict):
        stickers = {"category": "Instagram X", "packs": []}
        payload["stickers"] = stickers
    rows = [row for row in state["defaults"].values() if isinstance(row, dict) and isinstance(row.get("id"), str)]
    rows.sort(key=lambda row: (int(row.get("order") or 0), row["id"]))
    stickers["hidden_defaults"] = [row["id"] for row in rows if row.get("hidden")]
    stickers["default_order"] = [row["id"] for row in rows if not row.get("hidden")]
    packs = stickers.get("packs")
    if not isinstance(packs, list):
        packs = []
        stickers["packs"] = packs
    custom = [row for row in state["custom"] if isinstance(row, dict)]
    if not custom:
        return
    packs.append({
        "id": 9001,
        "name": "Wexpid",
        "order": 0,
        "stickers": custom,
    })


def admin_ok(token: str) -> bool:
    expected = os.environ.get("IGX_ADMIN_TOKEN", "")
    return bool(expected) and token == expected


def admin_html(token: str) -> tuple[int, str]:
    if not admin_ok(token):
        return 401, "unauthorized"
    state = load_state()
    rows = []
    for row in sorted(state["defaults"].values(), key=lambda item: (int(item.get("order") or 0), item.get("id", ""))):
        checked = " checked" if row.get("hidden") else ""
        rows.append(
            "<tr><td>{id}</td><td>{name}</td><td>{typ}</td>"
            "<td><input name=\"hidden\" value=\"{id}\" type=\"checkbox\"{checked}></td>"
            "<td><input name=\"order_{id}\" value=\"{order}\" size=\"4\"></td></tr>".format(
                id=_esc(row.get("id", "")),
                name=_esc(row.get("name", "")),
                typ=_esc(row.get("type", "")),
                checked=checked,
                order=int(row.get("order") or 0),
            )
        )
    custom = "".join("<li>{}</li>".format(_esc(item.get("name") or item.get("url", ""))) for item in state["custom"] if isinstance(item, dict))
    page = """<!DOCTYPE html><meta charset="utf-8"><title>Story stickers</title>
<style>body{{font:15px sans-serif;margin:24px;background:#111;color:#eee}}table{{border-collapse:collapse}}td,th{{border-bottom:1px solid #333;padding:6px 10px;text-align:left}}input,button{{font:inherit}}</style>
<h1>Story sticker tray</h1>
<p>Hide and reorder Instagram's default stickers. Uploads are added to the next signed config as a Wexpid pack.</p>
<form method="post">
<table><tr><th>Id</th><th>Name</th><th>Type</th><th>Hide</th><th>Order</th></tr>
{rows}
</table>
<p><button type="submit">Save tray</button></p>
</form>
<h2>Custom stickers</h2>
<ul>{custom}</ul>
""".format(rows="".join(rows) or "<tr><td colspan=5>No tray report yet.</td></tr>", custom=custom or "<li>None uploaded.</li>")
    return 200, page


def admin_apply(token: str, form: dict, upload: tuple[str, bytes] | None = None) -> tuple[int, dict]:
    if not admin_ok(token):
        return 401, {"error": "unauthorized"}
    state = load_state()
    editing = "hidden" in form or any(str(key).startswith("order_") for key in form)
    if editing:
        hidden = form.get("hidden") or []
        if isinstance(hidden, str):
            hidden = [hidden]
        hidden_set = set(hidden)
        for ident, row in list(state["defaults"].items()):
            if not isinstance(row, dict):
                continue
            row["hidden"] = ident in hidden_set
            raw = form.get("order_" + ident)
            if isinstance(raw, str) and raw.lstrip("-").isdigit():
                row["order"] = int(raw)
    if upload and upload[0] and upload[1]:
        name = Path(upload[0]).name
        if "/" not in name and ".." not in name and len(upload[1]) <= 8 * 1024 * 1024:
            digest = hashlib.sha256(upload[1]).hexdigest()
            dest = static_dir() / name
            dest.write_bytes(upload[1])
            state["custom"].append({
                "id": digest[:12],
                "name": Path(name).stem,
                "order": len(state["custom"]),
                "url": "/static/stickers/" + name,
                "sha256": digest,
            })
    save_state(state)
    return 200, {"ok": True}


def _esc(text: str) -> str:
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _self_test() -> None:
    import tempfile
    root = tempfile.mkdtemp(prefix="igx-stickers-")
    os.environ["IGX_DATA"] = str(Path(root) / "data")
    os.environ["IGX_STATIC"] = str(Path(root) / "static")
    os.environ["IGX_ADMIN_TOKEN"] = "test-token"
    os.environ["IGX_STICKER_OPEN_BEARER"] = "1"
    status, body = handle_defaults("Bearer device-token-1", json.dumps({
        "items": [
            {"id": "weather/60F", "type": "Weather", "name": "60°F"},
            {"id": "time/clock", "type": "Time", "name": "Clock"},
        ]
    }).encode())
    assert status == 200 and body["count"] == 2, body
    status, _ = handle_defaults("", b"{}")
    assert status == 401
    status, payload = admin_apply("test-token", {"hidden": ["weather/60F"], "order_time/clock": "0", "order_weather/60F": "5"})
    assert status == 200, payload
    status, payload = admin_apply("nope", {})
    assert status == 401
    png = b"\x89PNG\r\n\x1a\n" + b"x" * 16
    status, payload = admin_apply("test-token", {}, ("star.png", png))
    assert status == 200, payload
    config = {"stickers": {"category": "Instagram X", "packs": []}}
    merge_into_config(config)
    assert config["stickers"]["hidden_defaults"] == ["weather/60F"]
    assert config["stickers"]["default_order"] == ["time/clock"]
    assert config["stickers"]["packs"][0]["stickers"][0]["sha256"] == hashlib.sha256(png).hexdigest()
    code, html = admin_html("test-token")
    assert code == 200 and "60°F" in html and "weather/60F" in html
    print("ok sticker panel")


if __name__ == "__main__":
    import sys
    if "--self-test" in sys.argv:
        _self_test()
    else:
        raise SystemExit("usage: igx_stickers.py --self-test")
