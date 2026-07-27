import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        ApprovalDecision,
        ApprovalRequest,
        AskAnswer,
        AskQuestion,
        RequestSecretResult;
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/analytics.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/approval_ui.dart';
import 'package:fa/ui/widgets/ask_ui.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/ui/markdown_style.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:fa/ui/widgets/chat_message_tile.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:fa/ui/widgets/secret_request_sheet.dart';
import 'package:fa/ui/widgets/session_sidebar.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/services/upload.dart';

/// Minimum body width (logical px) at which the side panels (sessions/model
/// on the left, files on the right) become persistent, collapsible panels
/// instead of drawers — and below which the apps launcher (see
/// `AppLauncherScreen`) replaces this screen as the app home.
const double kWideLayoutBreakpoint = 900;

/// A chat UI backed by [FlutterSessionManager], built on top of
/// `flutter_chat_ui`.
///
/// Text messages are rendered as Markdown, tool calls/results are shown as
/// distinct cards, and image attachments are supported.
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

  /// The active session's widget.service. Convenience accessor so the rest of the
  /// screen does not need to know about the manager indirection.
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

  /// The custom-provider registry shared with the settings dialog/sidebar;
  /// `null` falls back to an in-memory one inside the form (tests).
  final ProviderRegistry? registry;

  /// The last-connection store handed to the settings dialog/sidebar: their
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

/// The `source` for an attached-image chat message.
///
/// On IO platforms the bytes land in a temp file. The web has no `dart:io`
/// filesystem (`getTemporaryDirectory` throws there — and the resulting
/// unhandled error used to repeat on every chat sync), so the bytes ride
/// inside a `data:` URI instead.
Future<String> chatImageMessageSource(
  int index,
  Uint8List bytes, {
  required bool isWeb,
}) async {
  if (isWeb) {
    return 'data:image/png;base64,${base64Encode(bytes)}';
  }
  final tmp = await getTemporaryDirectory();
  final file = File('${tmp.path}/fah_chat_image_$index.png');
  if (!file.existsSync() || file.lengthSync() != bytes.length) {
    await file.writeAsBytes(bytes);
  }
  return file.path;
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  late final InMemoryChatController _chatController;

  /// Own scroll controller for the message list (injected via
  /// [Builders.chatAnimatedListBuilder]) so the follow-tail logic can track
  /// whether the user is at the bottom and keep up with streaming updates —
  /// the library only auto-scrolls on inserts, not on in-place updates.
  final _chatScrollController = ScrollController();
  bool _userNearBottom = true;

  /// Loads sandbox images referenced from Markdown / `generate_image` tool
  /// results through the active session's env (memoized — see
  /// [SandboxImageResolver]).
  SandboxImageResolver? _sandboxImages;

  SandboxImageResolver get _images {
    final env = widget.service.env;
    final resolver = _sandboxImages;
    if (resolver == null || resolver.env != env) {
      return _sandboxImages = SandboxImageResolver(env);
    }
    return resolver;
  }

  final _user = const User(id: 'user', name: 'Me');
  final _assistant = const User(id: 'assistant', name: 'Fa');
  final _tool = const User(id: 'tool', name: 'tool');
  final _system = const User(id: 'system', name: 'system');

  List<Message> _lastSynced = [];
  Timer? _syncDebounce;
  bool _isSyncing = false;
  bool _isStreaming = false;
  String? _error;

  /// Whether the left session/model sidebar is expanded (wide layouts only).
  bool _leftPanelOpen = true;

  /// Whether the file browser side panel is expanded (wide layouts only).
  bool _filesPanelOpen = false;

  /// Opens the session/model sidebar: toggles the side panel on wide
  /// layouts, opens the drawer on narrow ones. [context] must be below the
  /// [Scaffold].
  void _openSidebar(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
      setState(() => _leftPanelOpen = !_leftPanelOpen);
    } else {
      Scaffold.of(context).openDrawer();
    }
  }

  /// Opens the file browser: toggles the right side panel on wide layouts,
  /// opens the end drawer on narrow ones. [context] must be below the
  /// [Scaffold].
  void _openFiles(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
      setState(() => _filesPanelOpen = !_filesPanelOpen);
    } else {
      Scaffold.of(context).openEndDrawer();
    }
  }

  @override
  void initState() {
    super.initState();
    _chatController = InMemoryChatController();
    _chatScrollController.addListener(_trackNearBottom);
    widget.manager.addListener(_onManagerChanged);
    _subscribeToService();
    _isStreaming = widget.service.isStreaming;
    _error = widget.service.error;
    _syncMessages();
  }

  /// The follow-tail latch (YoLoIT's pattern): scrolling up unlatches,
  /// scrolling back to the bottom relatches. Streaming then keeps the tail
  /// pinned only while the user is at the bottom.
  void _trackNearBottom() {
    if (!_chatScrollController.hasClients) return;
    final position = _chatScrollController.position;
    _userNearBottom = position.maxScrollExtent - position.pixels < 150;
  }

  DateTime _lastTailScroll = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pins the chat to the tail after a sync when the user hasn't scrolled
  /// away. Runs post-frame so the new content has been laid out. Throttled:
  /// during heavy streaming (50 ms sync debounce) constant re-animation
  /// would stutter.
  void _scrollToTailIfFollowing() {
    if (!_userNearBottom) return;
    final now = DateTime.now();
    if (now.difference(_lastTailScroll).inMilliseconds < 400) return;
    _lastTailScroll = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScrollController.hasClients) return;
      final maxExtent = _chatScrollController.position.maxScrollExtent;
      if ((maxExtent - _chatScrollController.offset).abs() < 1) return;
      _chatScrollController.animateTo(
        maxExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.linearToEaseOut,
      );
    });
  }

  void _subscribeToService() {
    widget.service.addListener(_onServiceChanged);
    // This screen renders approval prompts as Material dialogs; clearing the
    // handler on dispose restores the deny-by-default for headless runs.
    widget.service.approvalPromptHandler = _handleApprovalPrompt;
    // Same pattern for the ask tool: this screen renders the questions as a
    // modal bottom sheet; without a handler, ask calls resolve as cancelled.
    widget.service.askHandler = _handleAskQuestions;
    // And for the request_secret tool: this screen renders the credential
    // prompt as a modal bottom sheet; without a handler, requests resolve as
    // declined. The service persists and activates a granted key itself.
    widget.service.secretRequestHandler = _handleSecretRequest;
    // And for the open_app tool: this screen owns the Navigator, so it
    // pushes the app's JsAppView; without a launcher the tool is absent.
    widget.service.appLauncher = _launchApp;
  }

  void _unsubscribeFromService() {
    final active = widget.manager.active;
    if (active == null) return;
    active.service.removeListener(_onServiceChanged);
    if (active.service.approvalPromptHandler == _handleApprovalPrompt) {
      active.service.approvalPromptHandler = null;
    }
    if (active.service.askHandler == _handleAskQuestions) {
      active.service.askHandler = null;
    }
    if (active.service.secretRequestHandler == _handleSecretRequest) {
      active.service.secretRequestHandler = null;
    }
    if (active.service.appLauncher == _launchApp) {
      active.service.appLauncher = null;
    }
  }

  /// Opens a JS app for the user (the agent's `open_app` tool): the exact
  /// navigation the sidebar's Apps section performs, pushed on this screen's
  /// Navigator — the visible transition is the confirmation affordance.
  ///
  /// Fire-and-forget: [pushJsApp] awaits the pushed route, which completes
  /// only when the user LEAVES the app — awaiting it here would block the
  /// agent's tool call (and its result to the model) until then.
  Future<void> _launchApp(JsAppInfo app) async {
    if (!mounted) return;
    unawaited(
      pushJsApp(context, manager: widget.manager, app: app).catchError((
        Object e,
      ) {
        debugPrint('open_app navigation failed: $e');
      }),
    );
  }

  Future<ApprovalDecision> _handleApprovalPrompt(ApprovalRequest request) {
    if (!mounted) return Future.value(ApprovalDecision.deny);
    return showApprovalPrompt(context, request);
  }

  Future<List<AskAnswer>?> _handleAskQuestions(List<AskQuestion> questions) {
    if (!mounted) return Future.value(null);
    return showAskSheet(context, questions);
  }

  Future<RequestSecretResult?> _handleSecretRequest(
    String name,
    String reason,
  ) {
    if (!mounted) return Future.value(null);
    return showSecretRequestSheet(context, name, reason);
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _chatScrollController.dispose();
    widget.manager.removeListener(_onManagerChanged);
    _unsubscribeFromService();
    _chatController.dispose();
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
    _unsubscribeFromService();
    _subscribeToService();
    _syncMessages();
    if (mounted) setState(() {});
  }

  void _onServiceChanged() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _syncMessages();
    });

    final needsRebuild =
        widget.service.isStreaming != _isStreaming ||
        widget.service.error != _error;
    if (needsRebuild) {
      _isStreaming = widget.service.isStreaming;
      _error = widget.service.error;
      if (mounted) setState(() {});
    }
  }

  Future<void> _syncMessages() async {
    if (_isSyncing) {
      _syncDebounce?.cancel();
      _syncDebounce = Timer(const Duration(milliseconds: 50), () {
        if (mounted) _syncMessages();
      });
      return;
    }
    _isSyncing = true;

    try {
      final converted = await Future.wait(
        widget.service.messages.indexed.map(
          (entry) => _toMessage(entry.$1, entry.$2),
        ),
      );
      final newList = converted.toList();

      if (_lastSynced.isEmpty || newList.isEmpty) {
        await _chatController.setMessages(newList);
      } else {
        final oldLen = _lastSynced.length;
        final newLen = newList.length;
        final minLen = math.min(oldLen, newLen);

        var commonPrefix = 0;
        while (commonPrefix < minLen &&
            _lastSynced[commonPrefix].id == newList[commonPrefix].id) {
          commonPrefix++;
        }

        for (var i = 0; i < commonPrefix; i++) {
          if (_messageChanged(_lastSynced[i], newList[i])) {
            await _chatController.updateMessage(_lastSynced[i], newList[i]);
          }
        }

        for (var i = oldLen - 1; i >= commonPrefix; i--) {
          await _chatController.removeMessage(_lastSynced[i]);
        }

        for (var i = commonPrefix; i < newLen; i++) {
          await _chatController.insertMessage(newList[i], index: i);
        }
      }

      _lastSynced = newList;
      _scrollToTailIfFollowing();
    } on Object catch (e, stack) {
      // _syncMessages runs from a Timer callback: an escape here is an
      // unhandled async error that repeats on every service notification
      // (the "Uncaught Error" console storm). Log it and leave
      // _lastSynced stale so the next notification retries the sync.
      debugPrint('chat sync failed: $e\n$stack');
    } finally {
      _isSyncing = false;
    }
  }

  bool _messageChanged(Message a, Message b) {
    if (a.runtimeType != b.runtimeType) return true;
    return switch (a) {
      TextMessage textA => textA.text != (b as TextMessage).text,
      CustomMessage customA =>
        customA.metadata?.toString() !=
            (b as CustomMessage).metadata?.toString(),
      ImageMessage imageA =>
        // ignore: unnecessary_cast
        imageA.source != (b as ImageMessage).source ||
            // ignore: unnecessary_cast
            imageA.text != (b as ImageMessage).text,
      _ => true,
    };
  }

  Future<Message> _toMessage(int index, FahChatMessage chat) async {
    final id = 'msg-$index';
    final now = DateTime.now();

    switch (chat.role) {
      case 'user':
        if (chat.imageBytes != null) {
          final path = await chatImageMessageSource(
            index,
            chat.imageBytes!,
            isWeb: kIsWeb,
          );
          return Message.image(
            id: id,
            authorId: 'user',
            source: path,
            text: chat.content.isEmpty ? null : chat.content,
            createdAt: now,
          );
        }
        return Message.text(
          id: id,
          authorId: 'user',
          text: chat.content,
          createdAt: now,
        );
      case 'assistant':
        return Message.text(
          id: id,
          authorId: 'assistant',
          text: chat.content,
          createdAt: now,
        );
      case 'system':
      case 'tool':
      case 'thinking':
        return Message.custom(
          id: id,
          authorId: chat.role == 'tool' ? 'tool' : 'system',
          createdAt: now,
          metadata: <String, dynamic>{
            'role': chat.role,
            'toolName': chat.toolName,
            'content': chat.content,
            'isError': chat.isError,
          },
        );
      default:
        return Message.text(
          id: id,
          authorId: 'system',
          text: chat.content,
          createdAt: now,
        );
    }
  }

  Future<User?> _resolveUser(UserID id) async {
    return switch (id) {
      'user' => _user,
      'assistant' => _assistant,
      'tool' => _tool,
      'system' => _system,
      _ => User(id: id, name: id),
    };
  }

  /// Copies the whole session transcript to the clipboard as plain text.
  Future<void> _copySession() async {
    final buffer = StringBuffer();
    for (final m in widget.service.messages) {
      final header = switch (m.role) {
        'user' => '## You',
        'assistant' => '## Fa',
        'tool' => '## tool (${m.toolName ?? 'call'})',
        _ => '## ${m.role}',
      };
      buffer.writeln(header);
      if (m.imageBytes != null) buffer.writeln('[image attached]');
      if (m.content.isNotEmpty) buffer.writeln(m.content);
      buffer.writeln();
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.chatCopiedToClipboard),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Opens the BYOK connection settings (gear icon). Applying reconfigures
  /// this screen's service in place (see [AgentService.reconfigure]) — the
  /// visible transcript survives the backend switch.
  Future<void> _openSettings() async {
    AppAnalytics.instance.settingsOpened();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          service: widget.service,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
        ),
      ),
    );
  }

  // Text and custom (tool/thinking/system) messages share one renderer
  // with the in-app Fa chat overlay — see ChatMessageTile.
  Widget _buildTextMessage(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    return ChatMessageTile(
      message: FahChatMessage(
        role: isSentByMe ? 'user' : 'assistant',
        content: message.text,
      ),
      images: _images,
      audioControllerFactory: widget.audioControllerFactory,
      videoControllerFactory: widget.videoControllerFactory,
    );
  }

  /// Renders attached-image messages (user uploads and the in-app Fa
  /// screenshot) as a compact thumbnail; tap opens the full image. Without
  /// an imageMessageBuilder flutter_chat_ui asserts and paints a red box.
  Widget _buildImageMessage(
    BuildContext context,
    ImageMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final source = message.source;
    Widget image = source.startsWith('data:')
        ? Image.memory(
            base64Decode(source.split(',').last),
            // Decode at thumbnail scale — full-res app screenshots would
            // otherwise jank every chat rebuild.
            cacheWidth: 600,
          )
        : Image.file(File(source), cacheWidth: 600);
    image = ClipRRect(borderRadius: BorderRadius.circular(10), child: image);
    return Align(
      alignment: isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        constraints: const BoxConstraints(maxWidth: 280),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => _showFullImage(context, source),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: FahColors.of(context).border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: image,
              ),
            ),
            if (message.text?.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  message.text!,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showFullImage(BuildContext context, String source) {
    final Widget image = source.startsWith('data:')
        ? Image.memory(base64Decode(source.split(',').last))
        : Image.file(File(source));
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: InteractiveViewer(child: image),
      ),
    );
  }

  Widget _buildCustomMessage(
    BuildContext context,
    CustomMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final metadata = message.metadata ?? const {};
    return ChatMessageTile(
      message: FahChatMessage(
        role: (metadata['role'] as String?) ?? 'system',
        content: (metadata['content'] as String?) ?? '',
        toolName: metadata['toolName'] as String?,
        isError: (metadata['isError'] as bool?) ?? false,
      ),
      images: _images,
      audioControllerFactory: widget.audioControllerFactory,
      videoControllerFactory: widget.videoControllerFactory,
    );
  }

  Widget _buildChatBody(BuildContext context) {
    return Column(
      children: [
        if (_error case final error?)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.error, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: Chat(
            currentUserId: 'user',
            resolveUser: _resolveUser,
            chatController: _chatController,
            builders: Builders(
              textMessageBuilder: _buildTextMessage,
              customMessageBuilder: _buildCustomMessage,
              imageMessageBuilder: _buildImageMessage,
              chatAnimatedListBuilder: (context, itemBuilder) =>
                  ChatAnimatedList(
                    itemBuilder: itemBuilder,
                    scrollController: _chatScrollController,
                  ),
              composerBuilder: (_) => const SizedBox.shrink(),
            ),
            theme: Theme.of(context).brightness == Brightness.light
                ? buildFahChatThemeLight()
                : buildFahChatTheme(),
          ),
        ),
        ChatComposer(
          service: widget.service,
          uploadPicker: widget.uploadPicker,
          asr: widget.asr,
          asrTranscriber: widget.asrTranscriber,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: context.l10n.chatSessionsTooltip,
            onPressed: () => _openSidebar(context),
          ),
        ),
        title: Text(context.l10n.appTitle),
        actions: [
          if (_isStreaming)
            IconButton(
              icon: const Icon(Icons.stop),
              tooltip: context.l10n.chatAbortTooltip,
              onPressed: widget.service.abort,
            ),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.folder_outlined),
              tooltip: context.l10n.chatFilesTooltip,
              onPressed: () => _openFiles(context),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: context.l10n.chatCopySessionTooltip,
            onPressed: _copySession,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: context.l10n.chatSettingsTooltip,
            onPressed: _openSettings,
          ),
        ],
      ),
      drawer: isWide
          ? null
          : Drawer(
              width: kSessionSidebarWidth,
              child: SafeArea(
                child: Builder(
                  builder: (drawerContext) => SessionSidebar(
                    manager: widget.manager,
                    registry: widget.registry,
                    lastConnectionStore: widget.lastConnectionStore,
                    onAction: () => Scaffold.of(drawerContext).closeDrawer(),
                  ),
                ),
              ),
            ),
      endDrawer: isWide
          ? null
          : Drawer(
              width: kFileBrowserPanelWidth,
              child: SafeArea(
                child: FileBrowser(
                  env: widget.service.env,
                  inlinePreview: false,
                  fsRevision: widget.service.fsRevision,
                  onProjectMountChanged:
                      widget.service.refreshProjectMountPrompt,
                ),
              ),
            ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isWide && _leftPanelOpen) ...[
            SizedBox(
              width: kSessionSidebarWidth,
              child: SessionSidebar(
                manager: widget.manager,
                registry: widget.registry,
                lastConnectionStore: widget.lastConnectionStore,
              ),
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(child: _buildChatBody(context)),
          if (isWide && _filesPanelOpen) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: kFileBrowserPanelWidth,
              child: FileBrowser(
                env: widget.service.env,
                fsRevision: widget.service.fsRevision,
                onProjectMountChanged: widget.service.refreshProjectMountPrompt,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
