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

import 'agent_service.dart';
import 'app_theme.dart';
import 'approval_ui.dart';
import 'ask_ui.dart';
import 'file_browser.dart';
import 'file_preview.dart';
import 'flutter_session_manager.dart';
import 'last_connection.dart';
import 'markdown_style.dart';
import 'provider_registry.dart';
import 'session_sidebar.dart';
import 'settings.dart';
import 'upload.dart';
import 'upload_picker_stub.dart'
    if (dart.library.html) 'upload_picker_web.dart';

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

class _ChatScreenState extends State<ChatScreen> {
  late final InMemoryChatController _chatController;
  final _textController = TextEditingController();

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
    _chatController = InMemoryChatController();
    widget.manager.addListener(_onManagerChanged);
    _subscribeToService();
    _isStreaming = widget.service.isStreaming;
    _error = widget.service.error;
    _syncMessages();
  }

  void _subscribeToService() {
    widget.service.addListener(_onServiceChanged);
    // This screen renders approval prompts as Material dialogs; clearing the
    // handler on dispose restores the deny-by-default for headless runs.
    widget.service.approvalPromptHandler = _handleApprovalPrompt;
    // Same pattern for the ask tool: this screen renders the questions as a
    // modal bottom sheet; without a handler, ask calls resolve as cancelled.
    widget.service.askHandler = _handleAskQuestions;
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
    _textController.dispose();
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
      _showSnack('Could not attach "$name": no usable file name.');
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
      if (mounted) _showSnack('Could not attach $clean: $e');
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
        const SnackBar(
          content: Text('Session copied to clipboard'),
          duration: Duration(seconds: 2),
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
        _showSnack('Could not send: $e');
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
      if (mounted) _showSnack('Upload failed: $e');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final sizeError = uploadBatchSizeError(picked);
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
              title: const Text('Gallery'),
              onTap: () {
                Navigator.of(context).pop();
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () {
                Navigator.of(context).pop();
                _pickImage(ImageSource.camera);
              },
            ),
            if (_uploadPicker != null)
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('Attach file'),
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

    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isSentByMe ? FahPalette.userBubble : FahPalette.panel,
        border: Border.all(
          color: isSentByMe ? FahPalette.userBubbleBorder : FahPalette.border,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: MarkdownBody(
        data: message.text,
        selectable: true,
        styleSheet: styleSheet,
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
    final toolName = metadata['toolName'] as String?;
    final content = (metadata['content'] as String?) ?? '';
    final isError = (metadata['isError'] as bool?) ?? false;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: FahPalette.panelAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError
              ? FahPalette.error.withValues(alpha: 0.45)
              : FahPalette.border,
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
                  color: isError ? FahPalette.error : FahPalette.teal,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '[ $toolName ]',
                    overflow: TextOverflow.ellipsis,
                    style: FahPalette.mono(
                      color: isError ? FahPalette.error : FahPalette.indigo,
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
                          style: FahPalette.mono(color: FahPalette.teal),
                        ),
                        TextSpan(
                          text: content,
                          style: FahPalette.mono(color: FahPalette.dim),
                        ),
                      ],
                    ),
                  )
                : Text(content, style: FahPalette.mono(color: FahPalette.dim)),
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
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: FahPalette.panel,
        border: Border.all(color: FahPalette.border),
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
            tooltip: 'Remove attachment',
            onPressed: () => _removePendingAttachment(index),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: FahPalette.bg,
        border: Border(top: BorderSide(color: FahPalette.border)),
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
                      'fah is typing...',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: FahPalette.dim,
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
                          color: FahPalette.userBubble.withValues(alpha: 0.6),
                          border: Border.all(
                            color: FahPalette.userBubbleBorder,
                          ),
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
                            Icon(
                              Icons.schedule,
                              size: 16,
                              color: FahPalette.dim,
                            ),
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
                    tooltip: 'Attach',
                    onPressed: _showAttachmentSheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: const InputDecoration(
                        hintText: 'Type a message',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
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
                  const SizedBox(width: 4),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: FahPalette.brandGradient,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send, size: 20),
                      color: FahPalette.onAccent,
                      tooltip: 'Send',
                      onPressed: () => _send(_textController.text),
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
              composerBuilder: (_) => const SizedBox.shrink(),
            ),
            theme: buildFahChatTheme(),
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
            tooltip: 'Sessions & model',
            onPressed: () => _openSidebar(context),
          ),
        ),
        title: const Text('Fa'),
        actions: [
          if (_isStreaming)
            IconButton(
              icon: const Icon(Icons.stop),
              tooltip: 'Abort',
              onPressed: widget.service.abort,
            ),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.folder_outlined),
              tooltip: 'Files',
              onPressed: () => _openFiles(context),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy session',
            onPressed: _copySession,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Connection settings',
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
              ),
            ),
          ],
        ],
      ),
    );
  }
}
