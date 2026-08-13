// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/media_player.dart';

// The screen itself lives in the fa_ui package; these symbols stay
// re-exported so existing imports of this path keep working.
export 'package:fa_ui/fa_ui.dart'
    show chatImageMessageSource, kWideLayoutBreakpoint;

/// A chat UI backed by [FlutterSessionManager], built on top of
/// `flutter_chat_ui`.
///
/// The implementation lives in the `fa_ui` package ([fa_ui.FaChatScreen]);
/// this adapter keeps the app's multi-session surface: it owns the
/// [FlutterSessionManager] subscription (session switch → the shared screen
/// gets the new active service; closing the last session clones a fresh
/// one), wires the fa-specific affordances (settings route, file browser,
/// JS-app launcher, the composer's picker/ASR fakes) and translates them
/// into the package's host hooks.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.manager,
    this.uploadPicker,
    this.registry,
    this.lastConnectionStore,
    this.asr,
    this.asrTranscriber,
    this.audioControllerFactory,
    this.videoControllerFactory,
  });

  /// The multi-session manager owning the active [AgentService].
  final FlutterSessionManager manager;

  /// The active session's widget.service. Convenience accessor so the rest of
  /// the screen does not need to know about the manager indirection.
  AgentService get service => manager.active!.service;

  /// The config used to clone a fresh session when the active one is closed
  /// and none remain. Falls back to the most recent session's config.
  AgentConfig get _configForNewSession {
    final config =
        manager.active?.service.configForClone ??
        manager.sessions.last.service.configForClone;
    if (config == null) {
      throw StateError('No session config available to clone from');
    }
    return config;
  }

  /// File chooser behind the attach sheet's "Attach file" entry.
  /// Defaults to the platform picker (`null` off the web → the entry is
  /// hidden); tests inject a fake.
  final UploadPicker? uploadPicker;

  /// The custom-provider registry shared with the settings dialog;
  /// `null` falls back to an in-memory one inside the form (tests).
  final ProviderRegistry? registry;

  /// The last-connection store handed to the settings dialog: its
  /// applies update it (see [LastConnectionStore]); `null` skips prefill and
  /// persistence (tests).
  final LastConnectionStore? lastConnectionStore;

  /// Microphone backend for the composer's voice-input button; `null` uses
  /// the platform service ([createAsrService]). Tests inject a fake.
  final AsrApi? asr;

  /// Transcriber for voice input; `null` derives one from the active
  /// session's provider config at stop time (an OpenAI-compatible
  /// endpoint). Tests inject a fake.
  final AsrTranscriber? asrTranscriber;

  /// Playback engine factory for inline audio players (sandbox-generated
  /// `speak`/`generate_music`/`.mp3…` media); null uses the real
  /// `audioplayers`-backed controller. Tests/goldens inject fakes.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video players (`.mp4`/`.mov`/
  /// `.webm` sandbox media); null uses the real `video_player`-backed
  /// controller. Tests/goldens inject fakes.
  final SandboxVideoControllerFactory? videoControllerFactory;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    _installAppLauncher();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _uninstallAppLauncher();
    super.dispose();
  }

  void _onManagerChanged() {
    if (widget.manager.active == null) {
      // The active session was closed and none remain: create a fresh one so
      // the chat never points at a removed session.
      widget.manager.ensureActiveSession(
        config: widget._configForNewSession,
        serviceFactory: () async => widget.service.clone(),
      );
      return;
    }
    // Session switch: the rebuild below hands the shared screen the new
    // active service; it re-subscribes and re-syncs in place.
    _installAppLauncher();
    if (mounted) setState(() {});
  }

  /// The open_app tool's launcher lives on the active [AgentService] (its
  /// [AppLauncher] type is fa-specific, so the shared screen cannot install
  /// it). Setting a non-null launcher registers the tool.
  void _installAppLauncher() {
    widget.service.appLauncher = _launchApp;
  }

  void _uninstallAppLauncher() {
    final active = widget.manager.active;
    if (active != null && active.service.appLauncher == _launchApp) {
      active.service.appLauncher = null;
    }
  }

  /// Opens a JS app for the user (the agent's `open_app` tool): the same
  /// navigation the launcher's app tiles perform, pushed on this screen's
  /// Navigator — the visible transition is the confirmation affordance.
  /// A host-installed [fa_ui.FaChatHost.appLauncher] wins when set.
  ///
  /// Fire-and-forget: [pushJsApp] awaits the pushed route, which completes
  /// only when the user LEAVES the app — awaiting it here would block the
  /// agent's tool call (and its result to the model) until then.
  Future<void> _launchApp(JsAppInfo app) async {
    if (!mounted) return;
    final launcher = fa_ui.FaChatHost.appLauncher;
    if (launcher != null) {
      launcher(context, app.id);
      return;
    }
    unawaited(
      pushJsApp(
        context,
        manager: widget.manager,
        app: app,
        source: 'tool',
      ).catchError((Object e) {
        debugPrint('open_app navigation failed: $e');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return fa_ui.FaChatScreen(
      service: service,
      title: context.l10n.appTitle,
      settingsBuilder: (_) => SettingsScreen(
        service: service,
        registry: widget.registry,
        lastConnectionStore: widget.lastConnectionStore,
      ),
      fileBrowserBuilder: (context) =>
          MediaQuery.sizeOf(context).width >= fa_ui.kWideLayoutBreakpoint
          ? FileBrowser(
              env: service.env,
              fsRevision: service.fsRevision,
              onProjectMountChanged: service.refreshProjectMountPrompt,
            )
          : FileBrowser(
              env: service.env,
              inlinePreview: false,
              fsRevision: service.fsRevision,
              onProjectMountChanged: service.refreshProjectMountPrompt,
            ),
      composerBuilder: (context, chatService) => ChatComposer(
        service: chatService as AgentService,
        uploadPicker: widget.uploadPicker,
        asr: widget.asr,
        asrTranscriber: widget.asrTranscriber,
      ),
      onPermissionAction: (permission, action) {
        if (action == 'openSettings') {
          _openSystemSettings(permission);
        } else if (action == 'tryAgain') {
          unawaited(
            service.sendText('Please try again — I just granted access.'),
          );
        }
      },
      audioControllerFactory: widget.audioControllerFactory,
      videoControllerFactory: widget.videoControllerFactory,
    );
  }
}

/// Opens the system settings page for the given [permission] (calendar,
/// contacts, home, health, microphone, notifications).
///
/// macOS uses `x-apple.systempreferences:` deep links to the specific
/// Privacy & Security pane; iOS opens the app's settings page.
void _openSystemSettings(String permission) {
  final String url;
  if (Platform.isMacOS) {
    final pane = switch (permission.toLowerCase()) {
      'calendar' => 'Privacy_Calendars',
      'contacts' => 'Privacy_Contacts',
      'home' || 'homekit' => 'Privacy_HomeKit',
      'microphone' => 'Privacy_Microphone',
      'notification' || 'notifications' => null, // notifications pane
      _ => 'Privacy_Calendars', // fallback
    };
    url = pane != null
        ? 'x-apple.systempreferences:com.apple.preference.security?$pane'
        : 'x-apple.systempreferences:com.apple.preference.notifications';
  } else {
    // iOS: open the app's settings page (user navigates to the permission).
    url = 'app-settings:';
  }
  unawaited(
    url_launcher.launchUrl(
      Uri.parse(url),
      mode: url_launcher.LaunchMode.externalApplication,
    ),
  );
}
