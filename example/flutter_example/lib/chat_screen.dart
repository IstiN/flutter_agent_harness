import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'agent_service.dart';

/// A simple mobile chat UI backed by [AgentService].
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service});

  final AgentService service;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  Uint8List? _pendingImage;
  String? _pendingImageMime;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    setState(() {});
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
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

  void _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _pendingImage == null) return;
    _controller.clear();
    final image = _pendingImage;
    final mime = _pendingImageMime;
    _clearPendingImage();
    if (image != null) {
      await widget.service.sendImage(
        bytes: image,
        mimeType: mime ?? 'image/jpeg',
        text: text,
      );
    } else {
      await widget.service.sendText(text);
    }
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
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: widget.service.messages.length,
              itemBuilder: (context, index) {
                return _MessageBubble(message: widget.service.messages[index]);
              },
            ),
          ),
          if (_pendingImage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
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
          _InputBar(
            controller: _controller,
            focusNode: _focusNode,
            isStreaming: widget.service.isStreaming,
            onSend: _send,
            onPickImage: _pickImage,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    final isAssistant = message.role == 'assistant';
    final isTool = message.role == 'tool';
    Color? bubbleColor;
    if (isUser) bubbleColor = theme.colorScheme.primaryContainer;
    if (isAssistant) bubbleColor = theme.colorScheme.secondaryContainer;
    if (isTool) bubbleColor = theme.colorScheme.surfaceContainerHighest;
    if (message.isError) bubbleColor = theme.colorScheme.errorContainer;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.toolName != null)
          Text(
            '[${message.toolName}]',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        if (message.content.isNotEmpty) SelectableText(message.content),
        if (message.imageBytes != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(message.imageBytes!, fit: BoxFit.cover),
            ),
          ),
      ],
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        child: Card(
          color: bubbleColor,
          child: Padding(padding: const EdgeInsets.all(12), child: content),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.isStreaming,
    required this.onSend,
    required this.onPickImage,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isStreaming;
  final VoidCallback onSend;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.image),
              tooltip: 'Attach image',
              onPressed: isStreaming ? null : onPickImage,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: const InputDecoration.collapsed(
                  hintText: 'Message fah...',
                ),
                enabled: !isStreaming,
                onSubmitted: (_) => onSend(),
                minLines: 1,
                maxLines: 6,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              tooltip: 'Send',
              onPressed: isStreaming ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}
