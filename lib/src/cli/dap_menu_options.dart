/// The guided `/dap` menu entries for the `hub` plugin's `/dap` command,
/// in picker (arrow-walk) order.
///
/// Lives in lib/ as pure data so the untagged structural test
/// (`test/cli/dap_menu_options_test.dart`) can pin keys/labels/order at
/// PR time WITHOUT importing `bin/fah_hub_plugin.dart` — a bin/ import
/// would pull the dart:io plugin into the default coverage run, where its
/// interactive flows show 0% coverage and trip the CRAP ratchet
/// (issue #129). `bin/fah_hub_plugin.dart` re-exports the constant for
/// the integration-tagged PTY tests.
library;

import '../plugins/plugin.dart';

/// The `/dap` menu: keys drive the plugin's switch dispatch, labels are
/// what the TUI renders, descriptions are the dim hint line.
const dapMenuOptions = <PluginMenuOption>[
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
];
