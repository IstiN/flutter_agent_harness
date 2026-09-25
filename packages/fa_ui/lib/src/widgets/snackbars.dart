// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_strings.dart';

/// The app's ONE feedback module (issue #869): every SnackBar is built here —
/// informational snacks via [showFahSnack], error surfaces via
/// [showFahErrorSnack], which always carries the [FahErrorCopyButton] copy
/// affordance (tap = full verbatim text on the clipboard + a check mark;
/// long-press = the diagnostics envelope when the host provides fields).
/// The source guard (`flutter_app/test/error_surface_guard_test.dart`)
/// hard-fails on any `SnackBar(` constructed outside this file, so a new
/// error surface cannot ship without the affordance.

/// Copies [text] verbatim; false when the OS refuses (the affordance shows a
/// brief failed state instead of crashing).
Future<bool> copyText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } on Object {
    return false;
  }
}

/// Optional host-provided fields for the copy-with-diagnostics envelope
/// (issue #869 second tier): absent lines are omitted, an empty envelope
/// keeps the payload exactly [buildErrorCopyEnvelope]'s message.
class ErrorCopyDiagnostics {
  /// Creates the diagnostics fields.
  const ErrorCopyDiagnostics({this.sessionId, this.appVersion, this.platform});

  /// The session the error belongs to, when the call site knows it.
  final String? sessionId;

  /// The app/fa version string, when the host provides one.
  final String? appVersion;

  /// The platform line, when the host provides one.
  final String? platform;
}

/// Builds the one-payload bug-report text: [message] verbatim when
/// [diagnostics] is null or empty, otherwise the message plus a
/// `--- diagnostics ---` block (session id, app/fa version, platform).
String buildErrorCopyEnvelope({
  required String message,
  ErrorCopyDiagnostics? diagnostics,
}) {
  final d = diagnostics;
  if (d == null) return message;
  final lines = [
    if (d.sessionId != null) 'session: ${d.sessionId}',
    if (d.appVersion != null) 'version: ${d.appVersion}',
    if (d.platform != null) 'platform: ${d.platform}',
  ];
  if (lines.isEmpty) return message;
  return '$message\n\n--- diagnostics ---\n${lines.join('\n')}';
}

enum _CopyFeedback { idle, copied, failed }

/// The error copy affordance (issue #869): tap puts the FULL [text] verbatim
/// on the clipboard (visual truncation never truncates the payload) and flips
/// the icon to a check for ~1.5s; long-press copies the diagnostics envelope
/// when [diagnostics] is provided; an OS clipboard refusal shows a brief
/// failed state instead of crashing.
class FahErrorCopyButton extends StatefulWidget {
  /// Creates the affordance for one error surface.
  const FahErrorCopyButton({
    super.key,
    required this.text,
    this.diagnostics,
    this.color,
  });

  /// The exact error text the surface renders — copied verbatim.
  final String text;

  /// Diagnostics fields for the long-press envelope; null = plain copy only.
  final ErrorCopyDiagnostics? diagnostics;

  /// Icon color; defaults to the theme's inverse primary (snackbar-safe).
  final Color? color;

  @override
  State<FahErrorCopyButton> createState() => _FahErrorCopyButtonState();
}

class _FahErrorCopyButtonState extends State<FahErrorCopyButton> {
  static const _confirmDuration = Duration(milliseconds: 1500);
  _CopyFeedback _feedback = _CopyFeedback.idle;

  Future<void> _copy(String payload) async {
    final ok = await copyText(payload);
    if (!mounted) return;
    setState(() {
      _feedback = ok ? _CopyFeedback.copied : _CopyFeedback.failed;
    });
    await Future<void>.delayed(_confirmDuration);
    if (mounted) setState(() => _feedback = _CopyFeedback.idle);
  }

  @override
  Widget build(BuildContext context) {
    final strings = FaChatStrings.of(context);
    return Tooltip(
      message: switch (_feedback) {
        _CopyFeedback.copied => strings.errorCopiedToClipboard,
        _CopyFeedback.failed => strings.errorCopyFailedTooltip,
        _CopyFeedback.idle => strings.errorCopyTooltip,
      },
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: const EdgeInsets.all(4),
        iconSize: 16,
        color: widget.color ?? Theme.of(context).colorScheme.inversePrimary,
        onPressed: () => _copy(widget.text),
        onLongPress: widget.diagnostics == null
            ? null
            : () => _copy(
                buildErrorCopyEnvelope(
                  message: widget.text,
                  diagnostics: widget.diagnostics,
                ),
              ),
        icon: Icon(switch (_feedback) {
          _CopyFeedback.copied => Icons.check,
          _CopyFeedback.failed => Icons.error_outline,
          _CopyFeedback.idle => Icons.copy_rounded,
        }),
      ),
    );
  }
}

/// Plain informational snack (no copy affordance).
void showFahSnack(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  _showSnack(context, SnackBar(content: Text(message), duration: duration));
}

void _showSnack(BuildContext context, SnackBar snack) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  try {
    messenger.showSnackBar(snack);
  } on AssertionError catch (error) {
    // Scaffold-less host: the root messenger exists but registers no
    // Scaffold, so the snack has nowhere to render — stay cosmetic
    // (the pre-#869 no-crash contract, pinned by the codemie flow-steps
    // test and the fa_ui error-copy suite).
    debugPrint(
      'fa_ui: snack dropped, no Scaffold under the messenger ($error)',
    );
  }
}

/// ERROR snack (issue #869): the rendered message plus the trailing copy
/// affordance — tap writes the exact message to the clipboard, full text
/// even when the snackbar truncates visually. [sessionId] rides the
/// long-press diagnostics envelope when the caller knows it; [hideCurrent]
/// replaces the visible snack instead of queueing (composer error flow);
/// [action] keeps legacy side actions (e.g. #381 boot-notice "Open") beside
/// the affordance.
void showFahErrorSnack(
  BuildContext context,
  String message, {
  String? sessionId,
  Duration duration = const Duration(seconds: 4),
  bool hideCurrent = false,
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  if (hideCurrent) messenger.hideCurrentSnackBar();
  _showSnack(
    context,
    SnackBar(
      duration: duration,
      action: action,
      content: Row(
        children: [
          Expanded(child: Text(message)),
          FahErrorCopyButton(
            text: message,
            diagnostics: sessionId == null
                ? null
                : ErrorCopyDiagnostics(sessionId: sessionId),
          ),
        ],
      ),
    ),
  );
}
