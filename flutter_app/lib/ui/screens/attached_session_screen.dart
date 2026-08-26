import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../../l10n/l10n_ext.dart';
import '../../services/analytics.dart';
import '../../services/attached_session_controller.dart';
import 'package:fa_ui/fa_ui.dart';

/// A read-only live view of a session owned by a running `fa` CLI: the
/// transcript follows the session JSONL 1:1, and composer input is handed
/// to the CLI process through the attach transport (it lands there as the
/// user's own words and the answer streams back into this view).
///
/// The transport is injected (the interface trio from the core) — the
/// file impl today, a network impl for remote attach later.
class AttachedSessionScreen extends StatefulWidget {
  const AttachedSessionScreen({super.key, required this.controller});

  final AttachedSessionController controller;

  @override
  State<AttachedSessionScreen> createState() => _AttachedSessionScreenState();
}

class _AttachedSessionScreenState extends State<AttachedSessionScreen> {
  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.screenOpened('attached_session');
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final colors = FahColors.of(context);
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Colors.green.shade400,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.green.shade400.withValues(alpha: 0.6),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                controller.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.attachedToCli,
              style: TextStyle(color: colors.dim, fontSize: 12),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                if (controller.rows.isEmpty) {
                  return Center(
                    child: Text(
                      l10n.attachedEmpty,
                      style: TextStyle(color: colors.dim, fontSize: 13),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: controller.rows.length,
                  itemBuilder: (context, index) =>
                      _AttachedRow(row: controller.rows[index]),
                );
              },
            ),
          ),
          _AttachedComposer(controller: controller),
        ],
      ),
    );
  }
}

class _AttachedRow extends StatelessWidget {
  const _AttachedRow({required this.row});

  final AttachedMessage row;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final isUser = row.role == AttachedMessageRole.user;
    final isAssistant = row.role == AttachedMessageRole.assistant;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: isUser ? colors.panelAlt : colors.panel,
          borderRadius: BorderRadius.circular(12),
        ),
        child: isUser || isAssistant
            ? Text(
                row.text,
                style: TextStyle(color: colors.text, fontSize: 13, height: 1.4),
              )
            : Text(
                '[ ${row.toolName ?? 'tool'} ]',
                style: TextStyle(
                  color: colors.teal,
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
      ),
    );
  }
}

class _AttachedComposer extends StatefulWidget {
  const _AttachedComposer({required this.controller});

  final AttachedSessionController controller;

  @override
  State<_AttachedComposer> createState() => _AttachedComposerState();
}

class _AttachedComposerState extends State<_AttachedComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    await widget.controller.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: !widget.controller.sending,
                onSubmitted: (_) => unawaited(_send()),
                style: TextStyle(color: colors.text, fontSize: 13),
                decoration: InputDecoration(
                  hintText: l10n.sendToCli,
                  hintStyle: TextStyle(color: colors.dim, fontSize: 13),
                  filled: true,
                  fillColor: colors.panel,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: widget.controller.sending
                  ? null
                  : () => unawaited(_send()),
              icon: const Icon(Icons.send_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
