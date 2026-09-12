// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web implementation of the Office-host boot seam (issue #182).
///
/// The build flag (`--dart-define=FA_HOST=office`, set by
/// scripts/build_office_addin.sh when it bundles the app at outlook/app/)
/// is compile-time truth — the deployed pane bundle ALWAYS carries it, so
/// no runtime probe is needed. A missing/failed Office.js runtime is NOT a
/// detection concern: the [JsOfficeApi] facade surfaces it per call as the
/// clean 'office_unavailable' note, so the app still boots and answers
/// without mail tools (edge case E2).
///
/// Plain web/desktop builds (flag empty) resolve null — the app boots as
/// the normal web app with no outlook.* tools at all.
library;

import 'package:fa/services/relay/relay_probe.dart' show kFaBuildHost;
import 'package:fa_office_agent/fa_office_agent.dart'
    show createJsOfficeApi, OfficeApi;

/// The [OfficeApi] for this run, or null when not office-hosted.
OfficeApi? bootOfficeApi() {
  if (kFaBuildHost != 'office') return null;
  return createJsOfficeApi();
}
