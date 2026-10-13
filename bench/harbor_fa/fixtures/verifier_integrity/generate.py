#!/usr/bin/env python3
"""Regenerates the pinned verifier-stdout fixtures for gh-1579.

Only the five SYNTHESIZED ``*-test-stdout.txt`` files are (re)written
here. The ``*-test-stdout.real.txt`` siblings are pinned REAL artifact
bytes from run 38271607849 — not regenerable, never touched (provenance
and checksums in README.md).

The incident fixture synthesizes the artifact described in gh-1579 (run
38271607849, job `fa-2.1-docker-cpu-4`, trial
`filter-js-from-html__hoBwRwp`, `verifier/test-stdout.txt`): 28
`RUN BATCH N (contains K tests)` headers totalling 439 vectors, 84
urllib3 retry warnings (56 `Connection refused` + 28
`ConnectionResetError`), failed page loads in batches 2/5/16/20
(17+17+16+16 = 66 vectors silently skipped), and the contradicting
success claim `✓ Filter successfully blocked all 439 XSS attack
vectors!`. The four clean siblings carry the same 439-vector batch
structure with zero failed loads and only a handful of retries (the
negative fixtures: the detector must stay quiet on them).

Deterministic: byte-stable output. Run from this directory:

    python3 generate.py
"""
from pathlib import Path

_HERE = Path(__file__).resolve().parent

# Batch sizes for the filter-js-from-html verifier: 28 batches, 439 total.
# The incident's four skipped batches hold 17/17/16/16; the other 24 split
# 13×16 + 11×15 so the total is exactly 439.
BATCH_SIZES = {2: 17, 5: 17, 16: 16, 20: 16}
for _b in (1, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15):
    BATCH_SIZES[_b] = 16
for _b in (17, 18, 19, 21, 22, 23, 24, 25, 26, 27, 28):
    BATCH_SIZES[_b] = 15
assert len(BATCH_SIZES) == 28 and sum(BATCH_SIZES.values()) == 439

_RETRY_REFUSED = (
    "urllib3.connectionpool - WARNING - Retrying (Retry(total={total}, "
    "connect=None, read=None, redirect=None, status=None)) after connection "
    "broken by 'NewConnectionError('<urllib3.connection.HTTPConnection "
    "object at 0x7f9c{n:012x}>: Failed to establish a new connection: "
    "[Errno 111] Connection refused')': /session/{sid}"
)
_RETRY_RESET = (
    "urllib3.connectionpool - WARNING - Retrying (Retry(total={total}, "
    "connect=None, read=None, redirect=None, status=None)) after connection "
    "broken by 'ConnectionResetError(104, Connection reset by peer)': "
    "/session/{sid}"
)
_FAILED_LOAD = (
    "Failed to load URL: HTTPConnectionPool(host='localhost', port={port}): "
    "Read timed out. (read timeout=120)"
)


def _emit(trial: str, failed_batches: tuple[int, ...], retries: dict[int, int],
          footer: list[str]) -> str:
    lines = [
        "============================= test session starts =============================",
        "platform linux -- Python 3.11.9, pytest-8.2.0, pluggy-1.5.0",
        "rootdir: /app",
        "collected 2 items",
        "",
        "Launching chromedriver on port 9515",
        "test_outputs.py",
    ]
    retry_kinds = ("refused", "refused", "reset")  # 2 refused + 1 reset per batch
    retry_seq = 0
    for batch in sorted(BATCH_SIZES):
        n = BATCH_SIZES[batch]
        lines.append(f"RUN BATCH {batch} (contains {n} tests)")
        lines.append(
            f"[b{batch}] loading batch page "
            f"http://localhost:8000/filter?batch={batch} (timeout=120)"
        )
        for i in range(retries.get(batch, 0)):
            kind = retry_kinds[retry_seq % len(retry_kinds)]
            retry_seq += 1
            tmpl = _RETRY_REFUSED if kind == "refused" else _RETRY_RESET
            lines.append(tmpl.format(total=2 - (i % 3), n=0x5F0000 + retry_seq,
                                     sid=f"b{batch}-{i}"))
        if batch in failed_batches:
            lines.append(_FAILED_LOAD.format(port=41861 + batch))
            lines.append(f"[b{batch}] page never loaded — vectors not exercised")
        else:
            lines.append(
                f"v{batch}-1: <img src=x onerror=alert(1)> -> blocked"
            )
            lines.append(
                f"v{batch}-{n}: <svg onload=alert(2)> -> blocked"
            )
    lines.append("======================================================================")
    lines.append("✓ Filter successfully blocked all 439 XSS attack vectors!")
    lines.extend(footer)
    return "\n".join(lines) + "\n"


INCIDENT = _emit(
    "filter-js-from-html__hoBwRwp",
    failed_batches=(2, 5, 16, 20),
    retries={b: 3 for b in BATCH_SIZES},  # 84 warnings: 56 refused + 28 reset
    footer=[
        "✗ test_clean_html_unchanged — the filter rewrote clean html",
        "======================================================================",
        "FAILED test_outputs.py::test_clean_html_unchanged - AssertionError: html changed",
        "==================================== 1 failed, 1 passed in 312.40s ====================================",
    ],
)

CLEAN = {
    # The four clean siblings of the incident trial (gh-1579 negative
    # fixtures): zero failed loads, a handful of retries — all far below
    # the S2 suspect threshold — and the honest success claim.
    "4FpkEin": {3: 2},
    "NmQswud": {7: 3, 19: 2},
    "t4MK34E": {},
    "UX5zWxE": {1: 4, 9: 2, 22: 2},
}
CLEAN_FOOTER = [
    "======================================================================",
    "=========================================== 2 passed in 214.07s ===========================================",
]


def main() -> None:
    # encoding pinned: the fixtures carry "✓" and the docstring promises
    # byte-stable output — never the locale default (cp1252 would crash
    # or silently re-encode on Windows). The two *-test-stdout.real.txt
    # artifacts are NOT generated here — they are pinned real bytes (see
    # README.md) and regeneration must never touch them.
    (_HERE / "filter-js-from-html__hoBwRwp-test-stdout.txt").write_text(
        INCIDENT, encoding="utf-8"
    )
    for trial, retries in CLEAN.items():
        (_HERE / f"filter-js-from-html__{trial}-test-stdout.txt").write_text(
            _emit(trial, (), retries, CLEAN_FOOTER), encoding="utf-8"
        )
    print("wrote", 1 + len(CLEAN), "fixtures to", _HERE)


if __name__ == "__main__":
    main()
