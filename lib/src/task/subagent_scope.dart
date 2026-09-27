/// Zone-scoped identity of the subagent whose run encloses the caller.
///
/// The executor's in-flight id STACK cannot attribute tool calls under
/// concurrency: several background children run on ONE executor, so the
/// stack's head is "the child that started last", not "the child executing
/// this tool call" — gh-970's swapped sender envelopes. Each child run
/// therefore publishes its id in a zone value (the same mechanism as the
/// soft-yield token, `cancel_token.dart`) and identity consumers read it at
/// call time: the child-only `reply`/`agent_message` tools resolve the
/// calling child through the executor, and shared tools with self-mailbox
/// semantics (`schedule_message`) resolve the caller's mailbox through the
/// host wiring.
library;

import 'dart:async';

/// Zone key under which a child runner publishes the running child's id.
const Symbol subagentIdZoneKey = #fahSubagentId;

/// The id of the subagent whose run encloses the caller, or null when the
/// caller is not inside a child run (the main agent, host code).
String? activeSubagentId() => Zone.current[subagentIdZoneKey] as String?;

/// Runs [body] with [id] published as the enclosing subagent identity.
/// Nested scopes shadow outer ones; the value is visible to every callback
/// executed within [body]'s async chain (tool executions included).
R runWithSubagentScope<R>(String id, R Function() body) =>
    runZoned(body, zoneValues: {subagentIdZoneKey: id});
