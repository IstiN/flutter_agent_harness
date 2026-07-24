// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import '../agent_service.dart';
import '../app_theme.dart';
import '../fa_mark.dart';

/// Compact "Fa is working" bar shown at the bottom of a JS app view while
/// the agent runs: the sparkling Fa mark, a live status line (current tool
/// call / thinking / writing), a stop button, an expand-to-chat button and
/// an inline follow-up input — so the user keeps steering without leaving
/// the app.
class FaWorkBar extends StatefulWidget {
  const FaWorkBar({
    super.key,
    required this.service,
    this.onSend,
    this.onExpand,
  });

  final AgentService service;

  /// Sends a follow-up message to the agent (text; the caller attaches the
  /// app state + screenshot when useful).
  final Future<void> Function(String text)? onSend;

  /// Opens the full chat (typically pops the app view).
  final VoidCallback? onExpand;

  @override
  State<FaWorkBar> createState() => _FaWorkBarState();
}

class _FaWorkBarState extends State<FaWorkBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  final _inputController = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _inputController.dispose();
    super.dispose();
  }

  String _statusText() {
    for (final message in widget.service.messages.reversed) {
      switch (message.role) {
        case 'system':
          return message.content.split('\n').first;
        case 'tool':
          return '[${message.toolName}] ✓';
        case 'thinking':
          return 'thinking…';
        case 'assistant':
          return 'writing…';
      }
    }
    return 'Fa is working…';
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final onSend = widget.onSend;
    if (text.isEmpty || onSend == null || _sending) return;
    setState(() => _sending = true);
    try {
      _inputController.clear();
      await onSend(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        if (!widget.service.isStreaming) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: FahPalette.panelAlt.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: FahPalette.indigo.withValues(alpha: 0.4)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ScaleTransition(
                    scale: Tween(begin: 0.85, end: 1.15).animate(
                      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                    ),
                    child: const FaMark(size: 18),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FahPalette.mono(
                        color: FahPalette.dim,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.open_in_full, size: 16),
                    tooltip: 'Open chat',
                    visualDensity: VisualDensity.compact,
                    color: FahPalette.dim,
                    onPressed: widget.onExpand,
                  ),
                  IconButton(
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    tooltip: 'Stop',
                    visualDensity: VisualDensity.compact,
                    color: FahPalette.error,
                    onPressed: widget.service.abort,
                  ),
                ],
              ),
              if (widget.onSend != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Follow up…',
                          hintStyle: const TextStyle(
                            color: FahPalette.dim,
                            fontSize: 13,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.black26,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                        ),
                        onSubmitted: (_) => unawaited(_send()),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: const Icon(Icons.send, size: 16),
                      tooltip: 'Send',
                      visualDensity: VisualDensity.compact,
                      color: FahPalette.indigo,
                      onPressed: _sending ? null : () => unawaited(_send()),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
