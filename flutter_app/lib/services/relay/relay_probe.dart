// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Build-time host marker: `scripts/build_browser_ext.sh --with-app`
/// compiles the panel bundle with `--dart-define=FA_HOST=extension`, so an
/// extension-hosted app KNOWS its host without probing `chrome.*` through
/// js-interop (a probe that can lie or throw under dart2wasm). Plain
/// `flutter build web` leaves this empty.
library;

/// The raw `FA_HOST` define; empty outside the extension build.
const String kFaBuildHost = String.fromEnvironment('FA_HOST');

/// The relay hosting decision plus a human-readable reason — the reason is
/// what the boot log prints, so a misfiring detection is visible in the
/// in-app debug log instead of silently falling back to the local web
/// agent (the "no Chrome APIs" mystery).
final class RelayDecision {
  const RelayDecision(this.hosted, this.reason);

  /// True → the panel relay (SW-owned agent + browser tools) must serve.
  final bool hosted;

  /// Why — logged at boot either way.
  final String reason;
}

/// Decides whether this run is extension-hosted: the build flag wins
/// (compile-time truth), otherwise the [probe] (chrome.runtime.id check)
/// decides; a throwing probe degrades to plain web with the error in the
/// reason. Unknown flag values are ignored.
RelayDecision decideRelay({
  required String buildHost,
  required bool Function() probe,
}) {
  if (buildHost == 'extension') {
    return const RelayDecision(true, 'hosted by build flag FA_HOST=extension');
  }
  final bool probed;
  try {
    probed = probe();
  } on Object catch (error) {
    return RelayDecision(false, 'plain web: probe threw: $error');
  }
  return RelayDecision(
    probed,
    probed
        ? 'hosted by probe (chrome.runtime.id present)'
        : 'plain web: no FA_HOST flag, no chrome.runtime.id',
  );
}
