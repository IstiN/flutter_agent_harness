// The SW host's slash-command dispatch (gh-2059 AC2): the panel composer's
// input is classified BEFORE it can enter the transcript, so `/compact`
// runs a compaction instead of riding the wire as a literal user message
// (the incident's relay-224 record) and an unknown command answers like the
// CLI's REPL instead of being sent to the model.
//
// Pure Dart: no chrome.*, no js_interop — VM-tested in
// test/slash_commands_test.dart; agent_host.dart applies the decision.
library;

/// What [dispatchExtUserInput] decided for one composer input.
sealed class ExtUserInput {
  const ExtUserInput();
}

/// Ordinary text — run the turn (or steer a live one) verbatim.
final class ExtUserMessage extends ExtUserInput {
  const ExtUserMessage(this.text);

  final String text;
}

/// `/compact` — the manual compaction path; never a transcript message.
final class ExtCompactCommand extends ExtUserInput {
  const ExtCompactCommand();
}

/// An unknown `/word` — answered with a notice, never sent to the model
/// (CLI parity: "unknown command: $command (try /help)").
final class ExtUnknownCommand extends ExtUserInput {
  const ExtUnknownCommand(this.command);

  final String command;
}

/// Classifies one panel-composer input (CLI `_handleUnknownCommand`
/// semantics, thinned to the extension's command surface):
///
/// - `/compact` (with optional arguments, ignored — the CLI's `/compact`
///   takes none) → [ExtCompactCommand];
/// - a single token starting with `/` that names no command →
///   [ExtUnknownCommand] — the CLI answers it locally and sends nothing;
/// - anything else — including multi-segment `/path/like` shapes (the CLI
///   routes those as filesystem paths / messages, never commands) and a
///   bare `/` — stays a [ExtUserMessage].
ExtUserInput dispatchExtUserInput(String raw) {
  final text = raw.trim();
  if (!text.startsWith('/') || text.length <= 1) {
    return ExtUserMessage(text);
  }
  final token = text.split(RegExp(r'\s+')).first;
  if (token == '/compact') return const ExtCompactCommand();
  // `/a/b`-shaped single tokens are paths, not commands (CLI parity) —
  // they ride the transcript like ordinary text.
  if (token.contains('/', 1)) return ExtUserMessage(text);
  return ExtUnknownCommand(token);
}
