#!/usr/bin/env python3
"""Official Terminal-Bench leaderboard fetcher (gh-1682).

Usage:
    fetch.py --version 2.1 [--out rows.json] [--source auto|hub|tbench]

Pulls the official leaderboard rows for one Terminal-Bench dataset
version and prints a normalized JSON document:

    {
      "schema": 1,
      "version": "2.1",
      "package": "terminal-bench/terminal-bench-2-1",
      "leaderboard": "main",
      "title": "Terminal-Bench 2.1",
      "source": "harbor-hub" | "tbench.ai",
      "fetched_at": "<iso8601>",
      "rows": [
        {"rank": 1, "agent": "Codex", "agent_url": ...,
         "model": "GPT-6 Astra", "model_url": ...,
         "accuracy": 87.42, "n_trials": 445, "date": "2026-09-03",
         "cost_usd": ...},
        ...
      ]
    }

Source of truth (ticket order): the Harbor Hub API first — the public
`leaderboard-read` function documented at
docs.harborframework.com/harbor-hub/leaderboards and backing tbench.ai.
Fallback: parse tbench.ai's embedded page JSON (a Next.js app — the
leaderboard dehydrates into `self.__next_f.push` RSC payloads). HTML
tables are NEVER regex-scraped; only the embedded structured JSON is
read. `--source tbench` forces the fallback (used by tests/backfills).

Version -> (package, leaderboard name), verified live against the Hub
on 2026-10-18: the 2.x boards live under their own packages (only the
4.x/3.x generations share `terminal-bench/terminal-bench`):

    2.0  terminal-bench/terminal-bench-2    2-0
    2.1  terminal-bench/terminal-bench-2-1  main
    3.0  terminal-bench/terminal-bench      3-0-0
    4.0  terminal-bench/terminal-bench      4-0-0

Stdlib only (same tooling constraint as the rest of bench/).
"""
import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# version label -> (hub package, leaderboard name). Verified live against
# the Harbor Hub leaderboard-read function (gh-1682).
BOARDS = {
    "2.0": ("terminal-bench/terminal-bench-2", "2-0"),
    "2.1": ("terminal-bench/terminal-bench-2-1", "main"),
    "3.0": ("terminal-bench/terminal-bench", "3-0-0"),
    "4.0": ("terminal-bench/terminal-bench", "4-0-0"),
}

HUB_READ_URL = "https://api.harborframework.com/functions/v1/leaderboard-read"
TBENCH_URL = "https://www.tbench.ai/"
# Hub row lists are paged; the docs example uses 100 and tbench.ai's own
# boards are a few dozen rows, so one page of 1000 covers a board whole.
HUB_PAGE_SIZE = 1000
HUB_MAX_PAGES = 20
HTTP_TIMEOUT = 30
USER_AGENT = "fa-leaderboard-fetch (gh-1682)"

# HTML tables are never scraped — only the Next.js RSC payload lines.
_RSC_PUSH_RE = re.compile(
    r'self\.__next_f\.push\(\[1,\s*"((?:[^"\\]|\\.)*)"\s*\]\)'
)


def board_for(version: str) -> "tuple[str, str]":
    """Resolve a version label (or a bare board name under the 4.x
    package) to its (package, name); unknown versions fail loudly."""
    if version in BOARDS:
        return BOARDS[version]
    raise SystemExit(
        f"error: unknown Terminal-Bench version '{version}' — known boards: "
        + ", ".join(sorted(BOARDS))
    )


def _label(value) -> str:
    """Hub metadata fields are {'label': ..., 'url': ...} objects (or
    plain strings in older rows) — the table wants the label."""
    if isinstance(value, dict):
        return value.get("label")
    return value


def _url(value) -> str:
    if isinstance(value, dict):
        return value.get("url")
    return None


def normalize_hub_payload(payload: dict, version: str) -> dict:
    """Normalize a leaderboard-read response body into our row schema."""
    lb = payload.get("leaderboard") or {}
    rows = []
    for row in payload.get("rows") or []:
        md = row.get("metadata") or {}
        mt = row.get("metrics") or {}
        rows.append(
            {
                "rank": row.get("rank"),
                "agent": _label(md.get("agent_display")),
                "agent_url": _url(md.get("agent_display")),
                "model": _label(md.get("model_display")),
                "model_url": _url(md.get("model_display")),
                "accuracy": mt.get("accuracy"),
                "n_trials": mt.get("n_trials"),
                "date": md.get("date"),
                "cost_usd": mt.get("total_cost_usd"),
            }
        )
    rows.sort(key=lambda r: (r["accuracy"] is None, -(r["accuracy"] or 0)))
    return {
        "schema": 1,
        "version": version,
        "package": lb.get("package"),
        "leaderboard": lb.get("name"),
        "title": lb.get("title"),
        "source": "harbor-hub",
        "source_url": HUB_READ_URL,
        "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "rows": rows,
    }


def parse_tbench_page(html: str, package: str, name: str) -> list:
    """Extract one leaderboard's dehydrated rows from a tbench.ai page.

    tbench.ai is a Next.js app: the leaderboard query result dehydrates
    into `self.__next_f.push([1,"<json>"])` lines. We decode every such
    payload, find the query whose key is ["leaderboard", package, name],
    and return its data rows. Returns [] when the page does not carry
    that board (never an HTML-table fallback).
    """
    for raw in _RSC_PUSH_RE.findall(html):
        # The captured group is a JSON string literal — json.loads
        # decodes both \" and \uXXXX correctly (unicode_escape would
        # mangle multi-byte labels).
        try:
            text = json.loads('"' + raw + '"')
        except json.JSONDecodeError:
            continue
        start = text.find("{")
        if start < 0:
            continue
        try:
            payload, _ = json.JSONDecoder().raw_decode(text[start:])
        except json.JSONDecodeError:
            continue
        queries = (payload.get("state") or {}).get("queries") or []
        for query in queries:
            if query.get("queryKey") != ["leaderboard", package, name]:
                continue
            data = (query.get("state") or {}).get("data") or {}
            return list(data.get("rows") or [])
    return []


def normalize_tbench_rows(rows: list, version: str, package: str,
                          name: str, title: str = None) -> dict:
    """Normalize tbench.ai RSC rows — same shape as the Hub rows."""
    doc = normalize_hub_payload(
        {"leaderboard": {"package": package, "name": name, "title": title},
         "rows": rows},
        version,
    )
    doc["source"] = "tbench.ai"
    doc["source_url"] = TBENCH_URL
    return doc


def _http_json(url: str, payload: dict = None) -> dict:
    data = None
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode())


def _http_get(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.read().decode()


def fetch_hub(version: str) -> dict:
    """Read a board through the Harbor Hub leaderboard-read function,
    paging through total_pages."""
    package, name = board_for(version)
    rows = []
    title = None
    got_package = package
    for page in range(1, HUB_MAX_PAGES + 1):
        payload = _http_json(
            HUB_READ_URL,
            {"package": package, "name": name, "page": page,
             "page_size": HUB_PAGE_SIZE},
        )
        lb = payload.get("leaderboard") or {}
        title = lb.get("title") or title
        got_package = lb.get("package") or got_package
        rows.extend(payload.get("rows") or [])
        pagination = payload.get("pagination") or {}
        if page >= pagination.get("total_pages", 1):
            break
    return normalize_hub_payload(
        {"leaderboard": {"package": got_package, "name": name,
                         "title": title},
         "rows": rows},
        version,
    )


def fetch_tbench(version: str) -> dict:
    """Fallback: parse the leaderboard out of tbench.ai's page JSON."""
    package, name = board_for(version)
    rows = parse_tbench_page(_http_get(TBENCH_URL), package, name)
    return normalize_tbench_rows(rows, version, package, name)


def fetch_official(version: str, source: str = "auto") -> dict:
    """Fetch normalized official rows; hub first, tbench.ai fallback.

    A missing board (404 on the hub function) falls through to the page
    parser; transport errors on BOTH sources raise — the caller decides
    whether a stale snapshot is better than no table.
    """
    if source not in ("auto", "hub", "tbench"):
        raise SystemExit(f"error: unknown --source '{source}'")
    if source in ("auto", "hub"):
        try:
            return fetch_hub(version)
        except urllib.error.HTTPError as exc:
            if source == "hub" or exc.code != 404:
                raise
        # 404 with source=auto: the board is not on the hub API — try
        # the page (it may dehydrate a board the API does not expose).
    doc = fetch_tbench(version)
    if not doc["rows"]:
        # Unknown or removed board — say so honestly instead of emitting
        # an empty table that could read as "nobody solved anything".
        raise SystemExit(
            f"error: no official leaderboard rows for '{version}' on the"
            f" hub API or tbench.ai (package '{board_for(version)[0]}'"
            f" name '{board_for(version)[1]}')"
        )
    return doc


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True,
                        help="dataset version label (2.0/2.1/3.0/4.0)")
    parser.add_argument("--source", choices=["auto", "hub", "tbench"],
                        default="auto")
    parser.add_argument("--out", type=argparse.FileType("w"), default=sys.stdout)
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args(argv)

    doc = fetch_official(args.version, args.source)
    json.dump(doc, args.out, indent=2 if args.pretty else None)
    args.out.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
