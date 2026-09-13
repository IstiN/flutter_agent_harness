/// Structural contract of the guided `/dap` menu (issue #304 AC7): the
/// menu is STATE-DEPENDENT — a stopped local hub leads with
/// "Start DAP locally (one step)", a running one with "Stop DAP". The PTY
/// tests in `test/integration/dap_tui_menu_test.dart` derive their
/// arrow-walk offsets from these lists, so ANY change here must update
/// that test in the same PR.
///
/// Imports ONLY the lib/ builder — never `bin/fah_hub_plugin.dart`,
/// whose import would drag the dart:io plugin into this default-suite
/// coverage run (0% on its interactive flows) and trip the CRAP ratchet.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/dap_menu_options.dart';
import 'package:test/test.dart';

void main() {
  test('stopped hub: leads with the one-step start (AC7)', () {
    final stopped = dapMenuOptions(hubRunning: false);
    expect(
      stopped,
      const <PluginMenuOption>[
        (
          'start',
          'Start DAP locally (one step)',
          'prompts the master key once, launches a local hub, connects',
        ),
        (
          'status',
          'Connection status',
          'agent id, display name, hub url, joined channels',
        ),
        (
          'connect',
          'Connect to a hub…',
          'enter a host, optional display name and channel',
        ),
        (
          'secret',
          'Set master secret…',
          'masked input — enables DAP for this session',
        ),
        (
          'about',
          'What is DAP?',
          'a short explainer of the hub, channels and secrets',
        ),
      ],
      reason:
          'the /dap menu drives the arrow-walk in dap_tui_menu_test.dart — '
          'an insertion/removal/retitle must update that test deliberately, '
          'never shift offsets silently',
    );
  });

  test('running hub: the first row becomes Stop DAP (AC7)', () {
    final running = dapMenuOptions(hubRunning: true);
    expect(running.first.$1, 'stop');
    expect(running.first.$2, 'Stop DAP');
    expect(running.first.$3, isNotEmpty);
    // The remaining rows keep their keys and order — the arrow-walk for
    // status/connect/secret/about is unchanged by hub state.
    expect(
      [for (final o in running.skip(1)) o.$1],
      ['status', 'connect', 'secret', 'about'],
    );
  });

  test('the menu has exactly one of start/stop in the first slot', () {
    for (final running in [false, true]) {
      final keys = [
        for (final o in dapMenuOptions(hubRunning: running)) o.$1,
      ];
      expect(keys.contains('start') && keys.contains('stop'), isFalse,
          reason: 'running=$running: start and stop are mutually exclusive');
      expect(keys.first, running ? 'stop' : 'start');
    }
  });

  test('default (no arg) is the stopped shape — backward compatible', () {
    expect(dapMenuOptions().first.$1, 'start');
  });
}
