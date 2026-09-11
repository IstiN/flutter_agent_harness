#!/usr/bin/env python3
"""Compaction 2.0 judge experiment — issue #148.

Builds a context ledger (seq = JSONL line number) from a real fa session,
asks glm-5.3-flash which ids to HIDE, validates the answer.
"""
import json, os, re, subprocess, sys, urllib.request

SESSION = os.environ.get("FAH_SESSION_FILE") or sys.argv[1]
WINDOW = int(os.environ.get("WINDOW", "140"))
KEY = subprocess.run(
    ["textutil", "-convert", "txt", "-stdout",
     os.path.expanduser("~/Documents/test_key.rtf")],
    capture_output=True, text=True).stdout.strip()

def preview(rec, n=110):
    t = rec.get("type")
    if t == "message":
        m = rec.get("message", {})
        role = m.get("role", "?")
        parts = m.get("content")
        if isinstance(parts, str):
            txt = parts
        else:
            txt = " ".join(
                p.get("text", "") if isinstance(p, dict) else ""
                for p in (parts or []))
        txt = re.sub(r"\s+", " ", txt).strip()
        return f"{role}: {txt[:n]}"
    if t == "thinking":
        return f"thinking: {re.sub(chr(92)+'s+', ' ', str(rec.get('thinking','')))[:n]}"
    return f"{t}: {json.dumps(rec)[:n]}"

def kind_of(rec):
    t = rec.get("type")
    if t == "message":
        m = rec.get("message", {})
        role = m.get("role", "?")
        if role == "assistant":
            parts = m.get("content") or []
            calls = [p for p in parts if isinstance(p, dict) and p.get("type") == "toolCall"]
            if calls:
                names = ",".join(c.get("name", "?") for c in calls)[:60]
                return f"msg/assistant-TOOLCALL({names})"
            return "msg/assistant-TEXT"
        return f"msg/{role}"
    return t or "?"

ledger, meta = [], 0
with open(SESSION) as f:
    for i, line in enumerate(f, 1):
        if i > WINDOW:
            break
        try:
            rec = json.loads(line)
        except Exception:
            continue
        t = rec.get("type")
        if t in ("session", "session_info", "model_change", "checkpoint"):
            meta += 1
            continue
        tok = max(1, len(line) // 4)
        ledger.append((i, kind_of(rec), tok, preview(rec)))

lines = [f"[{s}] {k} ~{t}tok · {p}" for s, k, t, p in ledger]
total = sum(t for _, _, t, _ in ledger)
print(f"window: {len(ledger)} context records (+{meta} meta skipped), "
      f"~{total} tokens", file=sys.stderr)

JUDGE_SYS = """You are the context-hygiene judge for an AI agent harness.
The agent's context is a numbered ledger of records (id = stable number).
Near the context window edge you decide which records to HIDE.
Hiding is lossless (records stay on disk, expandable on demand), so be
aggressive — but NEVER hide:
- user messages containing requests, questions, or instructions;
- assistant text that answers the user or states decisions/conclusions;
- the most recent ~8 records (the live edge);
- unresolved errors the agent may still need.
PRIME hide candidates:
- tool results whose content was consumed (a file read followed by an edit
  of that file; a fetched page already distilled into an assistant summary);
- superseded re-reads and stale search/grep outputs;
- thinking/reasoning blocks whose conclusions are already stated;
- large one-off logs/listings.
PAIR RULE: an assistant-TOOLCALL record and its toolResult records are
atomic — either hide ALL of them (call + every result) or NONE.
Prefer keeping assistant-TEXT records (they carry conclusions the user saw).
Output ONLY a JSON array of ids and ranges, e.g. ["3","5","7-8","12"]."""

user = "LEDGER (id kind ~tokens preview):\n" + "\n".join(lines) + \
       "\n\nReturn ONLY the JSON array of ids/ranges to hide."

body = json.dumps({
    "model": "glm-5.3-flash",
    "messages": [
        {"role": "system", "content": JUDGE_SYS},
        {"role": "user", "content": user}],
    "temperature": 0.0,
    "max_tokens": 2048,
    "thinking": {"type": "disabled"},
}).encode()

req = urllib.request.Request(
    "https://api.z.ai/api/coding/paas/v4/chat/completions",
    data=body,
    headers={"Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=120) as r:
    resp = json.load(r)

msg = resp["choices"][0]["message"]["content"]
usage = resp.get("usage", {})
print(f"usage: {usage}", file=sys.stderr)
print("RAW ANSWER:", msg, file=sys.stderr)

m = re.search(r"\[.*\]", msg, re.S)
ids = json.loads(m.group(0)) if m else []
valid = {s for s, _, _, _ in ledger}
expanded = []
bad = []
for item in ids:
    item = str(item)
    if "-" in item:
        a, b = item.split("-", 1)
        rng = list(range(int(a), int(b) + 1))
    else:
        rng = [int(item)]
    for x in rng:
        (expanded if x in valid else bad).append(x)

saved = sum(t for s, k, t, _ in ledger if s in expanded)
print(f"\njudge proposed hiding {len(expanded)} records "
      f"(invalid ids: {bad or 'none'})")
print(f"tokens freed: ~{saved} of ~{total} ({100*saved//max(1,total)}%)")
print("\nhide decisions:")
for s, k, t, p in ledger:
    mark = "HIDE" if s in expanded else "keep"
    if s in expanded:
        print(f"  {mark} [{s}] {k} ~{t}tok · {p[:80]}")
