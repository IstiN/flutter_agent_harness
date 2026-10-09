import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

void main() {
  test('probe busy row bytes', () {
    final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');
    String line({String phase = '', required int elapsed, int frame = 1}) {
      var model = FaTuiModel(
        callbacks: FaTuiCallbacks(
          onSubmit: (_, {images = const []}) async {},
          onModelSelected: (_) async {},
          buildSlashMenu: (_) => const [],
          buildModelMenu: (_, _) => const [],
          statusLine: () => '',
          prompt: '',
        ),
        isExited: () => false,
        termWidth: 80,
      );
      model = model.update(const BusyMsg(true, source: 'run')).$1 as FaTuiModel;
      final now = DateTime.now().millisecondsSinceEpoch;
      model = model.copyWith(
        busyStartedAtMs: now - elapsed * 1000,
        busyLastEventMs: now,
        busyPhase: phase,
        kaomojiFace: frame,
      );
      return model
          .view()
          .content
          .split('\n')
          .map((l) => l.replaceAll(ansi, ''))
          .firstWhere((l) => l.contains('· run'))
          .trimRight();
    }

    // ignore: avoid_print
    print('A[${line(elapsed: 12)}]');
    // ignore: avoid_print
    print('B[${line(phase: 'Compacting context…', elapsed: 12)}]');
    // ignore: avoid_print
    print('C[${line(phase: 'Running bash…', elapsed: 30, frame: 0)}]');
  });
}
