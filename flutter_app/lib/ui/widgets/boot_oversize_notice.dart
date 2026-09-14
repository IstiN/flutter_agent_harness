// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';

/// The boot notice for a last-active session skipped for size (issue #381):
/// instead of silently swapping the oversized session for a fresh one, boot
/// says so — one unobtrusive snackbar naming the session and its size, with
/// an action that opens it through the windowed loader.
///
/// Called once from the shells' `initState` (post-frame, so the messenger
/// exists); [onOpen] routes to the shell's own persisted-session open path.
void showBootOversizeNotice(
  BuildContext context, {
  required FlutterSessionManager manager,
  SessionNamesStore? names,
  required Future<void> Function(SessionMetadata metadata) onOpen,
}) {
  final skipped = manager.bootSkippedOversize;
  if (skipped == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!context.mounted || messenger == null) return;
    final sizeMb = (skipped.sizeBytes ?? 0) / (1024 * 1024);
    // The user-given overlay name when present, else the derived date
    // title (same rules as the sidebar rows).
    final name =
        names?.titleFor(skipped.id) ??
        derivedSessionTitle(
          context,
          id: skipped.id,
          createdAt: skipped.createdAt,
        );
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(
          context.l10n.sessionBootSkippedOversize(
            name,
            sizeMb.toStringAsFixed(0),
          ),
        ),
        action: SnackBarAction(
          label: context.l10n.sessionBootSkippedOpen,
          onPressed: () => unawaited(onOpen(skipped)),
        ),
      ),
    );
  });
}
