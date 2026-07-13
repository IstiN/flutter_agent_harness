import 'package:flutter_agent/flutter_agent.dart';

/// Minimal example: cooperative cancellation with [CancelToken].
Future<void> main() async {
  final source = CancelTokenSource();

  // Simulate a long-running operation that honors cancellation.
  final worker = () async {
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      source.token.throwIfCancelled();
      print('tick $i');
    }
  }();

  // Cancel after 200ms.
  Future<void>.delayed(const Duration(milliseconds: 200), source.cancel);

  try {
    await worker;
  } on CancelledException {
    print('worker cancelled');
  }
}
