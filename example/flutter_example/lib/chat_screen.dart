import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'agent_service.dart';

/// A chat UI backed by [AgentService], built on top of `flutter_chat_ui`.
///
/// Text messages are rendered as Markdown, tool calls/results are shown as
/// distinct cards, and image attachments are supported.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service});

  final AgentService service;

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

  @override
  void initState() {
    super.initState();
    _chatController = InMemoryChatController();
    widget.service.addListener(_onServiceChanged);
    _syncMessages();
  }

  @override
  void dispose() {
    _textController.dispose();
    widget.service.removeListener(_onServiceChanged);
    _chatController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    _syncMessages();
  }

  Future<void> _syncMessages() async {
    final converted = await Future.wait(
      widget.service.messages.indexed.map(
        (entry) => _toMessage(entry.$1, entry.$2),
      ),
    );
    await _chatController.setMessages(converted.toList());
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
    return MarkdownBody(
      data: message.text,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(
        Theme.of(context),
      ).copyWith(p: Theme.of(context).textTheme.bodyMedium),
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

    final theme = Theme.of(context);
    final color = isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (toolName != null)
            Text(
              '[ $toolName ]',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: isError ? theme.colorScheme.error : null,
              ),
            ),
          if (toolName != null && content.isNotEmpty) const SizedBox(height: 4),
          if (content.isNotEmpty)
            Text(
              content,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Courier', 'monospace'],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.2)),
        ),
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
            if (widget.service.isStreaming)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('fah is typing...'),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add),
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
                        filled: true,
                      ),
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _send,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () => _send(_textController.text),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('fah'),
        actions: [
          if (widget.service.isStreaming)
            IconButton(
              icon: const Icon(Icons.stop),
              tooltip: 'Abort',
              onPressed: widget.service.abort,
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'New session',
            onPressed: widget.service.reset,
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.service.error case final error?)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      Icons.error,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(error)),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Chat(
              currentUserId: 'user',
              resolveUser: _resolveUser,
              chatController: _chatController,
              onMessageSend: _send,
              onAttachmentTap: _showAttachmentSheet,
              builders: Builders(
                textMessageBuilder: _buildTextMessage,
                customMessageBuilder: _buildCustomMessage,
                composerBuilder: _buildComposer,
              ),
              theme: ChatTheme.light(),
            ),
          ),
        ],
      ),
    );
  }
}
