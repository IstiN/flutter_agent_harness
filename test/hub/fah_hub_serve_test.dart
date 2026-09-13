/// UT for `fa hub serve`'s graceful-termination signal wiring (the
/// Windows startup fix): `ProcessSignal.sigterm.watch()` is "Not
/// available on Windows" (dart:io docs) — listening there raises
/// `SignalException` as an unhandled stream error that kills the hub
/// mid-serve. The wiring must watch SIGTERM POSIX-only and keep SIGINT
/// (Ctrl-C) everywhere. `sigtermWatchable` pins the platform shape so
/// the Windows path runs on any OS.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../../bin/fah_hub_serve.dart';

void main() {
  group('watchHubTerminateSignals (Windows SIGTERM guard)', () {
    Future<void> cancelAll(List<StreamSubscription> subs) async {
      for (final sub in subs) {
        await sub.cancel();
      }
    }

    test(
      'host without SIGTERM (the Windows shape): SIGINT only, no throw',
      () async {
        // Before the fix this shape died: the sigterm watch raised
        // SignalException as an unhandled stream error. Pinning the
        // non-sigterm shape must wire exactly one subscription — the
        // Ctrl-C path — and never touch the SIGTERM stream.
        final fired = <String>[];
        final subs = watchHubTerminateSignals(
          () => fired.add('terminate'),
          sigtermWatchable: false,
        );
        addTearDown(() => cancelAll(subs));
        expect(subs, hasLength(1), reason: 'SIGINT only; no SIGTERM watch');
      },
    );

    test('default guard matches the host (POSIX: SIGTERM + SIGINT)', () async {
      final subs = watchHubTerminateSignals(() {});
      addTearDown(() => cancelAll(subs));
      expect(
        subs,
        hasLength((Platform.isLinux || Platform.isMacOS) ? 2 : 1),
        reason:
            'POSIX hosts watch SIGTERM and SIGINT; a host without '
            'SIGTERM support (Windows) watches SIGINT only',
      );
    });
  });
}
