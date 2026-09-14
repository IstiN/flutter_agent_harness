/// UT for the `fa dap` local-hub pid/state file (issue #304): the pure
/// parse/render half of the state under `~/.dap/` that lets a second CLI
/// instance see "running" and attach, and `fa dap stop` find the owning
/// pid from either instance (E4).
library;

import 'package:flutter_agent_harness/src/hub/dap_local_hub_state.dart';
import 'package:test/test.dart';

void main() {
  group('dapHubPidFileFor', () {
    test('places the pid file under <home>/.dap', () {
      expect(
        dapHubPidFileFor('/home/u'),
        '/home/u/.dap/hub.pid',
      );
      expect(
        dapHubPidFileFor('/home/u/'),
        '/home/u/.dap/hub.pid',
      );
    });
  });

  group('parseDapLocalHubState', () {
    test('round-trips a rendered state', () {
      final state = (
        pid: 4242,
        port: 8787,
        startedAt: '2026-09-13T10:00:00Z',
      );
      final parsed = parseDapLocalHubState(
        renderDapLocalHubState(state),
      );
      expect(parsed, isNotNull);
      expect(parsed!.pid, 4242);
      expect(parsed.port, 8787);
      expect(parsed.startedAt, '2026-09-13T10:00:00Z');
    });

    test('null on missing, invalid or incomplete content (E4 no zombie)',
        () {
      expect(parseDapLocalHubState(null), isNull);
      expect(parseDapLocalHubState(''), isNull);
      expect(parseDapLocalHubState('not json'), isNull);
      expect(parseDapLocalHubState('{"port": 8787}'), isNull,
          reason: 'no pid — the file cannot name an owner');
      expect(parseDapLocalHubState('{"pid": 1}'), isNull,
          reason: 'no port — the file cannot name the hub');
      expect(parseDapLocalHubState('{"pid": "x", "port": 1}'), isNull);
      expect(parseDapLocalHubState('{"pid": -5, "port": 1}'), isNull,
          reason: 'a negative pid is not a process');
    });

    test('a missing startedAt defaults to empty, not a parse failure', () {
      final parsed = parseDapLocalHubState('{"pid": 9, "port": 8787}');
      expect(parsed, isNotNull);
      expect(parsed!.pid, 9);
      expect(parsed.startedAt, '');
    });
  });
}
