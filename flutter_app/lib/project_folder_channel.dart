import 'dart:io';

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

/// The method-channel-backed [ProjectFolderOps] (macOS only).
final class ProjectFolderChannelOps implements ProjectFolderOps {
  /// Creates the ops over the `fah/project_folder` channel.
  const ProjectFolderChannelOps();

  /// Whether native project-folder picking is available (macOS only).
  static bool get isSupported => Platform.isMacOS;

  static const _channel = MethodChannel('fah/project_folder');

  @override
  Future<({String path, String bookmark})?> pickDirectory() async {
    if (!isSupported) return null;
    final result = await _channel.invokeMapMethod<String, String>(
      'pickDirectory',
    );
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
