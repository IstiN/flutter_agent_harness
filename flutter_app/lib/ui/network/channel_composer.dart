// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/models.dart';

/// The channel-only text composer. It keeps the shared composer's chrome and
/// adds roster-backed `@displayName` completion in a panel directly above the
/// input (no overlay, so it cannot render off-screen or lose key events).
/// Completion changes only the draft: [ChannelChatService] resolves the
/// literal names to envelope mention ids at send time.
class ChannelChatComposer extends StatefulWidget {
  const ChannelChatComposer({super.key, required this.service});

  final ChannelChatService service;

  @override
  State<ChannelChatComposer> createState() => _ChannelChatComposerState();
}

class _ChannelChatComposerState extends State<ChannelChatComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _sending = false;
  List<Member> _options = const [];
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refreshMentionMenu);
    _focusNode.addListener(_refreshMentionMenu);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_refreshMentionMenu);
    _focusNode.removeListener(_refreshMentionMenu);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _menuOpen => _options.isNotEmpty && _focusNode.hasFocus;

  Iterable<Member> _matchingMembers(TextEditingValue value) {
    final token = _MentionToken.atSelection(value);
    if (token == null) return const [];
    final query = token.query.toLowerCase();
    final matches = widget.service.session.roster.values
        .where(
          (member) =>
              member.displayName.isNotEmpty &&
              member.displayName.toLowerCase().startsWith(query),
        )
        .toList();
    matches.sort((a, b) {
      final byPresence = _presenceRank(
        a.presence,
      ).compareTo(_presenceRank(b.presence));
      if (byPresence != 0) return byPresence;
      final byName = a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      );
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return matches;
  }

  static int _presenceRank(Presence presence) => switch (presence) {
    Presence.live => 0,
    Presence.busy => 1,
    _ => 2,
  };

  void _refreshMentionMenu() {
    if (!mounted) return;
    final next = _focusNode.hasFocus
        ? _matchingMembers(_controller.value).toList()
        : const <Member>[];
    final previous = _highlight < _options.length ? _options[_highlight] : null;
    var highlight = 0;
    if (previous != null) {
      final kept = next.indexWhere((m) => m.id == previous.id);
      if (kept >= 0) highlight = kept;
    }
    if (next.length == _options.length &&
        highlight == _highlight &&
        _listEquals(next, _options)) {
      return;
    }
    setState(() {
      _options = next;
      _highlight = next.isEmpty ? 0 : highlight;
    });
  }

  static bool _listEquals(List<Member> a, List<Member> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _moveHighlight(int delta) {
    if (_options.isEmpty) return;
    setState(() {
      _highlight = (_highlight + delta) % _options.length;
      if (_highlight < 0) _highlight += _options.length;
    });
  }

  void _insertMention(Member member) {
    final value = _controller.value;
    final token = _MentionToken.atSelection(value);
    if (token == null) return;
    final inserted = '@${member.displayName} ';
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(token.start, token.end, inserted),
      selection: TextSelection.collapsed(offset: token.start + inserted.length),
    );
    setState(() {
      _options = const [];
      _highlight = 0;
    });
    _focusNode.requestFocus();
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (_menuOpen) {
      final menuResult = _handleMentionMenuKey(key, isEnter, keyboard);
      if (menuResult != null) return menuResult;
    }
    if (event is! KeyDownEvent || !isEnter) return KeyEventResult.ignored;
    return _handleEnterKey(keyboard);
  }

  /// Handles a key pressed while the mention menu is open: arrow keys
  /// move the highlight, Escape dismisses the menu, and Tab or Enter
  /// accept the highlighted option instead of moving focus or sending
  /// the half-typed mention. Returns null when the key should fall
  /// through to normal text editing.
  KeyEventResult? _handleMentionMenuKey(
    LogicalKeyboardKey key,
    bool isEnter,
    HardwareKeyboard keyboard,
  ) {
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _options = const [];
        _highlight = 0;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab ||
        (isEnter && !keyboard.isShiftPressed)) {
      _insertMention(_options[_highlight]);
      return KeyEventResult.handled;
    }
    return null;
  }

  /// Decides what a bare Enter press does: Shift+Enter (and modified
  /// Enters) stay a newline, matching the shared composer; a plain
  /// Enter sends the current draft.
  KeyEventResult _handleEnterKey(HardwareKeyboard keyboard) {
    if (keyboard.isShiftPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed) {
      return KeyEventResult.ignored;
    }
    unawaited(_send());
    return KeyEventResult.handled;
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    _controller.clear();
    try {
      await widget.service.sendText(text);
    } on Object catch (error) {
      if (mounted) {
        _controller.text = text;
        showFahErrorSnack(
          context,
          FaChatStrings.of(context).chatSendError(error.toString()),
          duration: const Duration(seconds: 3),
          hideCurrent: true,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = fahChatColorsOf(context);
    final strings = FaChatStrings.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_menuOpen)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  constraints: const BoxConstraints(maxHeight: 240),
                  decoration: BoxDecoration(
                    color: palette.panelAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _options.length,
                    itemBuilder: (context, index) {
                      final member = _options[index];
                      final highlighted = index == _highlight;
                      return Material(
                        color: highlighted
                            ? palette.indigo.withValues(alpha: 0.12)
                            : Colors.transparent,
                        child: ListTile(
                          key: ValueKey('mentionOption:${member.id}'),
                          dense: true,
                          leading: Icon(
                            member.memberClass == MemberClass.agent
                                ? Icons.smart_toy_outlined
                                : Icons.person_outline,
                            size: 20,
                            color: palette.dim,
                          ),
                          title: Text(
                            member.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: member.presence == Presence.live
                                  ? palette.teal
                                  : palette.dim,
                              shape: BoxShape.circle,
                            ),
                          ),
                          onTap: () => _insertMention(member),
                        ),
                      );
                    },
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: _handleComposerKey,
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        decoration: InputDecoration(
                          hintText: strings.chatInputHint,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
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
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        maxLines: 6,
                        minLines: 1,
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.light
                          ? palette.indigo
                          : null,
                      gradient: Theme.of(context).brightness == Brightness.dark
                          ? palette.brandGradient
                          : null,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_upward, size: 20),
                      color: palette.onAccent,
                      tooltip: strings.chatSendTooltip,
                      onPressed: _sending ? null : () => unawaited(_send()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The unfinished `@prefix` immediately before a collapsed caret.
final class _MentionToken {
  const _MentionToken({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;

  static _MentionToken? atSelection(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final caret = selection.extentOffset;
    if (caret <= 0 || caret > value.text.length) return null;
    final beforeCaret = value.text.substring(0, caret);
    final start = beforeCaret.lastIndexOf('@');
    if (start < 0) return null;
    if (start > 0) {
      final previous = value.text.substring(start - 1, start);
      if (previous.trim().isNotEmpty && !'([{<'.contains(previous)) {
        return null;
      }
    }
    final query = value.text.substring(start + 1, caret);
    if (query.trim().length != query.length || query.contains(RegExp(r'\s'))) {
      return null;
    }
    return _MentionToken(start: start, end: caret, query: query);
  }
}
