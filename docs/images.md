# Images: the session registry, caps, and drop notices

How multimodal sessions carry images, what happens when a request exceeds
its image cap, and what you see when it does (issues #171, #195 F4,
#1750, #1889).

## The registry and the cap

The session image registry is **derived state, rebuilt per request** from
the message window: every unique image rides a provider request exactly
once as a carrier; later occurrences become `[Image N]` text refs. The
**current** (last) user message always rides its images in place.

The per-request cap (`images.maxPerRequest`, default **20**) and the
per-request byte budget (`images.maxBytesPerRequest`, default **8MB** of
base64 — issue #1916) apply to the whole request: the current message's
images claim slots first (first-seen order inside the batch), the
remaining slots go to the newest history images, and every overflow image
is **dropped** — replaced by `(image no longer available)` on the wire.
Whichever limit binds first names the drop reason (count or bytes); a
byte drop never stops the scan — a smaller older image still fits.
The transcript (session JSONL) is never touched; only the outgoing
payload is rewritten.

```yaml
# ~/.fah/config.yaml (or .fah/config.yaml)
images:
  maxPerRequest: 20        # per-request cap on unique images
  maxBytesPerRequest: 8388608  # per-request image budget (~8MB of base64)
  registry: true           # kill switch: false = byte-identical legacy behavior
  perModel:                # per-model ceiling overrides (#1750)
    gemini-4-argon: 10
```

History text that carries a whole image as an inline `data:image/…;base64,…`
URL (legacy session records, pre-#171 transcripts, hosts that paste
screenshots as markdown) folds into a real image block on history
messages before the registry scan — those bytes ride the same once-only
path instead of replaying raw on every request forever (#1916 AC2; the
current message keeps its text verbatim and degrades on the next turn).
Data-URL payloads under 64KB stay text (icons, separators).

Cap resolution per request: `images.perModel.<modelId>` > the model
catalog's `maxImages` > `images.maxPerRequest`. A provider image-count
refusal can **teach** the loop a smaller cap at runtime (#1750); the
learned cap applies for the rest of the run for that (provider, model)
pair and is announced once when learned.

## The notice model (#1889): one notice per change, never a flood

Every drop is still **never silent** — but the user-facing transcript
gets an *aggregated, latched* notice, not one line per image per request:

- **Same dropped set again** (any number of requests) ⇒ **silence**. The
  latch key is the dropped images' **content keys** (stable across
  renumbering and compaction), plus the effective cap and the model id —
  so a `#1750` learned-cap change or a batch change re-notices exactly
  once.
- **Changed set or recovery** ⇒ one updated notice (recovery prints one
  all-clear line, then silence).
- **Severity split**:
  - current-message drops (just attached, immediately capped) get a
    *prominent* warning per changed situation:
    `5 of 25 attached images were not sent to the model — cap is 20/request; see /images or images.maxPerRequest`
  - history drops (expected long-session degradation) get the low-key
    line: `17 older images not sent this turn (cap 20) — /images for details`
- **No content-key hashes** appear in default notice lines; keys and
  indexes live in the details surface.
- **New session / resume**: the latch state is per run — the first
  post-resume request re-latches (one notice at most), never a flood.
  `/reset` clears it explicitly.
- **Kill switch** (`images.registry: false`): no rewrite, no drops, no
  notices — legacy behavior byte-for-byte.

The **debug surface stays per-image per-request** (never silent): the CLI
logs every drop event with index + key preview to `fa.log`; the app logs
the same detail to `AppLog` (`logs/app.log`).

## 413 recovery and compaction eviction (gh-1934)

A provider rejecting a request for **size** (`413`-class — `Request
Entity Too Large`, `request_too_large`, payload-too-large wordings) never
ends in an unusable session. The loop runs a bounded recovery ladder:

1. **Pass 1 — drop**: the session's adaptive image budget halves (from
   the configured `images.maxBytesPerRequest`; the halved value is
   learned for the rest of the session) and the request is rebuilt — the
   oldest images drop first until the payload fits, and the request is
   retried.
2. **Pass 2 — strip**: on a second 413 the budget halves again and
   **every** image block — the current message included — is replaced by
   an `[image dropped: <key preview>]` text placeholder, and the request
   is retried. The strip latches for the session: later requests ride
   placeholders and cannot re-trigger the refusal.
3. **Exhausted**: a third 413 yields ONE actionable notice
   (`switch provider or lower images.maxBytesPerRequest`) and the
   provider error surfaces as before. No loops — at most two recovery
   passes per response, and a text-only session never engages the
   ladder.

Each pass prints one `[images] recovered from 413: dropped N, stripped
M` line (headless prints the same line once per pass), and the retried
request carries a model-visible recovery note so the assistant answer
can mention it. The learned budget is session-scoped v1 (runtime-only);
a lower configured `images.maxBytesPerRequest` always wins over it.

**Compaction eviction** is the structural fix behind `/compact always
restores sendability`: once a renumbering boundary (a compaction
summary, a structured marker, or the local-trim note) sits in the
window, every HISTORY image block outside the current user message
rides as the `[image dropped: …]` placeholder instead of re-carrying its
bytes. The session JSONL keeps the original bytes (payload-only
rewrite), token accounting counts the placeholders, and remaining
`[Image N]` citations degrade to `(image no longer available)` — the
number could rebind to different bytes, and a silent rebind is never
allowed (#195 F2). `/images` names evictions explicitly
(`(evicted: compaction boundary / 413 recovery)`).

## The details surface: `/images` (CLI) and the chat chip + panel (app)

Both hosts render the **same shared projection** (`imageSurfaceLines` in
`lib/src/agent/image_drop_ux.dart`):

```
images: 37 in the window, 20 sent, 17 not sent last request
  dropped [Image 0] 03d21f2a… (older history — cap 20)
  …
cap: 20 per request for gemini-4-argon (images.perModel override) · ~8MB image budget
cap was learned from a provider refusal (#1750) — it applies for the rest of the run
knobs: images.maxPerRequest and images.maxBytesPerRequest in ~/.fah/config.yaml; images.registry: false sends everything unrewritten (no notices)
```

- CLI: type `/images`.
- App: the aggregated notice chip docked above the transcript — tap it
  for the details panel; `×` dismisses the chip (the situation itself
  only changes on the next capped request).

## Payload-aware stalls and the image-heavy playbook (#1916)

A submit carrying many megabytes of images needs more first-token
patience than a text session; without accounting, the stall watchdogs
abandon the attempt, drop the late answer, and retry the SAME multi-MB
payload — a livelock. Three defenses, all automatic:

- **Scaled windows**: the connect-stall window and the run-idle window
  widen linearly with the outbound payload size (1MB free, 2x at 16MB,
  capped). A user-declared `providerTimeouts.connectTimeoutMs` stays an
  absolute clamp and is never scaled. A payload-scaled stall line names
  the request size (`window scaled for a ~20MB request`).
- **Late-answer adoption**: a response that arrives from an abandoned
  attempt DURING the retry backoff is adopted (announced as `adopting
  the late response`) instead of detached — the billed generation is
  used. Once a later attempt owns the send, late answers detach as
  before (`response detached, generation dropped`).
- **One actionable warning**: repeated stalls of the SAME payload fire
  exactly ONE `[net]` advice line — `/compact` to drop image data,
  lower `images.maxBytesPerRequest` (see `/images`), `/restart` as a
  last resort — instead of endless silent re-uploads.

### Playbook: an image-heavy session stalls on submit

Symptoms: `connect stall: no response bytes` (attempts 2/3, 3/3),
`abandoned connect attempt … answered late`, `run-idle watchdog replay
of zero-byte request`, a busy row stuck at `Stalled… · submit` — while
the same model works fine in text-only sessions.

1. **`/compact`** — compaction evicts every history image to a
   placeholder (gh-1934), so the next submit carries zero image bytes
   from the folded region.
2. **Lower the image budget** — `images.maxBytesPerRequest` (default
   8MB) in `~/.fah/config.yaml` or via `/settings → Images`; `/images`
   shows what the last request actually sent and dropped.
3. **Check the payload, not the token bar** — the token display counts
   images at a flat heuristic (~120 tokens); a "98% full" session can
   still be re-uploading 20MB per submit.
4. **`/restart`** — last resort; the stall advice and the stall banner
   both list it last.

## Non-goals (unchanged by #1889/#1916)

- The registry's stateless per-request rebuild (#171).
- Image selection policy: current first, then newest history (#171 I3).
- The cap algorithms, including #1750's learned caps.
- Outbound payloads apart from identical drop behavior.
