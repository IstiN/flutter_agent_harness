# Images: the session registry, caps, and drop notices

How multimodal sessions carry images, what happens when a request exceeds
its image cap, and what you see when it does (issues #171, #195 F4,
#1750, #1889).

## The registry and the cap

The session image registry is **derived state, rebuilt per request** from
the message window: every unique image rides a provider request exactly
once as a carrier; later occurrences become `[Image N]` text refs. The
**current** (last) user message always rides its images in place.

The per-request cap (`images.maxPerRequest`, default **20**) applies to
the whole request: the current message's images claim slots first
(first-seen order inside the batch), the remaining slots go to the newest
history images, and every overflow image is **dropped** — replaced by
`(image no longer available)` on the wire. The transcript (session JSONL)
is never touched; only the outgoing payload is rewritten.

```yaml
# ~/.fah/config.yaml (or .fah/config.yaml)
images:
  maxPerRequest: 20        # per-request cap on unique images
  registry: true           # kill switch: false = byte-identical legacy behavior
  perModel:                # per-model ceiling overrides (#1750)
    gemini-4-argon: 10
```

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

## The details surface: `/images` (CLI) and the chat chip + panel (app)

Both hosts render the **same shared projection** (`imageSurfaceLines` in
`lib/src/agent/image_drop_ux.dart`):

```
images: 37 in the window, 20 sent, 17 not sent last request
  dropped [Image 0] 03d21f2a… (older history — cap 20)
  …
cap: 20 per request for gemini-4-argon (images.perModel override)
cap was learned from a provider refusal (#1750) — it applies for the rest of the run
knobs: images.maxPerRequest in ~/.fah/config.yaml; images.registry: false sends everything unrewritten (no notices)
```

- CLI: type `/images`.
- App: the aggregated notice chip docked above the transcript — tap it
  for the details panel; `×` dismisses the chip (the situation itself
  only changes on the next capped request).

## Non-goals (unchanged by #1889)

- The registry's stateless per-request rebuild (#171).
- Image selection policy: current first, then newest history (#171 I3).
- The cap algorithms, including #1750's learned caps.
- Outbound payloads apart from identical drop behavior.
