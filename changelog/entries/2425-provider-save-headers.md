---
type: fix
scope: browser_ext
issue: 2425
---

- fix(browser_ext): provider.save drops contextWindow/custom headers (gh-2425) —
  the panel save overwrote `faProvider` with baseUrl/apiKey/model only, so every
  save reset the stored window override (gh-2059) and a 264k-token model ran on
  the shared fallback window until "Context window exhausted". `provider.save`
  now merges field-wise (the same contract as the Dart settings_put merge:
  non-empty wins, blank keeps stored, positive ints by presence,
  string-tolerant, custom headers replace-by-presence so a header line the
  user deleted actually deletes — a dropped authorization header stops riding
  requests).
