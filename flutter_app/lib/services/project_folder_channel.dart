import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Native project-folder operations: directory picking plus the
/// security-scoped bookmark access lifecycle (macOS sandbox). Abstracted so
/// the file browser can be driven by fakes in tests.
abstract interface class ProjectFolderOps {
  /// Opens the native directory panel; null when cancelled/unsupported.
  Future<({String path, String bookmark})?> pickDirectory();

  /// Resolves a security-scoped bookmark and starts accessing the folder.
  Future<bool> startAccessing(String bookmark);

  /// Best-effort stop of a previously started access.
  Future<void> stopAccessing(String bookmark);
}

/// The method-channel-backed [ProjectFolderOps] for macOS and iOS.
final class ProjectFolderChannelOps implements ProjectFolderOps {
  /// Creates the ops over the `fah/project_folder` channel.
  const ProjectFolderChannelOps();

  /// Whether native project-folder picking is available (desktop sandbox or
  /// iOS document picker). Android uses the shared channel when its host
  /// picker is available; a missing native handler is a no-grant, not a boot
  /// failure.
  // kIsWeb first: dart:io Platform throws on the web.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static const _channel = MethodChannel('fah/project_folder');

  @override
  Future<({String path, String bookmark})?> pickDirectory() async {
    if (!isSupported) return null;
    final result = await _channel.invokeMapMethod<String, String>(
      'pickDirectory',
    );
    return pickResult(result);
  }

  /// The picked folder from a channel payload, or null on cancel or an
  /// incomplete `{path, bookmark}` record. Exposed for tests.
  @visibleForTesting
  static ({String path, String bookmark})? pickResult(
    Map<String, String>? result,
  ) {
    if (result == null) return null;
    final path = result['path'];
    final bookmark = result['bookmark'];
    if (path == null || bookmark == null) return null;
    return (path: path, bookmark: bookmark);
  }

  @override
  Future<bool> startAccessing(String bookmark) async {
    if (!isSupported) return false;
    final ok = await _channel.invokeMethod<bool>('startAccessing', bookmark);
    return ok ?? false;
  }

  @override
  Future<void> stopAccessing(String bookmark) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('stopAccessing', bookmark);
  }
}

/// The desktop file-selector-backed ops (Windows/Linux): the native folder
/// dialog through `file_selector` (file_selector_windows is a compiled
/// plugin in the Windows runner) without security-scoped bookmarks — the
/// bookmark is always the empty string and the access lifecycle is a
/// success no-op, matching how [ProjectMountStore] persists the mount on
/// platforms that have no sandbox to re-grant.
final class ProjectFolderSelectorOps implements ProjectFolderOps {
  /// Creates the selector-backed ops.
  const ProjectFolderSelectorOps();

  @override
  Future<({String path, String bookmark})?> pickDirectory() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return null;
    return (path: path, bookmark: '');
  }

  @override
  Future<bool> startAccessing(String bookmark) async => true;

  @override
  Future<void> stopAccessing(String bookmark) async {}
}

/// The default [ProjectFolderOps] per platform: the security-scoped
/// channel on macOS/iOS (sandbox bookmarks), the plain file selector on
/// Windows/Linux, null on web/embedded targets.
ProjectFolderOps? defaultProjectFolderOps() {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux) {
    return const ProjectFolderSelectorOps();
  }
  if (ProjectFolderChannelOps.isSupported) {
    return const ProjectFolderChannelOps();
  }
  return null;
}
