/// The guided `/dap` menu entries for the `hub` plugin's `/dap` command,
/// in picker (arrow-walk) order — STATE-DEPENDENT since issue #304 (AC7):
/// a stopped local hub leads with "Start DAP locally (one step)", a
/// running one swaps that row for "Stop DAP".
///
/// Lives in lib/ as pure data so the untagged structural test
/// (`test/cli/dap_menu_options_test.dart`) can pin keys/labels/order at
/// PR time WITHOUT importing `bin/fah_hub_plugin.dart` — a bin/ import
/// would pull the dart:io plugin into the default coverage run, where its
/// interactive flows show 0% coverage and trip the CRAP ratchet
/// (issue #129). `bin/fah_hub_plugin.dart` re-exports the builder for
/// the integration-tagged PTY tests.
library;

import '../plugins/plugin.dart';

/// The `/dap` menu for the current local-hub state: [hubRunning] swaps
/// the leading row between the one-step start (stopped) and the graceful
/// stop (running); every other row keeps its key and position so the
/// arrow-walk offsets for status/connect/secret/about never shift.
List<PluginMenuOption> dapMenuOptions({bool hubRunning = false}) {
  final lead = hubRunning
      ? (
          'stop',
          'Stop DAP',
          'graceful stop — names connected peers before disconnecting them',
        )
      : (
          'start',
          'Start DAP locally (one step)',
          'prompts the master key once, launches a local hub, connects',
        );
  return [
    lead,
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
  ];
}
