// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/sandbox/shell_parser.dart';

/// The file redirects of one pipeline stage.
typedef StageRedirects = ({
  String? stdinFile,
  String? stdoutFile,
  String? stderrFile,
  bool appendStdout,
  bool appendStderr,
});

/// Classifies a stage's redirects (pure): `<` stdin, `>`/`>>`/`&>` stdout,
/// `2>`/`2>>` stderr. An fd of `-1` routes to stdout first, exactly as the
/// original if-chain did.
StageRedirects parseStageRedirects(List<Redirect> redirects) {
  String? stdoutFile;
  String? stderrFile;
  var appendStdout = false;
  var appendStderr = false;
  String? stdinFile;

  for (final redirect in redirects) {
    if (redirect.fd == 0 && redirect.kind == RedirectKind.read) {
      stdinFile = redirect.target;
    } else if (redirect.fd == 1 || redirect.fd == -1) {
      stdoutFile = redirect.target;
      appendStdout = redirect.kind == RedirectKind.append;
    } else if (redirect.fd == 2 || redirect.fd == -1) {
      stderrFile = redirect.target;
      appendStderr = redirect.kind == RedirectKind.append;
    }
  }
  return (
    stdinFile: stdinFile,
    stdoutFile: stdoutFile,
    stderrFile: stderrFile,
    appendStdout: appendStdout,
    appendStderr: appendStderr,
  );
}
