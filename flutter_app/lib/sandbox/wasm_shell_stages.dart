// Stage helpers for WasiSandboxShell (gh-1232: extracted from
// wasm_shell.dart so the primary file stays under the 2800-line guard).
//
// The expr evaluator, per-stage stdio state, stage result record and the
// redirect-write error all moved here verbatim — same library scope.

part of 'wasm_shell.dart';


/// Precedence-climbing evaluator for `expr` integer arithmetic:
/// `*`/`/`/`%` bind tighter than `+`/`-`, comparisons loosest. Throws
/// [FormatException] with GNU-expr-shaped messages on malformed input.
final class _ExprEvaluator {
  _ExprEvaluator(this._args);

  final List<String> _args;
  var _pos = 0;

  String evaluate() {
    final left = _parseSum();
    if (_pos >= _args.length) return '$left';
    return _compare(left);
  }

  /// At most one trailing comparison; anything after the right operand is
  /// a syntax error.
  String _compare(int left) {
    const comparisons = {'=', '!=', '<', '<=', '>', '>='};
    final op = _args[_pos++];
    if (!comparisons.contains(op)) {
      throw FormatException('syntax error: $op');
    }
    final right = _parseSum();
    if (_pos != _args.length) throw const FormatException('syntax error');
    final result = switch (op) {
      '=' => left == right,
      '!=' => left != right,
      '<' => left < right,
      '<=' => left <= right,
      '>' => left > right,
      '>=' => left >= right,
      _ => false,
    };
    return result ? '1' : '0';
  }

  int _parseValue() {
    if (_pos >= _args.length) throw const FormatException('syntax error');
    final value = int.tryParse(_args[_pos]);
    if (value == null) {
      throw FormatException('non-integer argument: ${_args[_pos]}');
    }
    _pos++;
    return value;
  }

  int _parseTerm() {
    var value = _parseValue();
    while (_pos < _args.length && _isMulOp(_args[_pos])) {
      value = _applyMul(value, _args[_pos++], _parseValue());
    }
    return value;
  }

  int _parseSum() {
    var value = _parseTerm();
    while (_pos < _args.length && _isAddOp(_args[_pos])) {
      final op = _args[_pos++];
      value = op == '+' ? value + _parseTerm() : value - _parseTerm();
    }
    return value;
  }

  static bool _isMulOp(String op) => op == '*' || op == '/' || op == '%';

  static bool _isAddOp(String op) => op == '+' || op == '-';

  /// `*` never divides; `/` and `%` reject a zero right operand like GNU
  /// expr.
  int _applyMul(int value, String op, int rhs) {
    if (op == '*') return value * rhs;
    if (rhs == 0) throw const FormatException('division by zero');
    return op == '/' ? value ~/ rhs : value % rhs;
  }
}

/// Mutable stdio state for one running WASM stage: captured bytes, the
/// first callback failure, and derived flags for outcome resolution.
final class _StageIo {
  final stdoutBuffer = <int>[];
  final stderrBuffer = <int>[];
  ExecutionError? callbackError;

  /// Stream-closed markers (issue #1156 review): the drain can skip its
  /// quiet window entirely once both stdio streams are done — the common
  /// fast-exit-guest case.
  bool stdoutDone = false;
  bool stderrDone = false;

  bool get hasOutput => stdoutBuffer.isNotEmpty || stderrBuffer.isNotEmpty;

  /// Appends a raw chunk and mirrors it to the caller callback; callback
  /// failures are recorded (first one wins) instead of breaking the pump.
  void collect(
    List<int> target,
    Uint8List chunk,
    void Function(String)? callback,
  ) {
    target.addAll(chunk);
    if (callback == null) return;
    try {
      callback(utf8.decode(chunk, allowMalformed: true));
    } on Object catch (error) {
      callbackError ??= ExecutionError(
        ExecutionErrorCode.callbackError,
        error.toString(),
        cause: error,
      );
    }
  }
}

final class StageResult {
  const StageResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
  final List<int> stdout;
  final List<int> stderr;
  final int exitCode;
}

/// A redirect-target write failure, already sanitized to sandbox terms:
/// [message] is the full stderr line in sh's shape (`sh: /ro_dir/f.txt:
/// Permission denied`) and never contains a host path.
final class _RedirectWriteError implements Exception {
  _RedirectWriteError(this.sandboxPath, String sanitized) {
    // The OS short phrase (`Permission denied`) when present, else the
    // whole sanitized message.
    final phrase = RegExp('OS Error: ([^,]+)').firstMatch(sanitized)?.group(1);
    message = 'sh: $sandboxPath: ${(phrase ?? sanitized).trim()}\n';
  }

  final String sandboxPath;
  late final String message;

  @override
  String toString() => message;
}
