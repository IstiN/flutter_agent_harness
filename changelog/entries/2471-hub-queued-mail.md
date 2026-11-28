---
type: fix
scope: fabric
issue: 2471
---

- fix(fabric): queued hub mail no longer strands off an unsettled roster (gh-2471) —
  `FallbackMessagingRepository` untracked queued mail on the first connected
  roster snapshot lacking the recipient, and after a hub restart peers re-hello
  on their own reconnect backoff, so that snapshot is not ownership evidence
  (v1.0.794 hostile-env red, run 46147543769: "queued mail not forwarded within
  20s of inbox probes"; production shape: DMs queued during a hub restart are
  silently lost). The flush now untracks on a confirmed miss only when the
  routing primary's roster is settled — the new `RosterSettleness` capability
  (`hubRosterWarmup`, 5s, rides out the first three reconnect-backoff steps);
  `HubFabricRepository` (bin/) and `HubMessagingRepository` (flutter_app
  network-join path) report settledness off their own re-welcome witness.
  Non-advertising primaries keep today's behavior.
