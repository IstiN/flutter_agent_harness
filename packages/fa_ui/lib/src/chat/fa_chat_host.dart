// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A file picked by the host for attachment (already read into memory).
typedef FaChatUploadFile = ({String name, Uint8List bytes, String mimeType});

/// Picks files to attach (host's file/image picker). Returns an empty list
/// when the user cancels.
typedef FaChatUploadPicker = Future<List<FaChatUploadFile>> Function();

/// Reads an image from the system clipboard for smart paste (host
/// capability — fa backs it with super_clipboard). Returns null when the
/// clipboard holds no image. Null hook = clipboard images are ignored and
/// paste falls back to text.
typedef FaClipboardImageReader = Future<FaChatUploadFile?> Function();

/// Analytics sink for chat events (`message_sent`, `approval_mode_changed`,
/// `voice_input_used`, ...). Optional; events are dropped when unset.
typedef FaChatAnalytics =
    void Function(String event, [Map<String, Object> params]);

/// Voice input surface for the composer mic button. Implemented by the host
/// (fa wraps its AsrApi + Whisper transcriber); when null, the mic button
/// is hidden regardless of [FaChatFeatures.voiceInput].
abstract interface class FaChatVoiceInput {
  /// Whether voice input can run here (platform + configured endpoint).
  bool get isAvailable;

  /// A human-readable reason voice is unavailable (shown as a snackbar);
  /// null when [isAvailable] is true.
  String? get unavailableReason;

  /// Starts recording; false when mic permission is denied.
  Future<bool> start();

  /// Stops recording and returns the transcribed text (null when the
  /// recording was empty or transcription failed). Implementations may
  /// throw — the composer surfaces the error as a snackbar.
  Future<String?> stopAndTranscribe();

  /// Aborts an in-flight recording without transcribing (the composer was
  /// disposed mid-take). Best effort: never leaves the native recorder
  /// running.
  Future<void> cancel();
}

/// Launches a js mini-app referenced by a tool result (fa-only feature).
typedef FaChatAppLauncher = void Function(BuildContext context, String appId);

/// Process-wide host hooks for the chat widgets, mirroring [FaUiHost]:
/// set once at startup, everything optional with documented fallbacks.
abstract final class FaChatHost {
  /// Analytics sink; events are dropped when unset.
  static FaChatAnalytics? analytics;

  /// Reports [event] to the [analytics] sink when one is installed.
  static void track(String event, [Map<String, Object> params = const {}]) {
    analytics?.call(event, params);
  }

  /// File picker for the composer attachment button. When null, the
  /// attachment row is hidden regardless of [FaChatFeatures.attachments].
  static FaChatUploadPicker? uploadPicker;

  /// Gallery-image picker for the composer attach sheet; null hides the
  /// "Gallery" entry.
  static FaChatUploadPicker? galleryPicker;

  /// Camera picker for the composer attach sheet; null hides the "Camera"
  /// entry.
  static FaChatUploadPicker? cameraPicker;

  /// Clipboard image reader for the composer's smart paste (Cmd/Ctrl+V);
  /// null skips the image probe and pastes text only.
  static FaClipboardImageReader? clipboardImageReader;

  /// Voice input for the composer mic button; null hides the mic.
  static FaChatVoiceInput? voiceInput;

  /// Mini-app launcher for js-app tool results; null hides the affordance.
  static FaChatAppLauncher? appLauncher;

  /// The Navigator key of the apps side panel on wide screens. Set by the
  /// host's wide layout shell when it mounts the panel, cleared on dispose.
  /// `pushJsApp` checks this first: when present, agent-launched apps open
  /// inside the panel instead of pushing a full-screen route over the whole
  /// shell.
  static GlobalKey<NavigatorState>? jsAppNavigatorKey;

  /// Builder of the files side panel shown by the toolbar's files button;
  /// null hides the button regardless of [FaChatFeatures.fileBrowser].
  static WidgetBuilder? fileBrowserBuilder;
}
