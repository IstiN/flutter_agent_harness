// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

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
        MemoryExecutionEnv,
        RequestSecretResult;
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/app_theme.dart';
import '../theme/fa_ui_theme.dart';
import 'approval_ui.dart';
import 'ask_ui.dart';
import 'chat_composer.dart';
import 'chat_message_tile.dart';
import 'chat_strings.dart';
import 'fa_chat_features.dart';
import 'fa_chat_host.dart';
import 'fa_chat_service.dart';
import 'markdown_style.dart';
import 'media_player.dart';
import 'secret_request_sheet.dart';

/// Minimum body width (logical px) at which the files panel becomes a
/// persistent, collapsible panel instead of an end drawer.
const double kWideLayoutBreakpoint = 900;

/// Width of the files side panel / end drawer.
const double kFaChatFilesPanelWidth = 300;

/// Builds the composer's replacement / customization point; null uses the
/// default [ChatComposer] driven by [FaChatFeatures] and the host hooks.
typedef FaChatComposerBuilder =
    Widget Function(BuildContext context, FaChatService service);

/// A chat UI over a single [FaChatService], built on top of
/// `flutter_chat_ui`.
///
/// Text messages are rendered as Markdown, tool calls/results are shown as
/// distinct cards, and image attachments are supported. Multi-session
/// management is the host's job: hand a different [service] and the screen
/// re-subscribes and re-syncs in place. The optional affordances (files
/// panel, settings gear, composer pickers/voice) come from [features], the
/// constructor overrides, and the [FaChatHost] hooks.
class FaChatScreen extends StatefulWidget {
  const FaChatScreen({
    super.key,
    required this.service,
    this.features = const FaChatFeatures(),
    this.title = 'Fa',
    this.settingsBuilder,
    this.fileBrowserBuilder,
    this.composerBuilder,
    this.audioControllerFactory,
    this.videoControllerFactory,
  });

  /// The session this screen renders and sends to.
  final FaChatService service;

  /// Capability flags; everything optional degrades cleanly when off.
  final FaChatFeatures features;

  /// The app bar title.
  final String title;

  /// Builder of the settings route pushed by the app bar gear; null hides
  /// the gear.
  final WidgetBuilder? settingsBuilder;

  /// Builder of the files side panel (wide) / end drawer (narrow) content;
  /// overrides [FaChatHost.fileBrowserBuilder]. Null (with no host hook)
  /// hides the files button regardless of [FaChatFeatures.fileBrowser].
  final WidgetBuilder? fileBrowserBuilder;

  /// Replacement composer; null builds the default [ChatComposer] with
  /// [features].
  final FaChatComposerBuilder? composerBuilder;

  /// Playback engine factory for inline audio players; null uses the real
  /// `audioplayers`-backed controller. Tests/goldens inject fakes.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video players; null uses the real
  /// `video_player`-backed controller. Tests/goldens inject fakes.
  final SandboxVideoControllerFactory? videoControllerFactory;

  @override
  State<FaChatScreen> createState() => _FaChatScreenState();
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

class _FaChatScreenState extends State<FaChatScreen>
    with TickerProviderStateMixin {
  late final InMemoryChatController _chatController;

  /// Own scroll controller for the message list (injected via
  /// [Builders.chatAnimatedListBuilder]) so the follow-tail logic can track
  /// whether the user is at the bottom and keep up with streaming updates —
  /// the library only auto-scrolls on inserts, not on in-place updates.
  final _chatScrollController = ScrollController();
  bool _userNearBottom = true;

  /// Loads sandbox images referenced from Markdown / `generate_image` tool
  /// results through the session's env (memoized — see
  /// [SandboxImageResolver]).
  SandboxImageResolver? _sandboxImages;

  /// Shared dummy env for hosts without a sandbox
  /// ([FaChatService.sandboxEnv] is null): every read fails, so sandbox
  /// images/media render their dim placeholders.
  static final MemoryExecutionEnv _noSandboxEnv = MemoryExecutionEnv();

  SandboxImageResolver get _images {
    final env = widget.service.sandboxEnv ?? _noSandboxEnv;
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

  /// Whether the file browser side panel is expanded (wide layouts only).
  bool _filesPanelOpen = false;

  /// The files panel content builder: the constructor override, else the
  /// host hook.
  WidgetBuilder? get _fileBrowserBuilder =>
      widget.fileBrowserBuilder ?? FaChatHost.fileBrowserBuilder;

  /// Opens the file browser: toggles the right side panel on wide layouts,
  /// opens the end drawer on narrow ones. [context] must be below the
  /// [Scaffold].
  void _openFiles(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
      setState(() => _filesPanelOpen = !_filesPanelOpen);
      if (_filesPanelOpen) {
        FaChatHost.track('files_opened', {'source': 'chat'});
      }
    } else {
      FaChatHost.track('files_opened', {'source': 'chat'});
      Scaffold.of(context).openEndDrawer();
    }
  }

  @override
  void initState() {
    super.initState();
    FaChatHost.track('screen_opened', {'screen_name': 'chat'});
    _chatController = InMemoryChatController();
    _chatScrollController.addListener(_trackNearBottom);
    _subscribeToService(widget.service);
    _isStreaming = widget.service.isStreaming;
    _error = widget.service.error;
    _syncMessages();
  }

  @override
  void didUpdateWidget(covariant FaChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      // The host swapped sessions (close/switch): re-subscribe and re-sync.
      _unsubscribeFromService(oldWidget.service);
      _subscribeToService(widget.service);
      _isStreaming = widget.service.isStreaming;
      _error = widget.service.error;
      _syncMessages();
      setState(() {});
    }
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

  void _subscribeToService(FaChatService service) {
    service.addListener(_onServiceChanged);
    // This screen renders approval prompts as Material dialogs; clearing the
    // handler on dispose restores the deny-by-default for headless runs.
    if (widget.features.approvals) {
      service.approvalPromptHandler = _handleApprovalPrompt;
    }
    // Same pattern for the ask tool: this screen renders the questions as a
    // modal bottom sheet; without a handler, ask calls resolve as cancelled.
    if (widget.features.askSheets) {
      service.askHandler = _handleAskQuestions;
    }
    // And for the request_secret tool: this screen renders the credential
    // prompt as a modal bottom sheet; without a handler, requests resolve as
    // declined. The service persists and activates a granted key itself.
    if (widget.features.secretRequests) {
      service.secretRequestHandler = _handleSecretRequest;
    }
  }

  void _unsubscribeFromService(FaChatService service) {
    service.removeListener(_onServiceChanged);
    if (service.approvalPromptHandler == _handleApprovalPrompt) {
      service.approvalPromptHandler = null;
    }
    if (service.askHandler == _handleAskQuestions) {
      service.askHandler = null;
    }
    if (service.secretRequestHandler == _handleSecretRequest) {
      service.secretRequestHandler = null;
    }
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
    _unsubscribeFromService(widget.service);
    _chatController.dispose();
    super.dispose();
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

  Future<Message> _toMessage(int index, FaChatMessage chat) async {
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
    await Clipboard.setData(
      ClipboardData(text: widget.service.transcriptMarkdown()),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(FaChatStrings.of(context).chatCopiedToClipboard),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Opens the host's settings route (gear icon).
  Future<void> _openSettings() async {
    final builder = widget.settingsBuilder;
    if (builder == null) return;
    FaChatHost.track('settings_opened');
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
  }

  // Text and custom (tool/thinking/system) messages share one renderer —
  // see ChatMessageTile.
  Widget _buildTextMessage(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    return ChatMessageTile(
      message: FaChatMessage(
        role: isSentByMe ? 'user' : 'assistant',
        content: message.text,
      ),
      images: _images,
      audioControllerFactory: widget.audioControllerFactory,
      videoControllerFactory: widget.videoControllerFactory,
    );
  }

  /// Renders attached-image messages (user uploads and in-app screenshots)
  /// as a compact thumbnail; tap opens the full image. Without an
  /// imageMessageBuilder flutter_chat_ui asserts and paints a red box.
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
      message: FaChatMessage(
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
    final composerBuilder = widget.composerBuilder;
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
                ? buildFahChatThemeLight(uiTheme: FaUiThemeProvider.of(context))
                : buildFahChatTheme(uiTheme: FaUiThemeProvider.of(context)),
          ),
        ),
        composerBuilder != null
            ? composerBuilder(context, widget.service)
            : ChatComposer(service: widget.service, features: widget.features),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = FaChatStrings.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    final fileBrowserBuilder = widget.features.fileBrowser
        ? _fileBrowserBuilder
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_isStreaming)
            IconButton(
              icon: const Icon(Icons.stop),
              tooltip: strings.chatAbortTooltip,
              onPressed: widget.service.abort,
            ),
          if (fileBrowserBuilder != null)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.folder_outlined),
                tooltip: strings.chatFilesTooltip,
                onPressed: () => _openFiles(context),
              ),
            ),
          if (widget.features.copyTranscript)
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: strings.chatCopySessionTooltip,
              onPressed: _copySession,
            ),
          if (widget.settingsBuilder != null)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: strings.chatSettingsTooltip,
              onPressed: _openSettings,
            ),
        ],
      ),
      endDrawer: isWide || fileBrowserBuilder == null
          ? null
          : Drawer(
              width: kFaChatFilesPanelWidth,
              child: SafeArea(child: fileBrowserBuilder(context)),
            ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _buildChatBody(context)),
          if (isWide && _filesPanelOpen && fileBrowserBuilder != null) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: kFaChatFilesPanelWidth,
              child: fileBrowserBuilder(context),
            ),
          ],
        ],
      ),
    );
  }
}
