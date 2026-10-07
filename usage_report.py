#!/usr/bin/env python3
"""
claude-usage-emailer: a daily email of Claude API spend per person or team.

Reads Anthropic's Admin Usage & Cost API and sends a plain email. It makes
no model calls, so it costs zero tokens to run. Standard library only.

    python3 usage_report.py --check     # test the admin key, list workspaces and keys
    python3 usage_report.py --preview   # print the report, send nothing
    python3 usage_report.py             # build and email the report
"""
import argparse
import json
import os
import smtplib
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from pathlib import Path

__version__ = "1.1.0"

API = "https://api.anthropic.com/v1/organizations"
HERE = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("USAGE_EMAILER_CONFIG", HERE / "config.json"))
DEFAULT_WS = "__default__"
PLACEHOLDER = "PASTE_ADMIN_KEY_HERE"

# Rough list prices in USD per million tokens. These are ONLY used to share
# out spend between API keys that sit in the same workspace. Totals and
# per-workspace figures always come from Anthropic's own cost report.
# Matched by substring, first match wins. Override with "prices" in config.
DEFAULT_PRICES = [
    # match,     input, output, cache_write_5m, cache_write_1h, cache_read
    ["opus",      5.00, 25.00, 6.25, 10.00, 0.50],
    ["sonnet",    3.00, 15.00, 3.75,  6.00, 0.30],
    ["haiku",     1.00,  5.00, 1.25,  2.00, 0.10],
    ["",          3.00, 15.00, 3.75,  6.00, 0.30],  # fallback
]
WEB_SEARCH_USD = 0.01


# ------------------------------------------------------------------ config
def load_config():
    if not CONFIG_PATH.exists():
        sys.exit(f"No config found at {CONFIG_PATH}. Run the setup script first, "
                 "or copy config.example.json to config.json.")
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    cfg["admin_key"] = os.environ.get("ANTHROPIC_ADMIN_KEY", cfg.get("admin_key", "")).strip()
    cfg.setdefault("smtp", {})
    cfg["smtp"]["password"] = os.environ.get("SMTP_PASSWORD", cfg["smtp"].get("password", ""))
    if not cfg["admin_key"].startswith("sk-ant-admin"):
        sys.exit("admin_key is missing or wrong. It must be an Admin API key (starts with "
                 "sk-ant-admin). Create one in the Claude Console under Settings > Admin keys.")
    cfg.setdefault("members", [])
    return cfg


def norm(s):
    """Loose name match: ignore case, spaces and curly apostrophes."""
    return "".join((s or "").lower().replace("’", "'").split())


# ------------------------------------------------------------------ API
def get(cfg, path, params):
    url = f"{API}/{path}?{urllib.parse.urlencode(params, doseq=True)}"
    req = urllib.request.Request(url, headers={
        "x-api-key": cfg["admin_key"],
        "anthropic-version": "2023-06-01",
        "user-agent": f"claude-usage-emailer/{__version__}",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"Anthropic API error {e.code} on {path}: {e.read().decode()[:500]}")
    except urllib.error.URLError as e:
        sys.exit(f"Could not reach api.anthropic.com: {e.reason}")


def list_all(cfg, path, params):
    params, out = dict(params), []
    while True:
        d = get(cfg, path, params)
        out += d.get("data", [])
        if not d.get("has_more"):
            return out
        params["after_id"] = d["last_id"]


def buckets(cfg, path, params):
    params = dict(params)
    while True:
        d = get(cfg, path, params)
        yield from d.get("data", [])
        if not d.get("has_more"):
            return
        params["page"] = d["next_page"]


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ------------------------------------------------------------------ data
def workspaces(cfg):
    ws = {w["id"]: w.get("name") or w["id"]
          for w in list_all(cfg, "workspaces", {"limit": 100, "include_archived": "true"})}
    ws[DEFAULT_WS] = "Default"
    return ws


def api_keys(cfg):
    return list_all(cfg, "api_keys", {"limit": 1000})


def cost_by_workspace(cfg, start, end):
    divisor = 100.0 if cfg.get("cost_amount_unit", "cents") == "cents" else 1.0
    out = defaultdict(float)
    for b in buckets(cfg, "cost_report", {
        "starting_at": iso(start), "ending_at": iso(end), "bucket_width": "1d",
        "limit": 31, "group_by[]": ["workspace_id"],
    }):
        for r in b.get("results", []):
            out[r.get("workspace_id") or DEFAULT_WS] += float(r.get("amount") or 0) / divisor
    return out


def price_row(model, prices):
    m = (model or "").lower()
    return next((p for p in prices if p[0] in m), prices[-1])


def estimate(r, prices):
    _, inp, out, cw5, cw1, cr = price_row(r.get("model"), prices)
    cc = r.get("cache_creation") or {}
    usd = (r.get("uncached_input_tokens", 0) * inp + r.get("output_tokens", 0) * out
           + cc.get("ephemeral_5m_input_tokens", 0) * cw5
           + cc.get("ephemeral_1h_input_tokens", 0) * cw1
           + r.get("cache_read_input_tokens", 0) * cr) / 1e6
    if r.get("service_tier") == "batch":
        usd *= 0.5
    return usd + (r.get("server_tool_use") or {}).get("web_search_requests", 0) * WEB_SEARCH_USD


def estimate_by_key(cfg, start, end):
    """Returns {api_key_id: (workspace_id, estimated_usd)}."""
    prices = cfg.get("prices") or DEFAULT_PRICES
    out = defaultdict(lambda: [DEFAULT_WS, 0.0])
    for b in buckets(cfg, "usage_report/messages", {
        "starting_at": iso(start), "ending_at": iso(end), "bucket_width": "1d", "limit": 31,
        "group_by[]": ["api_key_id", "workspace_id", "model", "service_tier"],
    }):
        for r in b.get("results", []):
            row = out[r.get("api_key_id") or "unknown"]
            row[0] = r.get("workspace_id") or DEFAULT_WS
            row[1] += estimate(r, prices)
    return out


# ------------------------------------------------------------------ split
def resolve_members(cfg, ws_names, keys):
    """Attach workspace ids and api key ids to each member."""
    ws_by_name = {norm(n): wid for wid, n in ws_names.items()}
    key_by_name = {norm(k.get("name")): k["id"] for k in keys}
    key_ids = {k["id"] for k in keys}
    members, problems = [], []
    for m in cfg["members"]:
        wids, kids = [], []
        for w in m.get("workspaces", [m["workspace"]] if m.get("workspace") else []):
            wid = w if w in ws_names else ws_by_name.get(norm(w))
            (wids.append(wid) if wid else problems.append(f"{m['name']}: no workspace '{w}'"))
        for k in m.get("api_keys", []):
            kid = k if k in key_ids else key_by_name.get(norm(k))
            (kids.append(kid) if kid else problems.append(f"{m['name']}: no API key '{k}'"))
        members.append({**m, "wids": wids, "kids": kids})
    return members, problems


def split(members, ws_cost, key_est):
    """
    Workspace members get Anthropic's exact cost for their workspace(s).
    Key members share whatever is left in a workspace in proportion to the
    estimated cost of their keys' token usage.
    """
    owned_ws = {w for m in members for w in m["wids"]}
    key_owner = {k: m["name"] for m in members for k in m["kids"]}
    result = {m["name"]: 0.0 for m in members}

    for m in members:
        result[m["name"]] += sum(ws_cost.get(w, 0.0) for w in m["wids"])

    # per workspace not owned outright: share real cost by key estimate
    est_by_ws = defaultdict(dict)
    for kid, (wid, est) in key_est.items():
        est_by_ws[wid][kid] = est
    for wid, cost in ws_cost.items():
        if wid in owned_ws:
            continue
        ests = est_by_ws.get(wid, {})
        total_est = sum(ests.values())
        for kid, est in ests.items():
            if kid in key_owner and total_est:
                result[key_owner[kid]] += cost * est / total_est
    unassigned = max(sum(ws_cost.values()) - sum(result.values()), 0.0)
    return result, unassigned


# ------------------------------------------------------------------ report
def money(x):
    return f"${x:,.2f}"


def build(cfg):
    ws_names = workspaces(cfg)
    needs_keys = any(m.get("api_keys") for m in cfg["members"])
    keys = api_keys(cfg) if needs_keys else []
    members, problems = resolve_members(cfg, ws_names, keys)
    for p in problems:
        print("WARNING:", p, file=sys.stderr)

    now = datetime.now(timezone.utc)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    yday = today - timedelta(days=1)
    month_start = yday.replace(day=1)  # on the 1st this covers the whole previous month
    days = (today - month_start).days or 1

    def period(a, b):
        ws_cost = cost_by_workspace(cfg, a, b)
        key_est = estimate_by_key(cfg, a, b) if needs_keys else {}
        return ws_cost, split(members, ws_cost, key_est)

    y_ws, (y_by, y_other) = period(yday, today)
    m_ws, (m_by, m_other) = period(month_start, today)

    rows = []
    for m in members:
        b = m.get("monthly_budget_usd")
        mm = m_by[m["name"]]
        rows.append({"name": m["name"], "email": m.get("email"), "y": y_by[m["name"]], "m": mm,
                     "pace": mm / days * 30, "budget": b,
                     "pct": (mm / b * 100) if b else None})
    rows.sort(key=lambda r: -r["m"])
    return {
        "date": yday, "month": f"{month_start:%B}", "rows": rows,
        "other": (y_other, m_other), "total": (sum(y_ws.values()), sum(m_ws.values())),
        "show_other": cfg.get("show_unassigned", True),
    }


def render(rep, only=None):
    """Text and HTML for the whole table, or a single member's row if only= is set."""
    rows = [r for r in rep["rows"] if only is None or r["name"] == only]
    title = f"Claude API spend: {rep['date']:%a %d %b}"
    if only:
        title += f" ({only})"
    mo = rep["month"]

    def budget(r):
        return f"{r['pct']:.0f}% of {money(r['budget'])}" if r["budget"] else ""

    lines = [title, ""]
    for r in rows:
        b = f"  | {budget(r)}" if r["budget"] else ""
        lines.append(f"{r['name']:<14} yesterday {money(r['y']):>10}   {mo} {money(r['m']):>10}"
                     f"   ~{money(r['pace'])}/30d{b}")
    show_other = only is None and rep["show_other"] and rep["other"][1] > 0.005
    if show_other:
        lines.append(f"{'Other':<14} yesterday {money(rep['other'][0]):>10}   {mo} {money(rep['other'][1]):>10}")
    if only is None:
        lines += ["", f"Whole account: yesterday {money(rep['total'][0])}, {mo} {money(rep['total'][1])}"]
    lines += ["Days are UTC, same as Anthropic billing. Data can lag a few hours."]
    text = "\n".join(lines)

    td = "padding:6px 10px"
    body = "".join(
        f"<tr><td style='{td}'>{r['name']}</td>"
        f"<td style='{td};text-align:right'>{money(r['y'])}</td>"
        f"<td style='{td};text-align:right'><b>{money(r['m'])}</b></td>"
        f"<td style='{td};text-align:right;color:#666'>{money(r['pace'])}</td>"
        f"<td style='{td};color:{'#c0392b' if (r['pct'] or 0) >= 100 else '#666'}'>{budget(r)}</td></tr>"
        for r in rows)
    if show_other:
        body += (f"<tr style='color:#888'><td style='{td}'>Other</td>"
                 f"<td style='{td};text-align:right'>{money(rep['other'][0])}</td>"
                 f"<td style='{td};text-align:right'>{money(rep['other'][1])}</td><td></td><td></td></tr>")
    total = (f"<p style='color:#444;font-size:13px;margin-top:12px'>Whole account: yesterday "
             f"{money(rep['total'][0])} · {mo} {money(rep['total'][1])}</p>") if only is None else ""
    html = f"""<div style="font-family:-apple-system,Segoe UI,Arial,sans-serif;max-width:600px">
<h2 style="margin:0 0 12px">{title}</h2>
<table style="border-collapse:collapse;width:100%;font-size:14px">
<tr style="background:#f3f3f3;text-align:left"><th style="{td}">Who</th>
<th style="{td};text-align:right">Yesterday</th><th style="{td};text-align:right">{mo}</th>
<th style="{td};text-align:right">30-day pace</th><th style="{td}">Budget</th></tr>
{body}</table>{total}
<p style="color:#888;font-size:12px">Days are UTC, same as Anthropic billing. Data can lag a few hours.</p></div>"""
    return title, text, html


def send_mail(cfg, to, subject, text, html):
    s = cfg["smtp"]
    if not s.get("from") or not s.get("password"):
        sys.exit("The smtp section of the config is not filled in, so email can't be sent.")
    msg = EmailMessage()
    msg["Subject"], msg["From"], msg["To"] = subject, s["from"], ", ".join(to)
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    host, port = s.get("host", "smtp.gmail.com"), int(s.get("port", 587))
    ctx = ssl.create_default_context()
    if port == 465:
        srv = smtplib.SMTP_SSL(host, port, timeout=60, context=ctx)
    else:
        srv = smtplib.SMTP(host, port, timeout=60)
        srv.starttls(context=ctx)
    with srv:
        srv.login(s.get("username") or s["from"], s["password"])
        srv.send_message(msg)
    print(f"{datetime.now():%Y-%m-%d %H:%M} sent '{subject}' to {', '.join(to)}")


def deliver(cfg, rep):
    mode = cfg.get("send_mode", "digest")
    extra = cfg.get("digest_recipients", [])
    if mode == "individual":
        for r in rep["rows"]:
            if r["email"]:
                send_mail(cfg, [r["email"]], *render(rep, only=r["name"]))
        if extra:
            send_mail(cfg, extra, *render(rep))
    else:
        to = [r["email"] for r in rep["rows"] if r["email"]] + extra
        if not to:
            sys.exit("Nobody to email: add an email to a member or to digest_recipients.")
        send_mail(cfg, to, *render(rep))


# ------------------------------------------------------------------ main
def check(cfg):
    ws = workspaces(cfg)
    print("Admin key works.\n\nWorkspaces:")
    for wid, name in ws.items():
        print(f"  {name:<30} {wid}")
    keys = api_keys(cfg)
    print("\nAPI keys:")
    for k in keys:
        print(f"  {k.get('name') or '-':<30} {k['id']:<38} {k.get('status', '')}")
    members, problems = resolve_members(cfg, ws, keys)
    print("\nMembers:")
    for m in members:
        print(f"  {m['name']:<14} {len(m['wids'])} workspace(s), {len(m['kids'])} key(s)")
    for p in problems:
        print("  PROBLEM:", p)
    if not members:
        print("  none yet: add some to the members list in config.json")


def main():
    ap = argparse.ArgumentParser(description="Email daily Claude API spend. Uses zero tokens.")
    ap.add_argument("--check", action="store_true", help="test the admin key, list workspaces and keys")
    ap.add_argument("--preview", action="store_true", help="print the report instead of emailing it")
    ap.add_argument("--version", action="version", version=__version__)
    a = ap.parse_args()
    cfg = load_config()
    if a.check:
        return check(cfg)
    rep = build(cfg)
    if a.preview:
        print(render(rep)[1])
    else:
        deliver(cfg, rep)


if __name__ == "__main__":
    main()
