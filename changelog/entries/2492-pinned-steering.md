---
type: feat
scope: compaction
issue: 2492
---

- feat(compaction): pinned steering for task children (gh-2492 C2) — a task
  child's task prompt record and newest steering delivery pin in its OWN
  session file (`SegmentPinRecord`): the prompt pins once on its first
  transcript flush, every steering delivery pins its records and releases the
  previous delivery's (one steering pinned at a time), and a resume from a
  pre-card session gains ensure-pins (first prompt + newest steering, never
  un-hiding anything). The mechanical trim valve (`localTrimValve`) carries
  pinned messages behind its cut like the boundary summaries — the
  summarizer-down valve can no longer take the assignment or the newest
  instruction out of the live context. Mail stays data: `isSyntheticUserText`
  is untouched.
