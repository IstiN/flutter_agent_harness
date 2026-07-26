import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ApprovalDecision, ApprovalRequest, AskAnswer, AskQuestion;
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fa/l10n/l10n_ext.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/approval_ui.dart';
import 'package:fa/ui/widgets/ask_ui.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/file_preview.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/ui/markdown_style.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:fa/ui/widgets/session_sidebar.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/services/upload_picker_stub.dart'
    if (dart.library.html) 'package:fa/services/upload_picker_web.dart';

/// Minimum body width (logical px) at which the side panels (sessions/model
/// on the left, files on the right) become persistent, collapsible panels
/// instead of drawers.
const double _kWideLayoutBreakpoint = 900;

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
  final _textController = TextEditingController();

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

  /// Files attached in the composer but not sent yet. They are staged into
  /// the sandbox `uploads/` folder at PICK time (see
  /// [AgentService.stageAttachment]) — attaching never sends anything by
  /// itself; on send the message references the staged [path]s plus the
  /// typed text.
  final List<({String name, String path, Uint8List bytes, String mimeType})>
  _pendingAttachments = [];

  List<Message> _lastSynced = [];
  Timer? _syncDebounce;
  bool _isSyncing = false;
  bool _isStreaming = false;
  String? _error;

  /// Whether the left session/model sidebar is expanded (wide layouts only).
  bool _leftPanelOpen = true;

  /// Whether the file browser side panel is expanded (wide layouts only).
  bool _filesPanelOpen = false;

  /// Arbitrary-file picker for the attach sheet's "Attach file" entry;
  /// `null` off the web, which hides the entry.
  late final UploadPicker? _uploadPicker =
      widget.uploadPicker ?? createUploadPicker();

  /// Microphone backend for the composer's voice-input button.
  late final AsrApi _asr = widget.asr ?? createAsrService();

  /// Voice-input state: idle → recording → transcribing → idle.
  bool _micRecording = false;
  bool _micTranscribing = false;

  /// Drives the red pulse of the recording-state mic button; runs only
  /// while recording (a repeating animation would keep `pumpAndSettle`
  /// from ever settling if left running). Created in [initState] — a
  /// `late` field touched first in [dispose] would create a ticker while
  /// the element is deactivating.
  late final AnimationController _micPulse;

  /// The transcriber for voice input: the injected one, or one resolved
  /// through the session's media gateway (the media_models.json
  /// `transcription` slot, falling back to the active provider). Resolved
  /// lazily per use so slot edits and a provider switch mid-session are
  /// picked up. Null means no ASR-capable endpoint is configured.
  Future<AsrTranscriber?> _resolveTranscriber() async {
    if (widget.asrTranscriber != null) return widget.asrTranscriber;
    final gateway = widget.service.mediaGateway;
    if (gateway != null) return whisperTranscriberForGateway(gateway);
    // Services built around a pre-constructed agent (tests) have no
    // gateway: fall back to the active provider's endpoint directly.
    final config = widget.service.configForClone;
    return whisperTranscriberFor(
      providerKind: widget.service.providerKind,
      baseUrl: config?.baseUrl ?? '',
      apiKey: config?.apiKey ?? '',
    );
  }

  /// Mic button tap: idle starts a recording (after the OS permission
  /// prompt), recording stops it and transcribes the take into the input
  /// field.
  Future<void> _toggleMic() async {
    if (_micTranscribing) return;
    if (_micRecording) {
      await _stopMic();
      return;
    }
    try {
      if (!await _asr.requestAccess()) {
        if (mounted) _showSnack(context.l10n.chatMicDenied);
        return;
      }
      await _asr.startRecording();
    } on Object catch (e) {
      if (mounted) _showSnack(context.l10n.chatMicError(e.toString()));
      return;
    }
    if (!mounted) return;
    setState(() => _micRecording = true);
    _micPulse.repeat(reverse: true);
  }

  Future<void> _stopMic() async {
    _micPulse.stop();
    final AsrRecording recording;
    try {
      recording = await _asr.stopRecording();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _micRecording = false);
        _showSnack(context.l10n.chatMicError(e.toString()));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _micRecording = false;
      _micTranscribing = true;
    });
    try {
      final transcriber = await _resolveTranscriber();
      if (!mounted) return;
      if (transcriber == null) {
        _showSnack(context.l10n.chatMicError(asrNoEndpointMessage));
        return;
      }
      final bytes = await _asr.readRecording(recording.path);
      final filename = recording.path.split(RegExp(r'[/\\]')).last;
      final transcript = await transcriber.transcribe(
        bytes: bytes,
        filename: filename,
      );
      if (!mounted || transcript.isEmpty) return;
      final current = _textController.text;
      final spacer = current.isNotEmpty && !current.endsWith(' ') ? ' ' : '';
      _textController.text = '$current$spacer$transcript';
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    } on Object catch (e) {
      if (mounted) _showSnack(context.l10n.chatMicError(e.toString()));
    } finally {
      if (mounted) setState(() => _micTranscribing = false);
    }
  }

  /// Opens the session/model sidebar: toggles the side panel on wide
  /// layouts, opens the drawer on narrow ones. [context] must be below the
  /// [Scaffold].
  void _openSidebar(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= _kWideLayoutBreakpoint) {
      setState(() => _leftPanelOpen = !_leftPanelOpen);
    } else {
      Scaffold.of(context).openDrawer();
    }
  }

  /// Opens the file browser: toggles the right side panel on wide layouts,
  /// opens the end drawer on narrow ones. [context] must be below the
  /// [Scaffold].
  void _openFiles(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= _kWideLayoutBreakpoint) {
      setState(() => _filesPanelOpen = !_filesPanelOpen);
    } else {
      Scaffold.of(context).openEndDrawer();
    }
  }

  @override
  void initState() {
    super.initState();
    _micPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
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

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _micPulse.dispose();
    if (_micRecording) {
      // Best effort: never leave the native recorder running.
      _asr.stopRecording().ignore();
    }
    _textController.dispose();
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

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _stagePending(picked.name, bytes);
  }

  /// Stages one picked file into `uploads/` right away and adds a pending
  /// chip for it. Failures surface as a snackbar — nothing is staged and
  /// nothing is sent.
  Future<void> _stagePending(String name, Uint8List bytes) async {
    final clean = sanitizeUploadName(name).split('/').last;
    if (clean.isEmpty) {
      _showSnack(context.l10n.chatAttachNoName(name));
      return;
    }
    try {
      final path = await widget.service.stageAttachment(
        name: clean,
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() {
        _pendingAttachments.add((
          name: clean,
          path: path,
          bytes: bytes,
          mimeType: mimeTypeForUploadName(clean),
        ));
      });
    } on Object catch (e) {
      if (mounted) {
        _showSnack(context.l10n.chatAttachError(e.toString(), clean));
      }
    }
  }

  void _removePendingAttachment(int index) {
    final removed = _pendingAttachments[index];
    setState(() => _pendingAttachments.removeAt(index));
    // The file was staged at pick time; removing the chip drops it again
    // (best effort — a leftover in uploads/ is harmless).
    unawaited(widget.service.discardStagedAttachment(removed.path));
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

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && _pendingAttachments.isEmpty) return;
    final pending = List.of(_pendingAttachments);
    setState(() => _pendingAttachments.clear());
    _textController.clear();

    try {
      if (pending.isEmpty) {
        await widget.service.sendText(trimmed);
        return;
      }

      // Attachments were staged into <cwd>/uploads/ at pick time; the
      // outgoing message references the sandbox paths so the agent reads the
      // files with its tools (see AgentService.sendAttachments).
      await widget.service.sendAttachments(
        attachments: [
          for (final attachment in pending)
            (
              path: attachment.path,
              bytes: attachment.bytes,
              mimeType: attachment.mimeType,
            ),
        ],
        text: trimmed,
      );
    } on Object catch (e) {
      // The send itself failed before the run started: hand the chips and
      // the typed text back so nothing the user composed is lost.
      if (mounted) {
        setState(() => _pendingAttachments.addAll(pending));
        _textController.text = trimmed;
        _showSnack(context.l10n.chatSendError(e.toString()));
      }
    }
  }

  /// Picks arbitrary files and stages them as pending attachments (web
  /// only; elsewhere the picker is `null`). Staging happens immediately —
  /// the chips wait in the composer until the user sends (see [_send]).
  Future<void> _attachFiles() async {
    final picker = _uploadPicker;
    if (picker == null) return;
    final List<UploadFile> picked;
    try {
      picked = await picker.pick();
    } on Object catch (e) {
      if (mounted) _showSnack(context.l10n.chatUploadFailed(e.toString()));
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final sizeError = uploadBatchSizeError(
      picked,
      message: (total, max) => context.l10n.uploadTooLarge(max, total),
    );
    if (sizeError != null) {
      _showSnack(sizeError);
      return;
    }

    for (final file in picked) {
      await _stagePending(file.name, file.bytes);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(context.l10n.chatGallery),
              onTap: () {
                Navigator.of(context).pop();
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(context.l10n.chatCamera),
              onTap: () {
                Navigator.of(context).pop();
                _pickImage(ImageSource.camera);
              },
            ),
            if (_uploadPicker != null)
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: Text(context.l10n.chatAttachFile),
                onTap: () {
                  Navigator.of(context).pop();
                  _attachFiles();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextMessage(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    // Empty assistant bubbles (model returned no text) render as nothing —
    // they would otherwise show as a blank gray rectangle between tool calls.
    if (message.text.trim().isEmpty && !isSentByMe) {
      return const SizedBox.shrink();
    }
    final styleSheet = fahMarkdownStyleSheet(Theme.of(context));
    final palette = FahColors.of(context);

    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isSentByMe ? palette.userBubble : palette.panel,
        border: Border.all(
          color: isSentByMe ? palette.userBubbleBorder : palette.border,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: MarkdownBody(
        data: message.text,
        selectable: true,
        styleSheet: styleSheet,
        // Sandbox paths (`![alt](generated/x.png)`) load through the
        // session env; taps open the fullscreen preview.
        sizedImageBuilder: _images.sizedImageBuilder(
          onImageTap: (bytes) => showFahImagePreview(context, bytes),
        ),
        // Audio/video sandbox links open a small inline-player dialog.
        onTapLink: _onMarkdownLink,
      ),
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

  /// Extracts the saved sandbox path from a `generate_image` tool result
  /// (`Generated image saved to <path> (<n> bytes, …)`); null for errors
  /// or any other text.
  static final _generatedImagePathPattern = RegExp(
    r'Generated image saved to (\S+\.png)',
  );

  static String? _generatedImagePath(String content) =>
      _generatedImagePathPattern.firstMatch(content)?.group(1);

  /// Extracts the saved sandbox path from a `speak` / `generate_music`
  /// tool result (`Speech saved to <path> …` / `Music saved to <path> …`);
  /// null for errors or any other text.
  static String? _generatedAudioPath(String toolName, String content) {
    final prefix = switch (toolName) {
      speakToolName => 'Speech saved to ',
      generateMusicToolName => 'Music saved to ',
      _ => null,
    };
    if (prefix == null || !content.startsWith(prefix)) return null;
    return mediaPathInText(content, audioFileExtensions);
  }

  /// The sandbox media path a successful tool result should render an
  /// inline player for: explicit for `speak`/`generate_music`, otherwise
  /// any path-like token with a media extension (`.mp3/.wav/.m4a` → audio,
  /// `.mp4/.mov/.webm` → video). The `read` tool is NEVER sniffed — it
  /// legitimately prints file paths as text (same exclusion as images).
  static ({SandboxMediaKind kind, String path})? _toolMedia(
    String? toolName,
    String content,
    bool isError,
  ) {
    if (toolName == null || toolName == 'read' || isError) return null;
    final audioPath = _generatedAudioPath(toolName, content);
    if (audioPath != null) {
      return (kind: SandboxMediaKind.audio, path: audioPath);
    }
    final fallbackAudio = mediaPathInText(content, audioFileExtensions);
    if (fallbackAudio != null) {
      return (kind: SandboxMediaKind.audio, path: fallbackAudio);
    }
    final videoPath = mediaPathInText(content, videoFileExtensions);
    if (videoPath != null) {
      return (kind: SandboxMediaKind.video, path: videoPath);
    }
    return null;
  }

  /// `onTapLink` for chat Markdown: audio/video sandbox links open a small
  /// player dialog (flutter_markdown has no custom link renderer — only
  /// images render inline). Other links stay dead, as before.
  void _onMarkdownLink(String text, String? href, String title) {
    if (href == null) return;
    final kind = sandboxMediaKind(href);
    if (kind == null) return;
    showFahMediaDialog(
      context,
      bytes: _images.load(href),
      kind: kind,
      audioControllerFactory: widget.audioControllerFactory,
      videoControllerFactory: widget.videoControllerFactory,
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
    final toolName = metadata['toolName'] as String?;
    final content = (metadata['content'] as String?) ?? '';
    final isError = (metadata['isError'] as bool?) ?? false;
    final role = metadata['role'] as String?;
    final palette = FahColors.of(context);
    // generate_image results carry the saved sandbox path — show the image
    // inline under the tool tile instead of waiting for the model to
    // reference it. Errors ("Error: …") simply don't match.
    final generatedImagePath = toolName == generateImageToolName
        ? _generatedImagePath(content)
        : null;
    // speak/generate_music (and any non-read tool result mentioning a
    // media path) get an inline audio/video player under the tile.
    final toolMedia = _toolMedia(toolName, content, isError);

    if (role == 'thinking') {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.panelAlt.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.border.withValues(alpha: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.psychology_outlined, size: 14, color: palette.dim),
            const SizedBox(width: 6),
            Expanded(
              // Reasoning can run to thousands of lines (and small models
              // sometimes loop there) — collapse like long tool output, but
              // keep the NEWEST reasoning visible (the tail, not the head).
              child: _CollapsibleToolOutput(
                content: content,
                showTail: true,
                style: palette
                    .mono(color: palette.dim, fontSize: 12)
                    .copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError
              ? palette.error.withValues(alpha: 0.45)
              : palette.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (toolName != null) ...[
            Row(
              children: [
                Icon(
                  isError ? Icons.close : Icons.check,
                  size: 14,
                  color: isError ? palette.error : palette.teal,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '[ $toolName ]',
                    overflow: TextOverflow.ellipsis,
                    style: palette.mono(
                      color: isError ? palette.error : palette.indigo,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (content.isNotEmpty) const SizedBox(height: 6),
          ],
          if (content.isNotEmpty)
            toolName == null
                // System rows (e.g. tool-call echoes) read like shell input:
                // a teal `$` prompt followed by dim mono text.
                ? Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: r'$ ',
                          style: palette.mono(color: palette.teal),
                        ),
                        TextSpan(
                          text: content,
                          style: palette.mono(color: palette.dim),
                        ),
                      ],
                    ),
                  )
                : _CollapsibleToolOutput(
                    content: content,
                    style: palette.mono(color: palette.dim),
                  ),
          if (generatedImagePath != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: _images.image(
                  path: generatedImagePath,
                  onTap: (bytes) => showFahImagePreview(context, bytes),
                ),
              ),
            ),
          if (toolMedia != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: switch (toolMedia.kind) {
                  SandboxMediaKind.audio => SandboxAudioPlayer(
                    bytes: _images.load(toolMedia.path),
                    controllerFactory: widget.audioControllerFactory,
                  ),
                  SandboxMediaKind.video => SandboxVideoPlayer(
                    path: toolMedia.path,
                    bytes: _images.load(toolMedia.path),
                    controllerFactory: widget.videoControllerFactory,
                  ),
                },
              ),
            ),
        ],
      ),
    );
  }

  /// One pending attachment in the composer: a thumbnail for decodable
  /// raster images, an icon + name + size chip otherwise (SVG previews stay
  /// generic — see [isInlineImageMimeType]), each with a remove affordance.
  Widget _buildPendingAttachmentChip(int index) {
    final attachment = _pendingAttachments[index];
    final isImage = isInlineImageMimeType(attachment.mimeType);
    final palette = FahColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                attachment.bytes,
                height: 48,
                width: 48,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.broken_image_outlined, size: 24),
              ),
            )
          else ...[
            const Icon(Icons.insert_drive_file_outlined, size: 18),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                '${attachment.name.split('/').last} · '
                '${formatFileSize(attachment.bytes.length)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: context.l10n.chatRemoveAttachment,
            onPressed: () => _removePendingAttachment(index),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);
    final palette = FahColors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingAttachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _pendingAttachments.length; i++)
                        _buildPendingAttachmentChip(i),
                    ],
                  ),
                ),
              ),
            if (_isStreaming)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.chatTyping,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.dim,
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.service.pendingSteerTexts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final pending in widget.service.pendingSteerTexts)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: palette.userBubble.withValues(alpha: 0.6),
                          border: Border.all(color: palette.userBubbleBorder),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                pending,
                                style: theme.textTheme.bodyMedium,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.schedule, size: 16, color: palette.dim),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: context.l10n.chatAttachTooltip,
                    onPressed: _showAttachmentSheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: InputDecoration(
                        hintText: context.l10n.chatInputHint,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                      ),
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _send,
                    ),
                  ),
                  if (asrPlatformSupported) _buildMicButton(context),
                  const SizedBox(width: 4),
                  Container(
                    decoration: BoxDecoration(
                      gradient: palette.brandGradient,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(
                        _isStreaming ? Icons.stop : Icons.send,
                        size: 20,
                      ),
                      color: palette.onAccent,
                      tooltip: _isStreaming
                          ? context.l10n.chatAbortTooltip
                          : context.l10n.chatSendTooltip,
                      onPressed: _isStreaming
                          ? widget.service.abort
                          : () => _send(_textController.text),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The composer's voice-input button: idle shows a mic (tap to record),
  /// recording pulses red (tap again to stop + transcribe), transcribing
  /// shows a spinner. Rendered only where [asrPlatformSupported].
  Widget _buildMicButton(BuildContext context) {
    final l10n = context.l10n;
    if (_micTranscribing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_micRecording) {
      final error = Theme.of(context).colorScheme.error;
      return AnimatedBuilder(
        animation: _micPulse,
        builder: (context, child) => IconButton(
          icon: Icon(
            Icons.mic,
            color: Color.lerp(
              error,
              error.withValues(alpha: 0.35),
              _micPulse.value,
            ),
          ),
          tooltip: l10n.chatMicStopTooltip,
          onPressed: _toggleMic,
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.mic_none),
      tooltip: l10n.chatMicTooltip,
      onPressed: _toggleMic,
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
        _buildComposer(context),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _kWideLayoutBreakpoint;
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

/// Tool-output block that caps long dumps (file reads, big writes) at a few
/// lines with an expand/collapse toggle — keeps the transcript scannable
/// while the full output stays one tap away.
class _CollapsibleToolOutput extends StatefulWidget {
  const _CollapsibleToolOutput({
    required this.content,
    required this.style,
    this.showTail = false,
  });

  final String content;
  final TextStyle style;

  /// Collapse to the LAST lines instead of the first — used for thinking
  /// bubbles, where the newest reasoning matters more than the preamble.
  final bool showTail;

  /// Outputs longer than this collapse by default.
  static const int collapsedLineCount = 8;
  static const int longLineThreshold = 12;
  static const int longCharThreshold = 700;

  @override
  State<_CollapsibleToolOutput> createState() => _CollapsibleToolOutputState();
}

class _CollapsibleToolOutputState extends State<_CollapsibleToolOutput> {
  bool _expanded = false;

  bool get _isLong {
    final lines = widget.content.split('\n');
    return lines.length > _CollapsibleToolOutput.longLineThreshold ||
        widget.content.length > _CollapsibleToolOutput.longCharThreshold;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLong) {
      return Text(widget.content, style: widget.style);
    }
    final palette = FahColors.of(context);
    final lines = widget.content.split('\n');
    final shown = _expanded
        ? lines
        : widget.showTail
        ? lines
              .skip(
                lines.length > _CollapsibleToolOutput.collapsedLineCount
                    ? lines.length - _CollapsibleToolOutput.collapsedLineCount
                    : 0,
              )
              .toList()
        : lines.take(_CollapsibleToolOutput.collapsedLineCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(shown.join('\n'), style: widget.style),
        const SizedBox(height: 4),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 14,
                color: palette.indigo,
              ),
              const SizedBox(width: 4),
              Text(
                _expanded
                    ? context.l10n.chatCollapse
                    : context.l10n.chatShowAll(lines.length.toString()),
                style: palette.mono(color: palette.indigo, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
