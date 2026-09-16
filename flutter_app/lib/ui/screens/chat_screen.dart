// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/dynamic_messages_sheet.dart';
import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/apps/dynamic_widget_graduation.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/codemie_sso_flow.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/image_preview_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:fa/ui/widgets/fah_wallpaper.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/media_player.dart';

// The screen itself lives in the fa_ui package; these symbols stay
// re-exported so existing imports of this path keep working.
export 'package:fa_ui/fa_ui.dart' show kWideLayoutBreakpoint;

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
    this.onAppsToggle,
    this.projectIcon,
    this.projectIconColor,
    this.projectLabel,
    this.onProjectTap,
    this.modelChip,
    this.onModelChipTap,
    this.chipMenuLabel,
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

  /// Invoked by the bar's Apps toggle (issue #224) right before popping:
  /// on the narrow full-chat route the tap must land on the apps grid, so
  /// the hosting sheet collapses itself underneath the popped route. The
  /// wide shell passes null (the button is narrow-only anyway).
  final VoidCallback? onAppsToggle;

  /// The adaptive header's project slot (issue #225): the hosting layout
  /// renders the project identity inline in the chat bar instead of a
  /// separate project row above the chat. Null renders no project slot.
  final IconData? projectIcon;

  /// The project icon color (indigo when the session has a folder).
  final Color? projectIconColor;

  /// The project identity label ("Personal" or the folder basename).
  final String? projectLabel;

  /// Invoked on the project pill's tap (the wide shell's session info).
  final VoidCallback? onProjectTap;

  /// The inline quick-model chip in the merged header (host-built).
  final Widget? modelChip;

  /// Invoked when the demoted model chip is picked from the header ⋮
  /// menu (issue #225 AC3 — model switching at narrow widths).
  final VoidCallback? onModelChipTap;

  /// The ⋮-menu row label for the demoted model chip (the model id).
  final String? chipMenuLabel;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    _installAppLauncher();
    _installDynamicHosts();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _uninstallAppLauncher();
    _uninstallDynamicHosts();
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

  /// The dynamic-message host hooks are package-level statics resolved at
  /// render time against [ChatScreen.service] — always the active
  /// session's service, so session switches need no re-install. (The
  /// inline widget tile itself is passed to [fa_ui.FaChatScreen] in
  /// [build] — per surface, not process-wide: issue #336.)
  void _installDynamicHosts() {
    // The ✦ affordance (issue #102) as an adaptive-header action
    // (issue #225): the host-styled button stays the inline bar widget,
    // and its label/handler feed the ⋮ menu when the action demotes on
    // tight widths.
    fa_ui.FaChatHost.dynamicMessagesButtonBuilder = (context, chatService) {
      if (widget.service.dynamicMessages.widgets.isEmpty) return null;
      final service = chatService as AgentService;
      return fa_ui.FaChatHeaderAction(
        widget: DynamicMessagesButton(
          service: service,
          onSaveAsApp: _graduateWidget,
        ),
        label: context.l10n.dynamicMessagesButtonTooltip,
        onPressed: () => unawaited(
          showDynamicMessagesSheet(
            context,
            service: service,
            onSaveAsApp: _graduateWidget,
          ),
        ),
      );
    };
    // The Apps toggle (issue #224): narrow full-chat only in v1 — tapping
    // pops back to the launcher home (apps expand; the sheet collapses
    // itself via [ChatScreen.onAppsToggle]). The wide apps-panel wiring is
    // a follow-up, so the wide bar renders exactly as before (null).
    fa_ui.FaChatHost.appsToggleButtonBuilder = (context, chatService) {
      if (MediaQuery.sizeOf(context).width >= fa_ui.kWideLayoutBreakpoint) {
        return null;
      }
      void toggle() {
        widget.onAppsToggle?.call();
        Navigator.of(context).maybePop();
      }

      return fa_ui.FaChatHeaderAction(
        widget: IconButton(
          key: const ValueKey('chatAppsToggle'),
          icon: const Icon(Icons.apps),
          tooltip: context.l10n.appsShowAppsTooltip,
          onPressed: toggle,
        ),
        label: context.l10n.appsShowAppsTooltip,
        onPressed: toggle,
      );
    };
  }

  void _uninstallDynamicHosts() {
    fa_ui.FaChatHost.dynamicMessagesButtonBuilder = null;
    fa_ui.FaChatHost.appsToggleButtonBuilder = null;
  }

  /// One-tap "save as app": the shared graduation (issue #457 AC3 —
  /// every construction path wires the same helper).
  Future<void> _graduateWidget(DynamicMessageDefinition definition) =>
      graduateDynamicWidget(context, widget.service, definition);

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

  /// The live dynamic-message tile for this surface's transcript
  /// (issue #336): resolved per render against this screen's service.
  Widget? _buildDynamicTile(BuildContext context, fa_ui.FaChatMessage message) {
    return DynamicWidgetTile(
      service: widget.service.dynamicMessages,
      message: message,
      onSaveAsApp: _graduateWidget,
    );
  }

  /// The ✦ chip ephemeral open (issue #379): mirrors the tile menu's
  /// 'Open as app without saving'. Returning false — unknown or broken
  /// widget id — lets fa_ui fall back to scroll-to-widget.
  Future<bool> _openWidgetAsApp(fa_ui.FaChatMessage message) async {
    final id = message.data?.toString();
    final definition = id == null
        ? null
        : widget.service.dynamicMessages.byId(id);
    if (definition == null || !mounted) return false;
    await pushEphemeralDynamicApp(
      context,
      widget.service.dynamicMessages,
      definition,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return fa_ui.FaChatScreen(
      service: service,
      title: context.l10n.appTitle,
      dynamicWidgetTileBuilder: _buildDynamicTile,
      onOpenWidgetAsApp: _openWidgetAsApp,
      // Issue #207: "High-quality image previews" — the scope notifies on
      // toggle, so the open transcript re-decodes live. Null = full
      // resolution; the default keeps the downscaled 600px previews.
      imagePreviewCacheWidth:
          ImagePreviewScope.maybeOf(context)?.highQuality ?? false
          ? null
          : fa_ui.kDefaultImagePreviewCacheWidth,
      projectIcon: widget.projectIcon,
      projectIconColor: widget.projectIconColor,
      projectLabel: widget.projectLabel,
      onProjectTap: widget.onProjectTap,
      modelChip: widget.modelChip,
      onModelChipTap: widget.onModelChipTap,
      chipMenuLabel: widget.chipMenuLabel,
      settingsBuilder: (_) => SettingsScreen(
        service: service,
        env: service.env,
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
      composerBuilder: (context, chatService, drop) => ChatComposer(
        service: chatService as AgentService,
        uploadPicker: widget.uploadPicker,
        asr: widget.asr,
        asrTranscriber: widget.asrTranscriber,
        dropBridge: drop,
      ),
      onPermissionAction: (permission, action) {
        if (action == 'openSettings') {
          _openSystemSettings(permission);
        } else if (action == 'tryAgain') {
          unawaited(
            service.sendText(
              'Please try again — I just granted access.',
            ), // l10n:ignore — agent-facing text
          );
        }
      },
      onAuthRecovery: (providerId) async {
        if (providerId != 'codemie') return;
        final ok = await runCodemieSsoFlow(
          context: context,
          registry: widget.registry ?? ProviderRegistry.inMemory(),
          service: service,
          lastConnectionStore:
              widget.lastConnectionStore ?? LastConnectionStore.inMemory(),
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Authorization successful — try sending your message again.'
                  : 'Authorization cancelled.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      },
      audioControllerFactory: widget.audioControllerFactory,
      wallpaperBuilder: (_) => const FahWallpaper(),
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
  // No system privacy panes exist on the web (and dart:io Platform throws
  // there) — nothing to open.
  if (kIsWeb) return;
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
