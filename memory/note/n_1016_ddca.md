---
id: "n_1016_ddca"
type: "note"
title: "gh-1947 root cause (fix 5941833): ShellJobRegistry.start registered the job's settle continuation in the CALLING bash call's zone — a background job started by a subagent carried its onSettled into the child's subagent zone, so a job settling after the child finished started the CLI settle-wake (_onShellJobSettled → _startRun → agent.prompt) with activeSubagentId() still naming the dead child; the whole MAIN wake run (schedule_message self-mailbox resolution included) attributed to the child (timers landed in <session>/<child>, auto-resuming it). Fix layers: (1) registry binds the settle continuation to its construction-time boot zone (_bootZone.run); (2) both hosts' scheduleSenderMailbox closures trust the zone scope only while TaskExecutor.isInFlight(id) — stale zones degrade to main; (3) the schedule_message response names the record's `to` (explicit to: was shadowed by the sender in the reply). Test: test/cli/agent_cli_schedule_recipient_test.dart drives the REAL AgentCli (FakeCliIO + _SettleableJobShell whose jobs settle on demand); zone pin at test/tools/shell_job_settle_zone_test.dart. LESSON: any .then/whenComplete/listener registered during a tool call inherits that call's zone forever — host callbacks that can START RUNS must be bound to the boot zone, and zone-scoped identity consumers need an in-flight liveness check."
author: "agent"
date: "2026-10-28T19:44:46.581879Z"
area: "project"
topics: []
source: "agent"
accessCount: 0
importance: 0.5
tags: ["#note", "#source_agent", "gh-1947", "zone-identity", "shell-jobs", "schedule_message", "root-cause", "architecture", "messaging", "subagents"]
---


# Note: n_1016_ddca

gh-1947 root cause (fix 5941833): ShellJobRegistry.start registered the job's settle continuation in the CALLING bash call's zone — a background job started by a subagent carried its onSettled into the child's subagent zone, so a job settling after the child finished started the CLI settle-wake (_onShellJobSettled → _startRun → agent.prompt) with activeSubagentId() still naming the dead child; the whole MAIN wake run (schedule_message self-mailbox resolution included) attributed to the child (timers landed in <session>/<child>, auto-resuming it). Fix layers: (1) registry binds the settle continuation to its construction-time boot zone (_bootZone.run); (2) both hosts' scheduleSenderMailbox closures trust the zone scope only while TaskExecutor.isInFlight(id) — stale zones degrade to main; (3) the schedule_message response names the record's `to` (explicit to: was shadowed by the sender in the reply). Test: test/cli/agent_cli_schedule_recipient_test.dart drives the REAL AgentCli (FakeCliIO + _SettleableJobShell whose jobs settle on demand); zone pin at test/tools/shell_job_settle_zone_test.dart. LESSON: any .then/whenComplete/listener registered during a tool call inherits that call's zone forever — host callbacks that can START RUNS must be bound to the boot zone, and zone-scoped identity consumers need an in-flight liveness check.

**By:** [[agent]]
**Date:** 2026-10-28T19:44:46.581879Z
**Area:** [[project|project]]
