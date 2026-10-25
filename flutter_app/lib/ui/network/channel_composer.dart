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
/// adds roster-backed `@displayName` completion above the input. Completion
/// changes only the draft: [ChannelChatService] resolves the literal names to
/// envelope mention ids at send time.
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
  int? _selectedMentionCaret;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Iterable<Member> _mentionOptions(TextEditingValue value) {
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

  bool get _hasMentionOptions =>
      _focusNode.hasFocus && _mentionOptions(_controller.value).isNotEmpty;

  /// RawAutocomplete replaces the whole field with this value immediately
  /// before calling `onSelected`. Return the full draft with only the active
  /// token replaced, then restore the caret in [_selectMention].
  String _displayMention(Member member) {
    final token = _MentionToken.atSelection(_controller.value);
    if (token == null) return member.displayName;
    final inserted = '@${member.displayName} ';
    _selectedMentionCaret = token.start + inserted.length;
    return _controller.text.replaceRange(token.start, token.end, inserted);
  }

  void _selectMention(Member member) {
    final caret = _selectedMentionCaret;
    if (caret != null && caret <= _controller.text.length) {
      _controller.selection = TextSelection.collapsed(offset: caret);
    }
    _selectedMentionCaret = null;
    _focusNode.requestFocus();
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter ||
        (keyboard.isShiftPressed &&
            !keyboard.isMetaPressed &&
            !keyboard.isControlPressed)) {
      return KeyEventResult.ignored;
    }
    // RawAutocomplete owns Enter while its menu is visible (highlight
    // navigation and selection). Otherwise Enter sends; Shift+Enter remains
    // a newline, matching the shared composer.
    if (_hasMentionOptions) return KeyEventResult.ignored;
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
          child: Row(
            children: [
              Expanded(
                child: RawAutocomplete<Member>(
                  textEditingController: _controller,
                  focusNode: _focusNode,
                  optionsViewOpenDirection: OptionsViewOpenDirection.up,
                  optionsBuilder: _mentionOptions,
                  displayStringForOption: _displayMention,
                  onSelected: _selectMention,
                  fieldViewBuilder:
                      (context, controller, focusNode, onFieldSubmitted) {
                        return Focus(
                          onKeyEvent: _handleComposerKey,
                          child: TextField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              hintText: strings.chatInputHint,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(24),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(24),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(24),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                            ),
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            maxLines: 6,
                            minLines: 1,
                          ),
                        );
                      },
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.bottomLeft,
                      child: Material(
                        elevation: 8,
                        color: palette.panelAlt,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 240),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: options.length,
                            itemBuilder: (context, index) {
                              final member = options.elementAt(index);
                              final highlighted =
                                  AutocompleteHighlightedOption.of(context) ==
                                  index;
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
                                  onTap: () => onSelected(member),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
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
