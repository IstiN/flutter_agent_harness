/// Delivery SLO instrumentation (issue #647): the messaging delivery path —
/// `task_send` into a child (running or waking) — logs stage timestamps
/// (send → enqueue → wake → consumed) and any stage landing past the SLO
/// emits a visible diagnostic naming the stalled stage. No silent queues.
///
/// Hosts wire [deliverySloSink]: the CLI prints a dim transcript line
/// (stderr in headless mode) and appends to fa.log; the app logs to
/// AppLog. Unwired (tests, embedders) the stages stay silent — the tool
/// result texts still carry them.
library;

/// The one delivery SLO: a message lands end-to-end within it, whatever the
/// recipient's state (running, idle, completed) and however many subagents
/// are in flight.
const Duration deliverySlo = Duration(seconds: 2);

/// Host sink for delivery stage lines. Null keeps the core silent.
void Function(String line)? deliverySloSink;

/// Emits one stage line when a host sink is wired; drops it otherwise.
void reportDeliveryStage(String line) {
  final sink = deliverySloSink;
  if (sink != null) sink(line);
}

/// One delivery stage line for [childId]: elapsed anchored at [since] (the
/// send) when given; [stage] names where the message is. A stage past the
/// SLO is marked as a breach so the diagnostic names the stalled stage.
void deliveryStage(
  String childId,
  String stage, {
  DateTime? since,
}) {
  final elapsed = since == null ? null : DateTime.now().difference(since);
  final breach = elapsed != null && elapsed > deliverySlo;
  reportDeliveryStage(
    '[slo${breach ? ' BREACH' : ''}] task_send child=$childId stage=$stage'
    '${elapsed == null ? '' : ' elapsed=${elapsed.inMilliseconds}ms'}'
    '${breach ? ' (slo ${deliverySlo.inMilliseconds}ms)' : ''}',
  );
}
