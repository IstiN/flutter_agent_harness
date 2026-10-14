/// The FinalizeGate fold machinery (gh-1412, gh-1516 + review): the
/// `MessageEndEvent` interceptor that strips the task ledger BEFORE hosts
/// persist/render the event payload, the strip stash, and the end-of-run
/// fold that turns the terminal answer's strip into the hidden
/// `task_ledger` record. Split out of `agent_loop.dart` to keep it under
/// the repo's 2800-line size gate. Same library (a `part of`), so the
/// helpers keep their access to the loop's private members.
part of 'agent_loop.dart';

/// One ledger stripped from an assistant message at `MessageEndEvent`
/// time (gh-1516 review): the parsed ledger plus the original/stripped
/// message pair. The end-of-run fold matches the TERMINAL message against
/// this stash — a mid-run strip never satisfies the gate (gh-1412).
final class _StrippedLedger {
  _StrippedLedger({
    required this.ledger,
    required this.original,
    required this.stripped,
  });

  final TaskLedger ledger;
  final AssistantMessage original;
  final AssistantMessage stripped;
}

/// The FinalizeGate `MessageEndEvent` interceptor (gh-1516 review): hosts
/// persist (`_persistIncremental` appends the event's message straight to
/// the session JSONL) and render (`_onAssistantMessageEnd` flushes the
/// answer on it) the message a `MessageEndEvent` carries — anything an
/// end-of-run fold rewrites later never reaches the persisted transcript
/// or the flush. In gate mode each assistant message is therefore
/// stripped at this choke point, BEFORE the event is forwarded, and the
/// strip is stashed for the end-of-run fold. Non-assistant events,
/// unstripped messages, and gate-off turns pass through untouched.
AgentEventSink _finalizeGateStrippingSink(
  AgentEventSink emit,
  List<_StrippedLedger> stash,
  bool Function() gateOn,
) {
  return (AgentEvent event) {
    if (!gateOn() || event is! MessageEndEvent) return emit(event);
    final stripped = _stripAssistantLedger(event.message, stash);
    if (stripped == null) return emit(event);
    return emit(MessageEndEvent(stripped));
  };
}

/// Strips the ledger out of EVERY ledger-bearing text block of an
/// assistant [message] (one resolve per text block, last block first) and
/// records ONE stash entry per stripped message. The stash entry's ledger
/// stays the LAST ledger-bearing block's (gh-1412: the last block
/// decides) — earlier blocks are stripped from the transcript but never
/// key the gate. Returns the stripped message, or null when no block
/// carries a ledger.
AssistantMessage? _stripAssistantLedger(
  Message message,
  List<_StrippedLedger> stash,
) {
  if (message is! AssistantMessage) return null;
  final content = message.content;
  var current = message;
  TaskLedger? ledger;
  for (var i = content.length - 1; i >= 0; i--) {
    if (content[i] is! TextContent) continue;
    final block = content[i] as TextContent;
    final resolution = resolveTaskLedger(block.text);
    if (resolution == null) continue;
    // First hit in reverse order = the LAST ledger-bearing block: the
    // gate's key (gh-1412). Blocks after this only leave the transcript.
    ledger ??= resolution.ledger;
    final replaced = List<ContentBlock>.of(current.content);
    replaced[i] = block.copyWith(text: resolution.strippedText);
    current = current.copyWith(content: replaced);
  }
  if (ledger == null) return null;
  stash.add(
    _StrippedLedger(ledger: ledger, original: message, stripped: current),
  );
  return current;
}

/// Applies the FinalizeGate end-of-run fold (gh-1412, gh-1516): emits
/// [TaskLedgerEvent] for the hidden `task_ledger` record and aligns the
/// in-memory transcript with what the interceptor already streamed and
/// persisted. The strip itself happened at `MessageEndEvent` time
/// ([_finalizeGateStrippingSink]); this fold only decides whether the
/// TERMINAL answer's ledger satisfies the gate (gh-1412: a run must END
/// on the answer — a mid-run strip, or a run that stopped on tool calls,
/// never fires) and rewrites `newMessages`/the context copy so the
/// returned run matches the persisted session.
///
/// [producedState] is the gh-1516 trivial-turn rule: ANY tool call in
/// the run counts as produced state — the loop cannot cheaply classify
/// which calls mutate, so the telemetry's bar is deliberately coarser
/// than the prompt's model-facing "state-changing commands" wording
/// (gh-1516 review): no tool calls, nothing to verify, no event.
Future<void> _emitFinalizeGateFold(
  List<Message> newMessages,
  List<Message> contextMessages,
  List<_StrippedLedger> stash,
  AgentEventSink emit,
) async {
  if (newMessages.isEmpty || newMessages.last is! AssistantMessage) return;
  final terminal = newMessages.last as AssistantMessage;
  // The stash's latest entry for the terminal message decides; earlier
  // entries were mid-run strips — stashed for the transcript, never for
  // the gate.
  _StrippedLedger? fold;
  for (final entry in stash) {
    if (identical(entry.original, terminal)) fold = entry;
  }
  if (fold == null) return;
  final matched = fold;
  final producedState = newMessages.any(
    (m) => m is AssistantMessage && m.content.any((block) => block is ToolCall),
  );
  if (producedState) await emit(TaskLedgerEvent(matched.ledger));
  newMessages[newMessages.length - 1] = matched.stripped;
  final at = contextMessages.lastIndexWhere(
    (message) => identical(message, matched.original),
  );
  if (at >= 0) contextMessages[at] = matched.stripped;
}
