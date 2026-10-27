// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fa/services/app_log.dart';

/// Marks paths excluded from cloud device backups.
///
/// gh-1730 review: the mobile sandbox's `.dap` hub tree holds the hub
/// `clientSecret` (accepted directly as a credential), the agent identity
/// key, and X25519 channel keypairs. On iOS `getApplicationDocumentsDirectory()`
/// is `Documents/`, which the default iCloud device backup includes — the
/// same class of leak issue #329 E4 stopped for `fah_keychain.xml`. The
/// native side (`fah/icloud` `excludeFromBackup`, AppDelegate.swift) sets
/// `NSURLIsExcludedFromBackupKey` on the subtree; Android needs no call
/// (its `app_flutter` documents dir already sits outside the default Auto
/// Backup domains, per the #329 E4 audit).
const MethodChannel _icloudChannel = MethodChannel('fah/icloud');

/// Test seam: replaces the platform call entirely (unit tests record the
/// requested path instead of round-tripping a channel no host implements).
@visibleForTesting
Future<void> Function(String path)? excludePathFromBackupOverride;

/// Whether backup exclusion applies at all on this platform: iOS only.
/// Android needs no call (its `app_flutter` documents dir already sits
/// outside the default Auto Backup domains, per the #329 E4 audit). The
/// kIsWeb check comes FIRST: on the web `Platform.isIOS` throws at
/// runtime (web_safety_guard_test), and the correct answer there is a
/// no-op anyway.
bool _backupExclusionApplies() {
  if (kIsWeb) return false;
  return Platform.isIOS;
}

/// The native exclusion call; every error path logs and moves on — the
/// exclusion is hardening, never a boot precondition.
Future<void> _excludeViaIcloudChannel(String path) async {
  try {
    await _icloudChannel.invokeMethod<void>('excludeFromBackup', {
      'path': path,
    });
  } on MissingPluginException {
    // No native handler (unit tests, macOS) — nothing to exclude with.
  } on PlatformException catch (e) {
    AppLog.i('sandbox', 'backup exclusion failed for $path: ${e.message}');
  }
}

/// Marks the file or directory at [path] excluded from cloud backups.
///
/// A failure must never break boot — the exclusion is hardening, not a
/// precondition — so every error path logs and moves on.
Future<void> excludePathFromBackup(String path) async {
  final override = excludePathFromBackupOverride;
  if (override != null) {
    await override(path);
    return;
  }
  if (!_backupExclusionApplies()) return;
  await _excludeViaIcloudChannel(path);
}
