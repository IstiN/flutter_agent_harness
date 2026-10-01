// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copyable error dialog for an app that cannot launch: a failed demo
/// seed or a manifest an agent edit broke (issue #866). Shared by every
/// launch surface — launcher tiles, launcher search, AppsGridView,
/// AppsPanel and the widgets-catalog sheet.
Future<void> showAppLoadError(
  BuildContext context,
  JsAppInfo app,
  String error,
  String title,
) async {
  final l10n = context.l10n;
  final appName = app.displayName(
    Localizations.localeOf(context).toLanguageTag(),
  );
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appName, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SelectableText(error),
          const SizedBox(height: 12),
          Text(l10n.launcherSeedErrorHint),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            unawaited(Clipboard.setData(ClipboardData(text: error)));
            Navigator.of(dialogContext).pop();
          },
          child: Text(l10n.launcherSeedErrorCopy),
        ),
      ],
    ),
  );
}

/// The broken-app launch guard every launch surface goes through.
///
/// Returns true when the tap was handled — [app] is broken, the copyable
/// error dialog is up — and the caller MUST NOT launch. Returns false for
/// healthy apps so callers proceed with `await`-free confidence.
Future<bool> guardBrokenApp(BuildContext context, JsAppInfo app) async {
  final error = app.error;
  if (error == null) return false;
  await showAppLoadError(
    context,
    app,
    error,
    context.l10n.launcherManifestErrorTitle,
  );
  return true;
}
