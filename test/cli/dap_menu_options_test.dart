/// Structural contract of the guided `/dap` menu (`dapMenuOptions` in
/// `lib/src/cli/dap_menu_options.dart`): the PTY tests in
/// `test/integration/dap_tui_menu_test.dart` derive their arrow-walk
/// offsets and visible-label assertions from this list, so ANY change
/// here — an inserted, removed, or retitled entry — must update that test
/// in the same PR. Deliberately untagged: it runs in the default suite at
/// PR time, while the PTY tests are `integration`-gated and would only
/// surface a menu shift at tag time (issues #107/#108/#129).
///
/// Imports ONLY the lib/ constant — never `bin/fah_hub_plugin.dart`,
/// whose import would drag the dart:io plugin into this default-suite
/// coverage run (0% on its interactive flows) and trip the CRAP ratchet.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/dap_menu_options.dart';
import 'package:test/test.dart';

void main() {
  test('dapMenuOptions: keys, labels and order are structural', () {
    expect(
      dapMenuOptions,
      const <PluginMenuOption>[
        (
          'start',
          'Start DAP locally (one step)',
          'generates a session secret if needed, launches a local hub, connects',
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
          'the /dap menu drives the arrow-walk in '
          'dap_tui_menu_test.dart — an insertion/removal/retitle must '
          'update that test deliberately, never shift offsets silently',
    );
  });
}
