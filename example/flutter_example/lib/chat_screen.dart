import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'agent_service.dart';
import 'app_theme.dart';
import 'file_browser.dart';
import 'session_sidebar.dart';
import 'settings.dart';
import 'upload.dart';
import 'upload_picker_stub.dart'
    if (dart.library.html) 'upload_picker_web.dart';

/// Minimum body width (logical px) at which the side panels (sessions/model
/// on the left, files on the right) become persistent, collapsible panels
/// instead of drawers.
const double _kWideLayoutBreakpoint = 900;

/// A chat UI backed by [AgentService], built on top of `flutter_chat_ui`.
///
/// Text messages are rendered as Markdown, tool calls/results are shown as
/// distinct cards, and image attachments are supported.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service, this.uploadPicker});

  final AgentService service;

  /// File chooser behind the attach sheet's "Upload to files" entry.
  /// Defaults to the platform picker (`null` off the web → the entry is
  /// hidden); tests inject a fake.
  final UploadPicker? uploadPicker;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final InMemoryChatController _chatController;
  final _textController = TextEditingController();

  final _user = const User(id: 'user', name: 'Me');
  final _assistant = const User(id: 'assistant', name: 'fah');
  final _tool = const User(id: 'tool', name: 'tool');
  final _system = const User(id: 'system', name: 'system');

  Uint8List? _pendingImage;
  String? _pendingImageMime;

  List<Message> _lastSynced = [];
  Timer? _syncDebounce;
  bool _isSyncing = false;
  bool _isStreaming = false;
  String? _error;

  /// Whether the left session/model sidebar is expanded (wide layouts only).
  bool _leftPanelOpen = true;

  /// Whether the file browser side panel is expanded (wide layouts only).
  bool _filesPanelOpen = false;

  /// Arbitrary-file picker for the attach sheet's "Upload to files" entry;
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
    _isStreaming = widget.service.isStreaming;
    _error = widget.service.error;
    widget.service.addListener(_onServiceChanged);
    _syncMessages();
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _textController.dispose();
    widget.service.removeListener(_onServiceChanged);
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
          final path = await _writeImageFile(index, chat.imageBytes!);
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

  Future<String> _writeImageFile(int index, Uint8List bytes) async {
    final tmp = await getTemporaryDirectory();
    final file = File('${tmp.path}/fah_chat_image_$index.png');
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      await file.writeAsBytes(bytes);
    }
    return file.path;
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
    final mime = _mimeFromName(picked.name);
    setState(() {
      _pendingImage = bytes;
      _pendingImageMime = mime;
    });
  }

  String _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  void _clearPendingImage() {
    setState(() {
      _pendingImage = null;
      _pendingImageMime = null;
    });
  }

  /// Copies the whole session transcript to the clipboard as plain text.
  Future<void> _copySession() async {
    final buffer = StringBuffer();
    for (final m in widget.service.messages) {
      final header = switch (m.role) {
        'user' => '## You',
        'assistant' => '## fah',
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
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(service: widget.service),
    );
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && _pendingImage == null) return;
    final image = _pendingImage;
    final mime = _pendingImageMime;
    _clearPendingImage();
    _textController.clear();

    if (image != null) {
      await widget.service.sendImage(
        bytes: image,
        mimeType: mime ?? 'image/jpeg',
        text: trimmed,
      );
    } else {
      await widget.service.sendText(trimmed);
    }
  }

  /// Picks arbitrary files and writes them into the sandbox root, so the
  /// agent can work with them (web only; elsewhere the picker is `null`).
  Future<void> _uploadToSandbox() async {
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

    var written = 0;
    var failed = 0;
    for (final file in picked) {
      final name = sanitizeUploadName(file.name);
      if (name.isEmpty) {
        failed++;
        continue;
      }
      final result = await widget.service.env.writeBinaryFile(name, file.bytes);
      if (result.isOk) {
        written++;
      } else {
        failed++;
      }
    }
    if (!mounted) return;
    _showSnack(
      'Uploaded $written file${written == 1 ? '' : 's'} to the sandbox'
      '${failed > 0 ? ', $failed failed' : ''}',
    );
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
                title: const Text('Upload to files'),
                onTap: () {
                  Navigator.of(context).pop();
                  _uploadToSandbox();
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
    final theme = Theme.of(context);
    final styleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium,
      a: const TextStyle(color: FahPalette.teal),
      code: FahPalette.mono().copyWith(backgroundColor: FahPalette.codeBg),
      codeblockDecoration: BoxDecoration(
        color: FahPalette.panelAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: FahPalette.border),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: FahPalette.indigo, width: 3)),
      ),
    );

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
            if (_pendingImage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _pendingImage!,
                        height: 64,
                        width: 64,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _clearPendingImage,
                    ),
                  ],
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
        title: const Text('fah'),
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
                    service: widget.service,
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
                ),
              ),
            ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isWide && _leftPanelOpen) ...[
            SizedBox(
              width: kSessionSidebarWidth,
              child: SessionSidebar(service: widget.service),
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(child: _buildChatBody(context)),
          if (isWide && _filesPanelOpen) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: kFileBrowserPanelWidth,
              child: FileBrowser(env: widget.service.env),
            ),
          ],
        ],
      ),
    );
  }
}
