/// The interactive prompt zone rendered in place of the REPL input while
/// the agent needs a decision from the user — mirrors the Flutter chat's
/// ask / approval / secret-request sheets (bordered frame with the
/// question, an input field or option list, and the same Recommended/
/// y/n/a affordances the sheets expose) so an interactive terminal run
/// behaves like the GUI when a tool call requires input.
///
/// Lives in pure Dart: no `dart:io`, no `dart_tui`. [PromptKey] is the
/// transport-neutral input type so the renderer and the key handler are
/// unit-testable without a real terminal, and the same code path serves the
/// dart_tui REPL (`fa_tui.dart` converts `KeyMsg` → [PromptKey]) and any
/// future TUI host.
library;

import '../approval/approval.dart';
import '../tools/ask_tool.dart';
import '../tools/request_secret_tool.dart';

/// A transport-neutral key event — dart_tui's `KeyMsg` carries the same
/// info but depends on `dart_tui`, so we re-shape it here and convert at
/// the boundary.
sealed class PromptKey {
  const PromptKey();
}

final class PromptEnter extends PromptKey {
  const PromptEnter();
}

final class PromptEscape extends PromptKey {
  const PromptEscape();
}

final class PromptTab extends PromptKey {
  const PromptTab();
}

/// Ctrl+R — the secret-sheet reveal toggle (show/hide the typed value).
final class PromptCtrlR extends PromptKey {
  const PromptCtrlR();
}

final class PromptArrowUp extends PromptKey {
  const PromptArrowUp();
}

final class PromptArrowDown extends PromptKey {
  const PromptArrowDown();
}

final class PromptArrowLeft extends PromptKey {
  const PromptArrowLeft();
}

final class PromptArrowRight extends PromptKey {
  const PromptArrowRight();
}

final class PromptBackspace extends PromptKey {
  const PromptBackspace();
}

final class PromptChar extends PromptKey {
  const PromptChar(this.text);
  final String text;
}

/// A clipboard paste (bracketed paste): inserted at the cursor like typing,
/// but as one unit (newlines allowed — the buffer keeps them until Enter
/// resolves the answer).
final class PromptPaste extends PromptKey {
  const PromptPaste(this.text);
  final String text;
}

/// The spec the host pushes into the TUI to ask the user for one decision.
/// Sealed so the renderer can switch on it cleanly.
sealed class TuiPromptSpec {
  const TuiPromptSpec({required this.header});

  /// The short label above the frame (`Ask`, `Approval`, `Secret`).
  final String header;
}

final class AskPromptSpec extends TuiPromptSpec {
  const AskPromptSpec({
    required super.header,
    required this.question,
    required this.index,
    required this.total,
    this.options = const [],
    this.multiSelect = false,
    this.recommended,
  });

  final String question;
  final int index;
  final int total;
  final List<AskOption> options;
  final bool multiSelect;
  final int? recommended;
}

final class SecretPromptSpec extends TuiPromptSpec {
  const SecretPromptSpec({
    required this.name,
    required this.reason,
    super.header = 'Secret',
  });

  final String name;
  final String reason;
}

final class ApprovalPromptSpec extends TuiPromptSpec {
  const ApprovalPromptSpec({required this.request, super.header = 'Approval'});

  final ApprovalRequest request;
}

/// A standalone free-text question (used by the provider wizard's `askLine`
/// step): the user types a line of text, optionally with a visible default
/// hint. When [secret] is true the typed characters are masked with dots.
final class TextPromptSpec extends TuiPromptSpec {
  const TextPromptSpec({
    required this.question,
    this.defaultValue,
    this.secret = false,
    super.header = 'Input',
  });

  final String question;
  final String? defaultValue;
  final bool secret; // mask input with dots
}

/// The answer to a [TuiPromptSpec], tagged so the host can downcast without
/// re-matching the spec.
sealed class TuiPromptAnswer {
  const TuiPromptAnswer();
}

final class TuiPromptCancelled extends TuiPromptAnswer {
  const TuiPromptCancelled();
}

final class AskPromptAnswer extends TuiPromptAnswer {
  const AskPromptAnswer(this.value);
  final AskAnswer value;
}

final class SecretPromptAnswer extends TuiPromptAnswer {
  const SecretPromptAnswer(this.value);
  final RequestSecretResult value;
}

final class ApprovalPromptAnswer extends TuiPromptAnswer {
  const ApprovalPromptAnswer(this.value, {this.note = ''});
  final ApprovalDecision value;

  /// Text the user typed before answering (chars that are not y/a/n).
  /// Delivered to the agent as feedback alongside the decision; empty when
  /// the user only pressed an answer key.
  final String note;
}

/// The typed line from a [TextPromptSpec].
final class TextPromptAnswer extends TuiPromptAnswer {
  const TextPromptAnswer(this.value);
  final String value;
}

/// The live state for one [TuiPromptSpec].
final class TuiPromptState {
  TuiPromptState(this.spec)
    : askSelected = <int>{},
      askCursor = 0,
      askMode = switch (spec) {
        AskPromptSpec s when s.options.isEmpty => AskInputMode.freeText,
        AskPromptSpec s when s.multiSelect => AskInputMode.multiSelect,
        _ => AskInputMode.singleSelect,
      },
      secretName = switch (spec) {
        SecretPromptSpec s => s.name,
        _ => '',
      },
      secretValue = '',
      secretCursor = switch (spec) {
        SecretPromptSpec _ => -1, // -1 = focus on name field
        _ => 0,
      },
      secretValueVisible = false,
      approvalInput = '';

  final TuiPromptSpec spec;
  final Set<int> askSelected;
  final int askCursor;
  final AskInputMode askMode;
  final String secretName;
  final String secretValue;
  final int secretCursor;

  /// Whether the secret sheet renders the typed value in clear text
  /// (Ctrl+R toggles; hidden is the default).
  final bool secretValueVisible;

  /// Text typed into an approval prompt that is not a y/a/n answer: the
  /// user can leave a note for the agent alongside the decision. Any
  /// recognized answer key submits the decision and clears the buffer.
  final String approvalInput;

  bool get hasOptions {
    final s = spec;
    return s is AskPromptSpec && s.options.isNotEmpty;
  }

  int get optionCount {
    final s = spec;
    return s is AskPromptSpec ? s.options.length : 0;
  }

  AskPromptSpec get askSpec => spec as AskPromptSpec;
  SecretPromptSpec get secretSpec => spec as SecretPromptSpec;
  ApprovalPromptSpec get approvalSpec => spec as ApprovalPromptSpec;
  TextPromptSpec get textSpec => spec as TextPromptSpec;

  TuiPromptState copyWith({
    Set<int>? askSelected,
    int? askCursor,
    AskInputMode? askMode,
    String? secretName,
    String? secretValue,
    int? secretCursor,
    bool? secretValueVisible,
    String? approvalInput,
  }) {
    return TuiPromptState._raw(
      spec,
      askSelected: askSelected ?? this.askSelected,
      askCursor: askCursor ?? this.askCursor,
      askMode: askMode ?? this.askMode,
      secretName: secretName ?? this.secretName,
      secretValue: secretValue ?? this.secretValue,
      secretCursor: secretCursor ?? this.secretCursor,
      secretValueVisible: secretValueVisible ?? this.secretValueVisible,
      approvalInput: approvalInput ?? this.approvalInput,
    );
  }

  TuiPromptState._raw(
    this.spec, {
    required this.askSelected,
    required this.askCursor,
    required this.askMode,
    required this.secretName,
    required this.secretValue,
    required this.secretCursor,
    this.secretValueVisible = false,
    this.approvalInput = '',
  });
}

enum AskInputMode { singleSelect, multiSelect, freeText }

/// The total number of physical rows the rendered frame occupies at [width].
int tuiPromptRowCount(TuiPromptState state, int width) {
  return _frameRows(state, width).length;
}

/// Renders the prompt zone for [state] at [width]. Returns a list of
/// already-styled rows. Pre-clip [width] to >= 20.
List<String> renderTuiPrompt(TuiPromptState state, int width) {
  if (width < 20) width = 20;
  return _frameRows(state, width);
}

/// The result of handling one prompt key: the next state plus an optional
/// resolved answer.
typedef _PromptKeyResult = ({TuiPromptState state, TuiPromptAnswer? resolved});

/// Pure key handler: returns the next state and optionally a resolved answer.
({TuiPromptState state, TuiPromptAnswer? resolved}) handleTuiPromptKey(
  TuiPromptState state,
  PromptKey key,
) {
  return switch (state.spec) {
    AskPromptSpec() => _handleAskKey(state, key),
    SecretPromptSpec() => _handleSecretKey(state, key),
    ApprovalPromptSpec() => _handleApprovalKey(state, key),
    TextPromptSpec() => _handleTextKey(state, key),
  };
}

// ---------------------------------------------------------------------------
// Shared key clusters (buffer editing, cancel)
// ---------------------------------------------------------------------------

/// Escape cancels the prompt; null when [key] belongs to another cluster.
_PromptKeyResult? _handleEscapeKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptEscape) return null;
  return (state: state, resolved: const TuiPromptCancelled());
}

/// The state with the edited buffer/cursor written into the field pair the
/// prompt uses (ask free text edits `askCursor`, the text prompt edits
/// `secretCursor`; both share `secretValue` as the buffer).
TuiPromptState _withBufferEdit(
  TuiPromptState state,
  String buffer,
  int cursor, {
  required bool useAskCursor,
}) {
  return useAskCursor
      ? state.copyWith(secretValue: buffer, askCursor: cursor)
      : state.copyWith(secretValue: buffer, secretCursor: cursor);
}

/// Left/right cursor motion inside the edited buffer; null when [key]
/// belongs to another cluster.
_PromptKeyResult? _handleBufferArrowKey(
  TuiPromptState state,
  PromptKey key, {
  required bool useAskCursor,
}) {
  if (key is! PromptArrowLeft && key is! PromptArrowRight) return null;
  final buffer = state.secretValue;
  final cursor = useAskCursor ? state.askCursor : state.secretCursor;
  final next = _movedBufferCursor(key, cursor, buffer.length);
  return (
    state: _withBufferEdit(state, buffer, next, useAskCursor: useAskCursor),
    resolved: null,
  );
}

/// The cursor position after a left/right arrow inside a buffer of [length]
/// characters (clamped at both ends).
int _movedBufferCursor(PromptKey key, int cursor, int length) {
  if (key is PromptArrowLeft && cursor > 0) return cursor - 1;
  if (key is PromptArrowRight && cursor < length) return cursor + 1;
  return cursor;
}

/// Backspace deletes the char before the cursor (a no-op at position 0 or
/// on an empty buffer); null when [key] belongs to another cluster.
_PromptKeyResult? _handleBufferBackspaceKey(
  TuiPromptState state,
  PromptKey key, {
  required bool useAskCursor,
}) {
  if (key is! PromptBackspace) return null;
  final buffer = state.secretValue;
  final cursor = useAskCursor ? state.askCursor : state.secretCursor;
  final deleted = _backspacedBuffer(buffer, cursor);
  if (deleted == null) {
    return (
      state: _withBufferEdit(state, buffer, cursor, useAskCursor: useAskCursor),
      resolved: null,
    );
  }
  return (
    state: _withBufferEdit(
      state,
      deleted.$1,
      deleted.$2,
      useAskCursor: useAskCursor,
    ),
    resolved: null,
  );
}

/// The buffer and cursor after a backspace at [cursor], or null when the
/// backspace is a no-op (empty buffer or cursor at the start).
(String, int)? _backspacedBuffer(String buffer, int cursor) {
  if (cursor == 0 || buffer.isEmpty) return null;
  return (
    buffer.substring(0, cursor - 1) + buffer.substring(cursor),
    cursor - 1,
  );
}

/// A typed char is inserted at the cursor; null when [key] belongs to
/// another cluster.
_PromptKeyResult? _handleBufferCharKey(
  TuiPromptState state,
  PromptKey key, {
  required bool useAskCursor,
}) {
  if (key is! PromptChar && key is! PromptPaste) return null;
  final String text;
  if (key is PromptChar) {
    text = key.text;
  } else if (key is PromptPaste) {
    text = key.text;
  } else {
    return null;
  }
  if (text.isEmpty) return null;
  final buffer = state.secretValue;
  final cursor = useAskCursor ? state.askCursor : state.secretCursor;
  final next = buffer.substring(0, cursor) + text + buffer.substring(cursor);
  return (
    state: _withBufferEdit(
      state,
      next,
      cursor + text.length,
      useAskCursor: useAskCursor,
    ),
    resolved: null,
  );
}

// ---------------------------------------------------------------------------
// Ask
// ---------------------------------------------------------------------------

({TuiPromptState state, TuiPromptAnswer? resolved}) _handleAskKey(
  TuiPromptState state,
  PromptKey key,
) {
  final spec = state.askSpec;
  if (spec.options.isEmpty) {
    return _handleAskFreeTextKey(state, key);
  }
  return switch (state.askMode) {
    AskInputMode.singleSelect => _handleAskSingleKey(state, key),
    AskInputMode.multiSelect => _handleAskMultiKey(state, key),
    AskInputMode.freeText => _handleAskFreeTextKey(state, key),
  };
}

final RegExp _digitPattern = RegExp(r'^\d$');

/// Single-select ask: nav → digit pick → char (space/mode/free text) →
/// accept/cancel; anything else leaves the state untouched.
_PromptKeyResult _handleAskSingleKey(TuiPromptState state, PromptKey key) {
  return _handleAskNavKey(state, key) ??
      _handleAskSingleDigitKey(state, key) ??
      _handleAskSingleCharKey(state, key) ??
      _handleAskSingleAcceptKey(state, key) ??
      (state: state, resolved: null);
}

/// Multi-select ask: nav → digit toggle → char (done/free text) →
/// accept/cancel; anything else leaves the state untouched.
_PromptKeyResult _handleAskMultiKey(TuiPromptState state, PromptKey key) {
  return _handleAskNavKey(state, key) ??
      _handleAskMultiDigitKey(state, key) ??
      _handleAskMultiCharKey(state, key) ??
      _handleAskMultiAcceptKey(state, key) ??
      (state: state, resolved: null);
}

/// Option-list navigation (↑/↓), shared by the single- and multi-select
/// modes; null when the key belongs to another cluster.
_PromptKeyResult? _handleAskNavKey(TuiPromptState state, PromptKey key) {
  final spec = state.askSpec;
  switch (key) {
    case PromptArrowUp():
      final next = state.askCursor > 0 ? state.askCursor - 1 : 0;
      return (state: state.copyWith(askCursor: next), resolved: null);
    case PromptArrowDown():
      final max = spec.options.length - 1;
      final next = state.askCursor < max ? state.askCursor + 1 : max;
      return (state: state.copyWith(askCursor: next), resolved: null);
    default:
      return null;
  }
}

/// Single-select digit keys pick the numbered option outright; null when the
/// key is not a digit char.
_PromptKeyResult? _handleAskSingleDigitKey(
  TuiPromptState state,
  PromptKey key,
) {
  if (key is! PromptChar || !_digitPattern.hasMatch(key.text)) return null;
  final spec = state.askSpec;
  final number = int.parse(key.text);
  if (number < 1 || number > spec.options.length) {
    return (state: state, resolved: null);
  }
  final pick = spec.options[number - 1].label;
  return (state: state, resolved: AskPromptAnswer(AskAnswer.selection([pick])));
}

/// Single-select char keys: space enters free text, `m` switches to
/// multi-select when available, anything else starts free text with the
/// char. Null when the key is not a char.
_PromptKeyResult? _handleAskSingleCharKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptChar) return null;
  final ch = key.text;
  if (ch == ' ') return _enterAskFreeText(state);
  if (ch == 'm' && state.askSpec.multiSelect) {
    return (
      state: state.copyWith(askMode: AskInputMode.multiSelect),
      resolved: null,
    );
  }
  return _enterAskFreeText(state, prepend: ch);
}

/// Single-select accept keys (enter/tab pick the cursor option, esc
/// cancels); null when the key belongs to another cluster.
_PromptKeyResult? _handleAskSingleAcceptKey(
  TuiPromptState state,
  PromptKey key,
) {
  final spec = state.askSpec;
  switch (key) {
    case PromptEnter():
    case PromptTab():
      if (spec.options.isEmpty) return (state: state, resolved: null);
      final pick = spec.options[state.askCursor].label;
      return (
        state: state,
        resolved: AskPromptAnswer(AskAnswer.selection([pick])),
      );
    case PromptEscape():
      return (state: state, resolved: const TuiPromptCancelled());
    default:
      return null;
  }
}

/// Multi-select digit keys toggle the numbered option; null when the key is
/// not a digit char.
_PromptKeyResult? _handleAskMultiDigitKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptChar || !_digitPattern.hasMatch(key.text)) return null;
  final spec = state.askSpec;
  final number = int.parse(key.text);
  if (number < 1 || number > spec.options.length) {
    return (state: state, resolved: null);
  }
  final i = number - 1;
  final selected = Set<int>.from(state.askSelected);
  if (!selected.remove(i)) selected.add(i);
  return (state: state.copyWith(askSelected: selected), resolved: null);
}

/// Multi-select char keys: `d` finishes with the current selection (or
/// enters free text when empty), space enters free text, anything else is
/// ignored. Null when the key is not a char.
_PromptKeyResult? _handleAskMultiCharKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptChar) return null;
  final ch = key.text;
  if (ch.toLowerCase() == 'd') return _resolveAskMultiSelection(state);
  if (ch == ' ') return _enterAskFreeText(state);
  return (state: state, resolved: null);
}

/// Multi-select accept keys: enter finishes with the current selection, tab
/// enters free text, esc cancels; null for other clusters.
_PromptKeyResult? _handleAskMultiAcceptKey(
  TuiPromptState state,
  PromptKey key,
) {
  switch (key) {
    case PromptEnter():
      return _resolveAskMultiSelection(state);
    case PromptTab():
      return _enterAskFreeText(state);
    case PromptEscape():
      return (state: state, resolved: const TuiPromptCancelled());
    default:
      return null;
  }
}

/// Resolves the multi-select selection as the answer, or enters free text
/// when nothing is selected.
_PromptKeyResult _resolveAskMultiSelection(TuiPromptState state) {
  if (state.askSelected.isEmpty) return _enterAskFreeText(state);
  final spec = state.askSpec;
  final picked = [
    for (final i in state.askSelected.toList()..sort()) spec.options[i].label,
  ];
  return (state: state, resolved: AskPromptAnswer(AskAnswer.selection(picked)));
}

/// Free-text ask: buffer edit keys → enter → esc; tab/↑/↓ are ignored.
_PromptKeyResult _handleAskFreeTextKey(TuiPromptState state, PromptKey key) {
  return _handleBufferArrowKey(state, key, useAskCursor: true) ??
      _handleBufferBackspaceKey(state, key, useAskCursor: true) ??
      _handleBufferCharKey(state, key, useAskCursor: true) ??
      _handleAskFreeTextEnterKey(state, key) ??
      _handleEscapeKey(state, key) ??
      (state: state, resolved: null);
}

/// Free-text enter: an empty buffer with options reverts to option
/// selection (the user entered free text accidentally via space), an
/// empty/`!` text cancels, otherwise the trimmed text is the answer.
_PromptKeyResult? _handleAskFreeTextEnterKey(
  TuiPromptState state,
  PromptKey key,
) {
  if (key is! PromptEnter) return null;
  final spec = state.askSpec;
  final buffer = state.secretValue;
  if (buffer.isEmpty && spec.options.isNotEmpty) {
    return (state: _revertAskToOptions(state, spec), resolved: null);
  }
  final text = buffer.trim();
  if (text.isEmpty || text == '!') {
    return (state: state, resolved: const TuiPromptCancelled());
  }
  return (state: state, resolved: AskPromptAnswer(AskAnswer.text(text)));
}

/// Reverts an accidentally-entered free-text ask back to option selection.
TuiPromptState _revertAskToOptions(TuiPromptState state, AskPromptSpec spec) {
  return state.copyWith(
    secretValue: '',
    askCursor: 0,
    askMode: spec.multiSelect
        ? AskInputMode.multiSelect
        : AskInputMode.singleSelect,
  );
}

({TuiPromptState state, TuiPromptAnswer? resolved}) _enterAskFreeText(
  TuiPromptState state, {
  String prepend = '',
}) {
  final next = state.copyWith(
    askMode: AskInputMode.freeText,
    secretValue: prepend,
    askCursor: prepend.length,
  );
  return (state: next, resolved: null);
}

// ---------------------------------------------------------------------------
// Secret
// ---------------------------------------------------------------------------

final RegExp _secretNamePattern = RegExp(r'^[A-Z][A-Z0-9_]*$');

bool _secretSubmittable(TuiPromptState state) {
  if (state.spec is! SecretPromptSpec) return false;
  if (!_secretNamePattern.hasMatch(state.secretName)) return false;
  if (state.secretValue.isEmpty) return false;
  return true;
}

/// Secret prompt: value-cursor arrows → backspace → char → enter → tab →
/// esc; ↑/↓ are ignored.
_PromptKeyResult _handleSecretKey(TuiPromptState state, PromptKey key) {
  return _handleSecretRevealKey(state, key) ??
      _handleSecretArrowKey(state, key) ??
      _handleSecretBackspaceKey(state, key) ??
      _handleSecretCharKey(state, key) ??
      _handleSecretEnterKey(state, key) ??
      _handleSecretTabKey(state, key) ??
      _handleEscapeKey(state, key) ??
      (state: state, resolved: null);
}

/// Ctrl+R toggles the value's clear-text rendering; null for other keys.
_PromptKeyResult? _handleSecretRevealKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptCtrlR) return null;
  return (
    state: state.copyWith(secretValueVisible: !state.secretValueVisible),
    resolved: null,
  );
}

/// Left/right move the value cursor; the name field (-1) has no cursor
/// motion. Null when the key belongs to another cluster.
_PromptKeyResult? _handleSecretArrowKey(TuiPromptState state, PromptKey key) {
  switch (key) {
    case PromptArrowLeft():
      if (state.secretCursor <= 0) return (state: state, resolved: null);
      return (
        state: state.copyWith(secretCursor: state.secretCursor - 1),
        resolved: null,
      );
    case PromptArrowRight():
      if (state.secretCursor < 0 ||
          state.secretCursor >= state.secretValue.length) {
        return (state: state, resolved: null);
      }
      return (
        state: state.copyWith(secretCursor: state.secretCursor + 1),
        resolved: null,
      );
    default:
      return null;
  }
}

/// Backspace trims the name on name focus, deletes before the cursor on
/// value focus. Null when the key belongs to another cluster.
_PromptKeyResult? _handleSecretBackspaceKey(
  TuiPromptState state,
  PromptKey key,
) {
  if (key is! PromptBackspace) return null;
  if (state.secretCursor < 0) return _backspaceSecretName(state);
  final deleted = _backspacedBuffer(state.secretValue, state.secretCursor);
  if (deleted == null) return (state: state, resolved: null);
  return (
    state: state.copyWith(secretValue: deleted.$1, secretCursor: deleted.$2),
    resolved: null,
  );
}

/// Backspace on name focus: trims the last char of the name, if any.
_PromptKeyResult _backspaceSecretName(TuiPromptState state) {
  if (state.secretName.isEmpty) return (state: state, resolved: null);
  return (
    state: state.copyWith(
      secretName: state.secretName.substring(0, state.secretName.length - 1),
    ),
    resolved: null,
  );
}

/// A typed char appends to the name on name focus, inserts at the cursor on
/// value focus. Null when the key belongs to another cluster.
_PromptKeyResult? _handleSecretCharKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptChar) return null;
  if (state.secretCursor < 0) {
    return (
      state: state.copyWith(secretName: state.secretName + key.text),
      resolved: null,
    );
  }
  final next =
      state.secretValue.substring(0, state.secretCursor) +
      key.text +
      state.secretValue.substring(state.secretCursor);
  return (
    state: state.copyWith(
      secretValue: next,
      secretCursor: state.secretCursor + 1,
    ),
    resolved: null,
  );
}

/// Enter submits the secret once the name matches and the value is
/// non-empty. Null when the key belongs to another cluster.
_PromptKeyResult? _handleSecretEnterKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptEnter) return null;
  if (!_secretSubmittable(state)) return (state: state, resolved: null);
  return (
    state: state,
    resolved: SecretPromptAnswer(
      RequestSecretResult(
        name: state.secretName,
        value: state.secretValue,
        persisted: false,
      ),
    ),
  );
}

/// Tab moves from name (-1) to value (0) focus. Null when the key belongs
/// to another cluster.
_PromptKeyResult? _handleSecretTabKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptTab) return null;
  if (state.secretCursor < 0) {
    return (state: state.copyWith(secretCursor: 0), resolved: null);
  }
  return (state: state, resolved: null);
}

// ---------------------------------------------------------------------------
// Approval
// ---------------------------------------------------------------------------

/// Approval prompt: y/a/n answer keys → enter/esc deny; anything else
/// leaves the state untouched.
_PromptKeyResult _handleApprovalKey(TuiPromptState state, PromptKey key) {
  return _handleApprovalAnswerKey(state, key) ??
      _handleApprovalDenyKey(state, key) ??
      (state: state, resolved: null);
}

/// The y/a/n answer keys resolve the decision (carrying the typed note) and
/// clear the note buffer; any other char is appended to the note buffer
/// instead (the user can leave a message for the agent alongside the
/// answer); null when the key is not a char.
_PromptKeyResult? _handleApprovalAnswerKey(
  TuiPromptState state,
  PromptKey key,
) {
  if (key is! PromptChar) return null;
  final note = state.approvalInput;
  return switch (key.text.toLowerCase()) {
    'y' => (
      state: state.copyWith(approvalInput: ''),
      resolved: ApprovalPromptAnswer(ApprovalDecision.approveOnce, note: note),
    ),
    'a' => (
      state: state.copyWith(approvalInput: ''),
      resolved: ApprovalPromptAnswer(
        ApprovalDecision.approveAlways,
        note: note,
      ),
    ),
    'n' => (
      state: state.copyWith(approvalInput: ''),
      resolved: ApprovalPromptAnswer(ApprovalDecision.deny, note: note),
    ),
    _ => (
      state: state.copyWith(approvalInput: state.approvalInput + key.text),
      resolved: null,
    ),
  };
}

/// Enter denies on an empty note buffer — with typed text the prompt stays
/// open (Enter does not submit a decision while the user is writing).
/// Escape always denies (the typed note rides along); null when the key
/// belongs to another cluster.
_PromptKeyResult? _handleApprovalDenyKey(TuiPromptState state, PromptKey key) {
  switch (key) {
    case PromptEscape():
      return (
        state: state.copyWith(approvalInput: ''),
        resolved: ApprovalPromptAnswer(
          ApprovalDecision.deny,
          note: state.approvalInput,
        ),
      );
    case PromptEnter():
      if (state.approvalInput.isNotEmpty) return (state: state, resolved: null);
      return (
        state: state,
        resolved: const ApprovalPromptAnswer(ApprovalDecision.deny),
      );
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/// Text prompt: buffer edit keys → enter → esc; tab/↑/↓ are ignored.
_PromptKeyResult _handleTextKey(TuiPromptState state, PromptKey key) {
  return _handleBufferArrowKey(state, key, useAskCursor: false) ??
      _handleBufferBackspaceKey(state, key, useAskCursor: false) ??
      _handleBufferCharKey(state, key, useAskCursor: false) ??
      _handleTextEnterKey(state, key) ??
      _handleEscapeKey(state, key) ??
      (state: state, resolved: null);
}

/// Text enter answers with the trimmed buffer, falling back to the spec's
/// default value (or an empty string) when blank. Null when the key belongs
/// to another cluster.
_PromptKeyResult? _handleTextEnterKey(TuiPromptState state, PromptKey key) {
  if (key is! PromptEnter) return null;
  final text = state.secretValue.trim();
  if (text.isNotEmpty) {
    return (state: state, resolved: TextPromptAnswer(text));
  }
  return (
    state: state,
    resolved: TextPromptAnswer(state.textSpec.defaultValue ?? ''),
  );
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

String _accent(String s) => '\x1b[1m\x1b[38;2;94;234;212m$s\x1b[0m';
String _accent2Plain(String s) => '\x1b[38;2;129;140;248m$s\x1b[0m';
String _dim(String s) => '\x1b[2m$s\x1b[0m';
String _bold(String s) => '\x1b[1m$s\x1b[0m';
String _yellow(String s) => '\x1b[38;2;250;204;21m$s\x1b[0m';
String _red(String s) => '\x1b[38;2;248;113;113m$s\x1b[0m';

String _fitWidth(String text, int maxWidth) {
  if (maxWidth <= 1) return text.substring(0, maxWidth);
  if (text.length <= maxWidth) return text;
  return '${text.substring(0, maxWidth - 1)}…';
}

List<String> _frameRows(TuiPromptState state, int width) {
  final inner = width - 2;
  final rows = <String>[];

  // Border rows must be exactly `width` visible columns (inner + 2).
  // ┌─${header}${dashes}┐ = 1 + 1 + header + dashes + 1 = inner + 2
  final headerText = ' ${state.spec.header} ';
  final headerStyled = _accent(headerText);
  final headerVisible = headerText.length;
  final dashesAfter = (inner - headerVisible - 1).clamp(0, inner);
  rows.add('┌─$headerStyled${'─' * dashesAfter}┐');

  rows.addAll(_bodyRows(state, inner));
  rows.add('├─${'─' * (inner - 1)}┤');
  rows.addAll(_inputRows(state, inner, width));
  rows.add('└─${'─' * (inner - 1)}┘');
  return rows;
}

List<String> _bodyRows(TuiPromptState state, int inner) {
  return switch (state.spec) {
    AskPromptSpec spec => _askBodyRows(state, spec, inner),
    SecretPromptSpec spec => _secretBodyRows(spec, inner),
    ApprovalPromptSpec spec => _approvalBodyRows(state, spec, inner),
    TextPromptSpec spec => _textBodyRows(spec, inner),
  };
}

List<String> _askBodyRows(TuiPromptState state, AskPromptSpec spec, int inner) {
  final header =
      'Question ${spec.index + 1} of ${spec.total}'
      '${spec.options.isEmpty ? ' (free text)' : ''}';
  final rows = <String>[_wrapBodyLine(header, inner, bold: true)];
  for (final line in _wrapText(spec.question, inner)) {
    rows.add(_wrapBodyLine(line, inner));
  }
  rows.addAll(_askOptionRows(state, inner));
  return rows;
}

List<String> _secretBodyRows(SecretPromptSpec spec, int inner) {
  final rows = <String>[_wrapBodyLine('Credential request', inner, bold: true)];
  for (final line in _wrapText(spec.reason, inner)) {
    rows.add(_wrapBodyLine(line, inner));
  }
  return rows;
}

List<String> _approvalBodyRows(
  TuiPromptState state,
  ApprovalPromptSpec spec,
  int inner,
) {
  final req = spec.request;
  final rows = <String>[
    _wrapBodyLine('Tool: ${req.toolName}', inner, bold: true),
    _wrapBodyLine('Tier: ${req.tier.name}', inner),
  ];
  for (final line in _wrapText(req.reason, inner)) {
    rows.add(_wrapBodyLine(line, inner, dim: true));
  }
  final args = req.arguments.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(', ');
  final argLine = args.isEmpty ? '(no arguments)' : args;
  rows.add(_wrapBodyLine('Args: ${_fitWidth(argLine, inner - 6)}', inner));
  return rows;
}

List<String> _textBodyRows(TextPromptSpec spec, int inner) {
  final rows = <String>[_wrapBodyLine(spec.question, inner, bold: true)];
  final defaultValue = spec.defaultValue;
  if (defaultValue != null && defaultValue.isNotEmpty) {
    rows.add(_wrapBodyLine(_dim('(default: $defaultValue)'), inner, dim: true));
  }
  return rows;
}

String _wrapBodyLine(
  String text,
  int inner, {
  bool bold = false,
  bool dim = false,
}) {
  final content = _fitWidth(text, inner);
  // Padding must be based on the VISIBLE length — strip ANSI escape codes
  // so pre-styled strings (dim/red/yellow hints) don't skew the frame.
  final visibleLength = _stripAnsi(content).length;
  final styled = bold
      ? _bold(content)
      : dim
      ? _dim(content)
      : content;
  return '│ $styled${' ' * (inner - visibleLength - 1)}│';
}

/// Strips ANSI escape sequences for visible-length computation.
String _stripAnsi(String text) {
  return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
}

List<String> _wrapText(String text, int width) {
  if (text.isEmpty) return [''];
  final out = <String>[];
  for (final paragraph in text.split('\n')) {
    if (paragraph.isEmpty) {
      out.add('');
      continue;
    }
    var rest = paragraph;
    while (rest.length > width) {
      out.add(rest.substring(0, width));
      rest = rest.substring(width);
    }
    out.add(rest);
  }
  return out;
}

List<String> _askOptionRows(TuiPromptState state, int inner) {
  final spec = state.askSpec;
  if (spec.options.isEmpty) return const [];
  final rows = <String>[];
  for (var i = 0; i < spec.options.length; i++) {
    rows.addAll(_askOptionRowLines(state, i, inner));
  }
  return rows;
}

/// The rendered lines for option [i]: the label row plus, when the option
/// has a description, the dimmed wrapped description lines under it.
List<String> _askOptionRowLines(TuiPromptState state, int i, int inner) {
  final spec = state.askSpec;
  final option = spec.options[i];
  final selected =
      i == state.askCursor && state.askMode != AskInputMode.freeText;
  final marker = _askOptionMarker(state, i, selected: selected);
  final recommended = spec.recommended == i ? ' ★' : '';
  final labelLine = '${i + 1}. $marker ${option.label}$recommended';
  final description = option.description;
  if (description != null && description.isNotEmpty) {
    return _askOptionDescriptionRows(
      labelLine,
      description,
      inner,
      selected: selected,
    );
  }
  return [_askOptionLabelRow(labelLine, inner, selected: selected)];
}

/// The selection marker for option [i]: a toggle dot in multi-select mode,
/// a cursor arrow otherwise.
String _askOptionMarker(TuiPromptState state, int i, {required bool selected}) {
  return switch (state.askMode) {
    AskInputMode.multiSelect => state.askSelected.contains(i) ? '◉' : '○',
    _ => selected ? '▸' : ' ',
  };
}

/// The label row plus the dimmed wrapped description lines under it.
List<String> _askOptionDescriptionRows(
  String labelLine,
  String description,
  int inner, {
  required bool selected,
}) {
  return [
    _wrapBodyLine(_fitWidth(labelLine, inner), inner, dim: !selected),
    for (final line in _wrapText('     $description', inner))
      _wrapBodyLine(line, inner, dim: true),
  ];
}

/// The one-line label row for an option without a description (accented
/// when the cursor is on it).
String _askOptionLabelRow(
  String labelLine,
  int inner, {
  required bool selected,
}) {
  final styled = selected ? _accent(labelLine) : _fitWidth(labelLine, inner);
  return '│ $styled${' ' * (inner - labelLine.length - 1)}│';
}

List<String> _inputRows(TuiPromptState state, int inner, int width) {
  return switch (state.spec) {
    AskPromptSpec() => _askInputRows(state, inner),
    SecretPromptSpec() => _secretInputRows(state, inner),
    ApprovalPromptSpec() => _approvalInputRows(state, inner),
    TextPromptSpec() => _textInputRows(state, inner),
  };
}

List<String> _askInputRows(TuiPromptState state, int inner) {
  final spec = state.askSpec;
  final isFree = state.askMode == AskInputMode.freeText;
  if (isFree) {
    final buffer = state.secretValue;
    final cursor = state.askCursor;
    final hint = spec.options.isEmpty
        ? 'Type your answer (Enter to send, ! to cancel):'
        : 'Type your answer (Enter to send, Esc to cancel):';
    final rows = <String>[];
    rows.add(_wrapBodyLine(_dim(hint), inner, dim: true));
    rows.add(_cursorInputRow(buffer, cursor, inner));
    return rows;
  }
  final hint = spec.multiSelect
      ? '↑/↓ navigate · numbers toggle · d done · space for free text · Esc cancel'
      : '↑/↓ navigate · number to select · space for free text · '
            'Enter to confirm · Esc cancel';
  return [
    _wrapBodyLine(_dim(hint), inner, dim: true),
    _wrapBodyLine('', inner),
  ];
}

List<String> _textInputRows(TuiPromptState state, int inner) {
  final spec = state.textSpec;
  final buffer = state.secretValue;
  final cursor = state.secretCursor;
  final display = spec.secret ? '•' * buffer.length : buffer;
  final hint = spec.secret
      ? 'Type your answer (hidden, Enter to send, Esc to cancel):'
      : 'Type your answer (Enter to send, Esc to cancel):';
  final rows = <String>[];
  rows.add(_wrapBodyLine(_dim(hint), inner, dim: true));
  rows.add(_cursorInputRow(display, cursor, inner));
  return rows;
}

List<String> _secretInputRows(TuiPromptState state, int inner) {
  final rows = <String>[];
  final visible = state.secretValueVisible;
  rows.add(
    _wrapBodyLine(
      _dim(
        visible
            ? 'Name (UPPER_SNAKE) — value visible (Ctrl+R hides):'
            : 'Name (UPPER_SNAKE) — value hidden (Ctrl+R reveals):',
      ),
      inner,
      dim: true,
    ),
  );
  rows.add(_wrapBodyLine(state.secretName, inner, bold: true));
  final focusedOnValue = state.secretCursor >= 0;
  final hint = focusedOnValue
      ? 'Enter to save · Esc to cancel'
      : 'Start typing the value · Esc to cancel';
  rows.add(_wrapBodyLine(_dim(hint), inner, dim: true));
  final display = visible
      ? state.secretValue
      : '•' * state.secretValue.length;
  rows.add(_wrapBodyLine(display, inner, bold: true));
  if (!_secretNamePattern.hasMatch(state.secretName)) {
    rows.add(_wrapBodyLine(_red('Name must match ^[A-Z][A-Z0-9_]*\$'), inner));
  }
  return rows;
}

List<String> _approvalInputRows(TuiPromptState state, int inner) {
  final hasNote = state.approvalInput.isNotEmpty;
  return [
    _wrapBodyLine(
      _dim(
        '[y] once  [a] always  [n] deny  · other keys type a note  · '
        'Enter/Esc = deny',
      ),
      inner,
      dim: true,
    ),
    if (hasNote)
      _wrapBodyLine(_yellow('note: ${state.approvalInput}'), inner)
    else
      _wrapBodyLine('', inner),
    _wrapBodyLine(_yellow('Awaiting decision…'), inner),
  ];
}

/// Renders an input row with the cursor inline (reverse-video block at
/// [cursor] position). The visible width is exactly `inner + 2` columns:
/// `│` + ` > ` + text + padding + `│`.
String _cursorInputRow(String display, int cursor, int inner) {
  final clampedCursor = cursor.clamp(0, display.length);
  final before = display.substring(0, clampedCursor);
  final at = clampedCursor < display.length ? display[clampedCursor] : ' ';
  final after = clampedCursor < display.length
      ? display.substring(clampedCursor + 1)
      : '';
  const invert = '\x1b[7m';
  const reset = '\x1b[0m';
  // Visible width: │(1) (1) >(1) (1) + contentWidth + padding + │(1)
  // = 5 + contentWidth + padding = inner + 2 → padding = inner - 3 - contentWidth
  final contentWidth =
      display.length + (clampedCursor >= display.length ? 1 : 0);
  final padding = (inner - 3 - contentWidth).clamp(0, inner);
  return '│ ${_accent2Plain('>')} ${_accent(before)}'
      '$invert$at$reset${_accent(after)}'
      '${' ' * padding}│';
}
