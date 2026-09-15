/// Password-ask detection for foreground bash commands (issue #367).
///
/// A foreground command that hits a password prompt (`[sudo] password for
/// user:`, `Password:`, an ssh `passphrase`, a TOTP `Verification code`)
/// used to strand the run: with no way to feed the process, the password
/// was typed into the chat composer — a plain echo that lands in the input
/// history and the session. The detector watches the command's output
/// stream and, when a password ask sits at the line end and the output
/// goes quiet, hands the prompt line to the host's
/// [PasswordPromptCallback]; the host renders it as a masked sheet and the
/// answer is written straight to the process's stdin — never into the tool
/// result, the transcript, or any captured surface.
///
/// Anchoring (GOAL #367 E4): the ask must sit at the END of the current
/// partial line (a colon with nothing but blanks after it), and it fires
/// only after a short quiet window — ordinary output that merely contains
/// `Password:` mid-stream never opens the sheet, and a wrongly opened
/// sheet is Esc-dismissable with zero side effects.
library;

import 'dart:async';

/// Answers a detected password ask on behalf of the host UI (the TUI's
/// masked prompt zone, the Flutter sheet). [promptLine] is the actual
/// prompt as it appeared in the output (`[sudo] password for user:`).
///
/// Returns the secret to write to the process's stdin, or `null` to
/// decline — the harness then writes a bare newline so the command fails
/// naturally and the user keeps control.
typedef PasswordPromptCallback = FutureOr<String?> Function(String promptLine);

/// The password-ask patterns anchored to the end of the current partial
/// line: `Password:`, `[sudo] password for user:`, `user@host's password:`,
/// `Enter passphrase for key '...':`, `Verification code:` (TOTP). The tail
/// anchor admits blanks but no newline — a newline-terminated line is
/// ordinary output, not a waiting prompt.
final RegExp _promptAtLineEnd = RegExp(
  r'(?:^|\n)[^\n]*'
  r'(?:'
  r'\[\s*sudo\s*\]\s*password(?:\s+for\s+\S+)?'
  r'|(?:enter\s+)?password'
  r'|passphrase(?:\s+for\s+[^:\n]*)?'
  r'|verification\s+code'
  r')'
  r':[ \t\r]*$',
  caseSensitive: false,
);

/// Watches a command's output stream for password asks and resolves them
/// through [onPrompt]. One answer at a time: while an answer is pending the
/// detector stays muted; after it resolves the next detected ask re-arms
/// (a wrong-password retry opens the sheet again — GOAL #367 E1).
final class PasswordPromptDetector {
  /// Creates a detector. [quiet] is the silence window the prompt must hold
  /// before the sheet fires (chunked streams routinely end a chunk at a
  /// colon; only a QUIET colon is a waiting prompt). [windowSize] caps the
  /// rolling tail the patterns match against.
  PasswordPromptDetector({
    required this.onPrompt,
    this.quiet = const Duration(milliseconds: 250),
    int windowSize = 200,
  }) : _windowCap = windowSize;

  final FutureOr<void> Function(String promptLine) onPrompt;

  /// How long the matched prompt must stay the last output before the host
  /// is asked.
  final Duration quiet;

  final int _windowCap;
  final StringBuffer _window = StringBuffer();
  Timer? _quietTimer;
  var _awaitingAnswer = false;
  var _disposed = false;

  /// Feeds one output chunk (stdout and stderr alike — sudo prompts on
  /// stderr). Any output resets the quiet window: a pending fire is
  /// re-evaluated against the new tail.
  void feed(String chunk) {
    if (_disposed || chunk.isEmpty) return;
    _quietTimer?.cancel();
    _quietTimer = null;
    _window.write(chunk);
    var text = _window.toString();
    if (text.length > _windowCap) {
      text = text.substring(text.length - _windowCap);
      _window
        ..clear()
        ..write(text);
    }
    if (_awaitingAnswer) return;
    if (_promptAtLineEnd.firstMatch(text) == null) return;
    _quietTimer = Timer(quiet, _fire);
  }

  /// Stops watching; cancels any pending fire. An answer already in
  /// flight is left to its owner.
  void dispose() {
    _disposed = true;
    _quietTimer?.cancel();
    _quietTimer = null;
  }

  void _fire() {
    _quietTimer = null;
    if (_disposed || _awaitingAnswer) return;
    final text = _window.toString();
    if (_promptAtLineEnd.firstMatch(text) == null) return;
    final newline = text.lastIndexOf('\n');
    final title = (newline < 0 ? text : text.substring(newline + 1)).trim();
    if (title.isEmpty) return;
    _awaitingAnswer = true;
    final answer = onPrompt(title);
    if (answer is Future<String?>) {
      answer.whenComplete(() => _awaitingAnswer = false);
    } else {
      _awaitingAnswer = false;
    }
  }
}
