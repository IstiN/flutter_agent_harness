---
name: edit
description: Description of the edit tool's two modes (exact-match replace and hashline patch), including the hashline patch language guide ported from oh-my-pi's prompt.md.
---
Edit a file in one of two modes.

## Exact-match mode: `path` + `oldText` + `newText`

Replace an exact text occurrence. `oldText` must match exactly (including indentation and newlines) and occur exactly once in the file. Prefer this over `write` for small, precise changes to existing files; read the file first to get the exact text.

## Hashline mode: `patch`

A hashline patch names lines to replace, delete, or insert at by number, bound to a `[PATH#TAG]` content-hash header — precise line addressing without re-quoting file text. To author one, first `read` the file with `hashline=true`: it returns a `[PATH#TAG]` header and `LINE:TEXT` rows. Rule of thumb: a header ending in `:` is followed by `+` body rows; `DEL` has no body.

<headers>
Every file section starts with `[PATH#TAG]`. `TAG` = the 4-hex snapshot tag from your latest hashline `read` or edit response, REQUIRED on every section. Create new files with `write`; hashline only edits existing files. One patch may carry several `[PATH#TAG]` sections (different files); all sections apply or none do.
</headers>

<ops>
`SWAP N.=M:` — replace original lines N.=M with the body rows below. INCLUSIVE — line M is consumed too.
`DEL N.=M` — delete original lines N.=M. No body.
`INS.PRE N:` — insert the body rows immediately before line N.
`INS.POST N:` — insert the body rows immediately after line N.
`INS.HEAD:` / `INS.TAIL:` — insert the body rows at the very start / end of the file.
Single line: `SWAP N.=N:` / `DEL N`. The range is the ORIGINAL lines you touch; body length is irrelevant (replacing 1 line with 10 is still `SWAP N.=N:`).
</ops>

<body-rows>
Body rows appear only under a `:` header. Every body row is `+TEXT` — add a literal line `TEXT`, verbatim (leading whitespace kept); `+` alone adds a blank line. No other row kind. NEVER write `-old` or a bare/context line. To keep a line, leave it out of every range. Literal lines starting with `-`/`+` still need the body prefix: Markdown `- item` → `+- item`, `+ item` → `++ item`.
</body-rows>

<rules>
- Line numbers + `[PATH#TAG]` header come from your latest hashline `read` (`LINE:TEXT` rows) or edit response.
- Numbers refer to the ORIGINAL file; never shift as hunks apply.
- They die with the call: every applied edit mints a fresh `#TAG` and renumbers — anchor the next edit on the edit response or a fresh hashline `read`.
- Touch only lines your latest `read` literally displayed as `LINE:TEXT`; the tag certifies the snapshot, not your memory. A hunk anchored on a line you never displayed is REJECTED — re-`read` that range first.
- Never start or end a range mid-expression or mid-block.
- Indent body rows exactly for the depth they should live at.
- On a stale-tag rejection or any surprising result: STOP and re-`read` before further edits.
- One hunk per range; body = final content, never an old/new pair.
- Ranges cover ONLY lines whose content changes. Never widen over unchanged lines — a stale wide range shreds everything it spans.
- Pure additions use `INS.PRE` / `INS.POST` / `INS.HEAD` / `INS.TAIL`, never a widened `SWAP`.
- Non-adjacent changes = separate hunks; untouched lines stay out of every range.
- NEVER format/restyle code with this tool; run the project formatter instead.
</rules>

<example>
Original (the exact shape `read` with `hashline=true` returns):
```
[greet.py#A1B2]
1:def greet(name):
2:    msg = "Hello, " + name
3:    print(msg)
4:greet("world")
```

Insert a guard after line 1:
```
[greet.py#A1B2]
INS.POST 1:
+    if not name: name = "stranger"
```

Replace line 2 with two lines:
```
[greet.py#A1B2]
SWAP 2.=2:
+    greeting = "Hi"
+    msg = f"{greeting}, {name}"
```

Delete line 3:
```
[greet.py#A1B2]
DEL 3
```

Add a header and trailer:
```
[greet.py#A1B2]
INS.HEAD:
+# generated header
INS.TAIL:
+greet("everyone")
```

Insert Markdown bullets — the leading `+` is the body-row marker; the file receives `- task`:
```
[PLAN.md#A1B2]
INS.POST 2:
+- task
+  - nested task
```
</example>

<anti-patterns>
# WRONG — `-` rows / bare context lines do not exist. The range deletes; the body is only the new content.
SWAP 3.=3:
    msg = "Hello, " + name
-   print(msg)
+   return msg
# RIGHT
SWAP 3.=3:
+   return msg

# WRONG — a pure insertion done as a widened `SWAP`: you want to add one line after 2,
# but you replace 2.=4, retype the keepers, and risk dropping one.
SWAP 2.=4:
+    msg = "Hello, " + name
+    extra = compute(name)
+    print(msg)
# RIGHT — touch nothing you keep; the new line is the whole body.
INS.POST 2:
+    extra = compute(name)
</anti-patterns>

<critical>
If you remember nothing else:
1. RE-GROUND AFTER EVERY EDIT. Every apply mints a fresh `#TAG` and renumbers — take the next edit's numbers from the edit response or a fresh hashline `read`. Stale tag or surprise? STOP, re-`read`.
2. RANGES ARE TIGHT. Cover only lines that change; a stale wide range shreds everything it spans.
3. THE BODY IS THE FINAL CONTENT. Every body row starts with `+`; Markdown bullets use `+- item`, not `- item`.
</critical>
