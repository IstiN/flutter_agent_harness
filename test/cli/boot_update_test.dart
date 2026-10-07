// Unit tests for the `auto_update:` boot hook decision surface
// (issue #1377): the pure skip/selection rules + the once-per-process
// notify-banner guard. The engine itself (fetch/verify/swap/spawn) lives
// in the executable (`bin/self_manage.dart`) and is covered there.
library;

import 'package:flutter_agent_harness/src/cli/boot_update.dart';
import 'package:flutter_agent_harness/src/cli/cli_config.dart';
import 'package:test/test.dart';

void main() {
  group('bootUpdateAction', () {
    test('off selects no check at all', () {
      expect(
        bootUpdateAction(mode: AutoUpdateMode.off, serveOrDaemon: false),
        BootUpdateAction.none,
      );
    });

    test('notify selects the bounded notify check', () {
      expect(
        bootUpdateAction(mode: AutoUpdateMode.notify, serveOrDaemon: false),
        BootUpdateAction.notifyCheck,
      );
    });

    test('on selects apply + restart before boot', () {
      expect(
        bootUpdateAction(mode: AutoUpdateMode.on, serveOrDaemon: false),
        BootUpdateAction.applyAndExit,
      );
    });

    test('serve/wire-daemon runs never update, whatever the mode', () {
      // A daemon must not restart itself under connected clients.
      for (final mode in AutoUpdateMode.values) {
        expect(
          bootUpdateAction(mode: mode, serveOrDaemon: true),
          BootUpdateAction.none,
          reason: 'mode ${mode.name} must be skipped for daemons',
        );
      }
    });
  });

  group('AutoUpdateNotify', () {
    test('the banner fires once per process', () {
      final notify = AutoUpdateNotify();
      // The tag carries its own v prefix (release tags are `v0.1.44`).
      expect(
        notify.banner('v0.1.44'),
        'fa v0.1.44 available → run: fa update',
      );
      expect(
        notify.banner('v0.1.45'),
        isNull,
        reason: 'once per process — a later check must not re-banner',
      );
    });
  });
}
