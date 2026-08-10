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
  const ApprovalPromptAnswer(this.value);
  final ApprovalDecision value;
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
      };

  final TuiPromptSpec spec;
  final Set<int> askSelected;
  final int askCursor;
  final AskInputMode askMode;
  final String secretName;
  final String secretValue;
  final int secretCursor;

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
  }) {
    return TuiPromptState._raw(
      spec,
      askSelected: askSelected ?? this.askSelected,
      askCursor: askCursor ?? this.askCursor,
      askMode: askMode ?? this.askMode,
      secretName: secretName ?? this.secretName,
      secretValue: secretValue ?? this.secretValue,
      secretCursor: secretCursor ?? this.secretCursor,
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

({TuiPromptState state, TuiPromptAnswer? resolved}) _handleAskSingleKey(
  TuiPromptState state,
  PromptKey key,
) {
  final spec = state.askSpec;
  switch (key) {
    case PromptArrowUp():
      final next = state.askCursor > 0 ? state.askCursor - 1 : 0;
      return (state: state.copyWith(askCursor: next), resolved: null);
    case PromptArrowDown():
      final max = spec.options.length - 1;
      final next = state.askCursor < max ? state.askCursor + 1 : max;
      return (state: state.copyWith(askCursor: next), resolved: null);
    case PromptChar():
      final ch = (key).text;
      if (ch == ' ') {
        return _enterAskFreeText(state);
      }
      if (ch == 'm' && spec.multiSelect) {
        return (
          state: state.copyWith(askMode: AskInputMode.multiSelect),
          resolved: null,
        );
      }
      if (RegExp(r'^\d$').hasMatch(ch)) {
        final number = int.parse(ch);
        if (number >= 1 && number <= spec.options.length) {
          final pick = spec.options[number - 1].label;
          return (
            state: state,
            resolved: AskPromptAnswer(AskAnswer.selection([pick])),
          );
        }
        return (state: state, resolved: null);
      }
      return _enterAskFreeText(state, prepend: ch);
    case PromptEnter():
      if (spec.options.isEmpty) return (state: state, resolved: null);
      final pick = spec.options[state.askCursor].label;
      return (
        state: state,
        resolved: AskPromptAnswer(AskAnswer.selection([pick])),
      );
    case PromptTab():
      if (spec.options.isEmpty) return (state: state, resolved: null);
      final pick = spec.options[state.askCursor].label;
      return (
        state: state,
        resolved: AskPromptAnswer(AskAnswer.selection([pick])),
      );
    case PromptEscape():
      return (state: state, resolved: const TuiPromptCancelled());
    case PromptBackspace():
    case PromptArrowLeft():
    case PromptArrowRight():
      return (state: state, resolved: null);
  }
}

({TuiPromptState state, TuiPromptAnswer? resolved}) _handleAskMultiKey(
  TuiPromptState state,
  PromptKey key,
) {
  final spec = state.askSpec;
  switch (key) {
    case PromptArrowUp():
      final next = state.askCursor > 0 ? state.askCursor - 1 : 0;
      return (state: state.copyWith(askCursor: next), resolved: null);
    case PromptArrowDown():
      final max = spec.options.length - 1;
      final next = state.askCursor < max ? state.askCursor + 1 : max;
      return (state: state.copyWith(askCursor: next), resolved: null);
    case PromptChar():
      final ch = (key).text;
      if (RegExp(r'^\d$').hasMatch(ch)) {
        final number = int.parse(ch);
        if (number >= 1 && number <= spec.options.length) {
          final i = number - 1;
          final selected = Set<int>.from(state.askSelected);
          if (!selected.remove(i)) selected.add(i);
          return (state: state.copyWith(askSelected: selected), resolved: null);
        }
        return (state: state, resolved: null);
      }
      if (ch.toLowerCase() == 'd') {
        if (state.askSelected.isNotEmpty) {
          final picked = [
            for (final i in state.askSelected.toList()..sort())
              spec.options[i].label,
          ];
          return (
            state: state,
            resolved: AskPromptAnswer(AskAnswer.selection(picked)),
          );
        }
        return _enterAskFreeText(state);
      }
      if (ch == ' ') {
        return _enterAskFreeText(state);
      }
      return (state: state, resolved: null);
    case PromptEnter():
      if (state.askSelected.isNotEmpty) {
        final picked = [
          for (final i in state.askSelected.toList()..sort())
            spec.options[i].label,
        ];
        return (
          state: state,
          resolved: AskPromptAnswer(AskAnswer.selection(picked)),
        );
      }
      return _enterAskFreeText(state);
    case PromptTab():
      return _enterAskFreeText(state);
    case PromptEscape():
      return (state: state, resolved: const TuiPromptCancelled());
    case PromptBackspace():
    case PromptArrowLeft():
    case PromptArrowRight():
      return (state: state, resolved: null);
  }
}

({TuiPromptState state, TuiPromptAnswer? resolved}) _handleAskFreeTextKey(
  TuiPromptState state,
  PromptKey key,
) {
  final spec = state.askSpec;
  var buffer = state.secretValue;
  var cursor = state.askCursor;

  switch (key) {
    case PromptArrowLeft():
      if (cursor > 0) cursor--;
      return (
        state: state.copyWith(secretValue: buffer, askCursor: cursor),
        resolved: null,
      );
    case PromptArrowRight():
      if (cursor < buffer.length) cursor++;
      return (
        state: state.copyWith(secretValue: buffer, askCursor: cursor),
        resolved: null,
      );
    case PromptBackspace():
      if (cursor == 0 || buffer.isEmpty) {
        return (
          state: state.copyWith(secretValue: buffer, askCursor: cursor),
          resolved: null,
        );
      }
      final next = buffer.substring(0, cursor - 1) + buffer.substring(cursor);
      return (
        state: state.copyWith(secretValue: next, askCursor: cursor - 1),
        resolved: null,
      );
    case PromptChar():
      final ch = (key).text;
      final next = buffer.substring(0, cursor) + ch + buffer.substring(cursor);
      return (
        state: state.copyWith(secretValue: next, askCursor: cursor + 1),
        resolved: null,
      );
    case PromptEnter():
      // Empty buffer with options → revert to option selection instead of
      // cancelling (user entered free-text accidentally via space).
      if (buffer.isEmpty && spec.options.isNotEmpty) {
        final revertedMode = spec.multiSelect
            ? AskInputMode.multiSelect
            : AskInputMode.singleSelect;
        final reverted = state.copyWith(
          secretValue: '',
          askCursor: 0,
          askMode: revertedMode,
        );
        return (state: reverted, resolved: null);
      }
      final text = buffer.trim();
      if (text.isEmpty) {
        return (state: state, resolved: const TuiPromptCancelled());
      }
      if (text == '!') {
        return (state: state, resolved: const TuiPromptCancelled());
      }
      return (state: state, resolved: AskPromptAnswer(AskAnswer.text(text)));
    case PromptEscape():
      return (state: state, resolved: const TuiPromptCancelled());
    case PromptTab():
    case PromptArrowUp():
    case PromptArrowDown():
      return (state: state, resolved: null);
  }
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

({TuiPromptState state, TuiPromptAnswer? resolved}) _handleSecretKey(
  TuiPromptState state,
  PromptKey key,
) {
  switch (key) {
    case PromptArrowLeft():
      // -1 = name focus (no cursor motion in name field).
      if (state.secretCursor < 0) return (state: state, resolved: null);
      if (state.secretCursor > 0) {
        return (
          state: state.copyWith(secretCursor: state.secretCursor - 1),
          resolved: null,
        );
      }
      return (state: state, resolved: null);
    case PromptArrowRight():
      if (state.secretCursor < 0) return (state: state, resolved: null);
      if (state.secretCursor < state.secretValue.length) {
        return (
          state: state.copyWith(secretCursor: state.secretCursor + 1),
          resolved: null,
        );
      }
      return (state: state, resolved: null);
    case PromptBackspace():
      if (state.secretCursor < 0) {
        // Name focus: trim the last char from the name, if any.
        if (state.secretName.isEmpty) return (state: state, resolved: null);
        return (
          state: state.copyWith(
            secretName: state.secretName.substring(
              0,
              state.secretName.length - 1,
            ),
          ),
          resolved: null,
        );
      }
      if (state.secretCursor == 0 || state.secretValue.isEmpty) {
        return (state: state, resolved: null);
      }
      final next =
          state.secretValue.substring(0, state.secretCursor - 1) +
          state.secretValue.substring(state.secretCursor);
      return (
        state: state.copyWith(
          secretValue: next,
          secretCursor: state.secretCursor - 1,
        ),
        resolved: null,
      );
    case PromptChar():
      final ch = (key).text;
      if (state.secretCursor < 0) {
        // Name focus: append to the name.
        final next = state.secretName + ch;
        return (state: state.copyWith(secretName: next), resolved: null);
      }
      final next =
          state.secretValue.substring(0, state.secretCursor) +
          ch +
          state.secretValue.substring(state.secretCursor);
      return (
        state: state.copyWith(
          secretValue: next,
          secretCursor: state.secretCursor + 1,
        ),
        resolved: null,
      );
    case PromptEnter():
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
    case PromptTab():
      // Tab moves from name (-1) to value (0) focus.
      if (state.secretCursor < 0) {
        return (state: state.copyWith(secretCursor: 0), resolved: null);
      }
      return (state: state, resolved: null);
    case PromptEscape():
      return (state: state, resolved: const TuiPromptCancelled());
    case PromptArrowUp():
    case PromptArrowDown():
      return (state: state, resolved: null);
  }
}

// ---------------------------------------------------------------------------
// Approval
// ---------------------------------------------------------------------------

({TuiPromptState state, TuiPromptAnswer? resolved}) _handleApprovalKey(
  TuiPromptState state,
  PromptKey key,
) {
  switch (key) {
    case PromptChar():
      final ch = (key).text.toLowerCase();
      switch (ch) {
        case 'y':
          return (
            state: state,
            resolved: const ApprovalPromptAnswer(ApprovalDecision.approveOnce),
          );
        case 'a':
          return (
            state: state,
            resolved: const ApprovalPromptAnswer(
              ApprovalDecision.approveAlways,
            ),
          );
        case 'n':
          return (
            state: state,
            resolved: const ApprovalPromptAnswer(ApprovalDecision.deny),
          );
      }
      return (state: state, resolved: null);
    case PromptEnter():
      return (
        state: state,
        resolved: const ApprovalPromptAnswer(ApprovalDecision.deny),
      );
    case PromptEscape():
      return (
        state: state,
        resolved: const ApprovalPromptAnswer(ApprovalDecision.deny),
      );
    case PromptTab():
    case PromptArrowUp():
    case PromptArrowDown():
    case PromptArrowLeft():
    case PromptArrowRight():
    case PromptBackspace():
      return (state: state, resolved: null);
  }
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

({TuiPromptState state, TuiPromptAnswer? resolved}) _handleTextKey(
  TuiPromptState state,
  PromptKey key,
) {
  final spec = state.textSpec;
  var buffer = state.secretValue;
  var cursor = state.secretCursor;

  switch (key) {
    case PromptArrowLeft():
      if (cursor > 0) cursor--;
      return (
        state: state.copyWith(secretValue: buffer, secretCursor: cursor),
        resolved: null,
      );
    case PromptArrowRight():
      if (cursor < buffer.length) cursor++;
      return (
        state: state.copyWith(secretValue: buffer, secretCursor: cursor),
        resolved: null,
      );
    case PromptBackspace():
      if (cursor == 0 || buffer.isEmpty) {
        return (
          state: state.copyWith(secretValue: buffer, secretCursor: cursor),
          resolved: null,
        );
      }
      final next = buffer.substring(0, cursor - 1) + buffer.substring(cursor);
      return (
        state: state.copyWith(secretValue: next, secretCursor: cursor - 1),
        resolved: null,
      );
    case PromptChar():
      final ch = (key).text;
      final next = buffer.substring(0, cursor) + ch + buffer.substring(cursor);
      return (
        state: state.copyWith(secretValue: next, secretCursor: cursor + 1),
        resolved: null,
      );
    case PromptEnter():
      final text = buffer.trim();
      if (text.isEmpty) {
        final def = spec.defaultValue;
        return (state: state, resolved: TextPromptAnswer(def ?? ''));
      }
      return (state: state, resolved: TextPromptAnswer(text));
    case PromptEscape():
      return (state: state, resolved: const TuiPromptCancelled());
    case PromptTab():
    case PromptArrowUp():
    case PromptArrowDown():
      return (state: state, resolved: null);
  }
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

  final headerText = ' ${state.spec.header} ';
  final headerStyled = _accent(headerText);
  final headerVisible = headerText.length;
  final dashesAfter = (inner - headerVisible).clamp(0, inner);
  rows.add('┌─$headerStyled${'─' * dashesAfter}┐');

  rows.addAll(_bodyRows(state, inner));
  rows.add('├─${'─' * inner}┤');
  rows.addAll(_inputRows(state, inner, width));
  rows.add('└─${'─' * inner}┘');
  return rows;
}

List<String> _bodyRows(TuiPromptState state, int inner) {
  final spec = state.spec;
  final rows = <String>[];
  switch (spec) {
    case AskPromptSpec():
      final header =
          'Question ${spec.index + 1} of ${spec.total}'
          '${spec.options.isEmpty ? ' (free text)' : ''}';
      rows.add(_wrapBodyLine(header, inner, bold: true));
      for (final line in _wrapText(spec.question, inner)) {
        rows.add(_wrapBodyLine(line, inner));
      }
      rows.addAll(_askOptionRows(state, inner));
    case SecretPromptSpec():
      rows.add(_wrapBodyLine('Credential request', inner, bold: true));
      for (final line in _wrapText(spec.reason, inner)) {
        rows.add(_wrapBodyLine(line, inner));
      }
    case ApprovalPromptSpec():
      final req = spec.request;
      rows.add(_wrapBodyLine('Tool: ${req.toolName}', inner, bold: true));
      rows.add(_wrapBodyLine('Tier: ${req.tier.name}', inner));
      for (final line in _wrapText(req.reason, inner)) {
        rows.add(_wrapBodyLine(line, inner, dim: true));
      }
      final args = req.arguments.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(', ');
      final argLine = args.isEmpty ? '(no arguments)' : args;
      rows.add(_wrapBodyLine('Args: ${_fitWidth(argLine, inner - 6)}', inner));
    case TextPromptSpec():
      rows.add(_wrapBodyLine(spec.question, inner, bold: true));
      if (spec.defaultValue != null && spec.defaultValue!.isNotEmpty) {
        rows.add(
          _wrapBodyLine(
            _dim('(default: ${spec.defaultValue})'),
            inner,
            dim: true,
          ),
        );
      }
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
  final styled = bold
      ? _bold(content)
      : dim
      ? _dim(content)
      : content;
  return '│ $styled${' ' * (inner - content.length - 1)}│';
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
    final option = spec.options[i];
    final selected =
        i == state.askCursor && state.askMode != AskInputMode.freeText;
    final multiToggled = state.askSelected.contains(i);
    final marker = switch (state.askMode) {
      AskInputMode.multiSelect => multiToggled ? '◉' : '○',
      _ => selected ? '▸' : ' ',
    };
    final recommended = spec.recommended == i ? ' ★' : '';
    final labelLine = '${i + 1}. $marker ${option.label}$recommended';
    final description = option.description;
    if (description != null && description.isNotEmpty) {
      rows.add(
        _wrapBodyLine(_fitWidth(labelLine, inner), inner, dim: !selected),
      );
      for (final line in _wrapText('     $description', inner)) {
        rows.add(_wrapBodyLine(line, inner, dim: true));
      }
    } else {
      final styled = selected
          ? _accent(labelLine)
          : _fitWidth(labelLine, inner);
      rows.add('│ $styled${' ' * (inner - labelLine.length - 1)}│');
    }
  }
  return rows;
}

List<String> _inputRows(TuiPromptState state, int inner, int width) {
  return switch (state.spec) {
    AskPromptSpec() => _askInputRows(state, inner),
    SecretPromptSpec() => _secretInputRows(state, inner),
    ApprovalPromptSpec() => _approvalInputRows(inner),
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
    final (line, cursorCol) = _inputField(buffer, cursor, inner - 2);
    rows.add(
      '│ ${_accent2Plain('>')} ${_accent(line)}'
      '${' ' * (inner - 1 - line.length)}│',
    );
    rows.add(_wrapBodyLine(' ' * cursorCol + '█', inner, dim: true));
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
  final (line, cursorCol) = _inputField(display, cursor, inner - 2);
  rows.add(
    '│ ${_accent2Plain('>')} ${_accent(line)}'
    '${' ' * (inner - 1 - line.length)}│',
  );
  rows.add(_wrapBodyLine(' ' * cursorCol + '█', inner, dim: true));
  return rows;
}

List<String> _secretInputRows(TuiPromptState state, int inner) {
  final rows = <String>[];
  rows.add(
    _wrapBodyLine(
      _dim('Name (UPPER_SNAKE) — value is hidden:'),
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
  final dots = '•' * state.secretValue.length;
  rows.add(_wrapBodyLine(dots, inner, bold: true));
  if (!_secretNamePattern.hasMatch(state.secretName)) {
    rows.add(_wrapBodyLine(_red('Name must match ^[A-Z][A-Z0-9_]*\$'), inner));
  }
  return rows;
}

List<String> _approvalInputRows(int inner) {
  return [
    _wrapBodyLine(
      _dim('[y] once  [a] always  [n] deny  · Enter/Esc = deny'),
      inner,
      dim: true,
    ),
    _wrapBodyLine('', inner),
    _wrapBodyLine(_yellow('Awaiting decision…'), inner),
  ];
}

(String text, int cursorCol) _inputField(String buffer, int cursor, int avail) {
  if (avail <= 0) return ('', 0);
  if (buffer.length <= avail) {
    return (buffer, cursor);
  }
  final start = (cursor - avail ~/ 2).clamp(0, buffer.length - avail);
  return (buffer.substring(start, start + avail), cursor - start);
}
