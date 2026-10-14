/// The modernize-scientific-stack__nwbgy7a evidence fixture, defined ONCE.
///
/// The FinalizeGate "grader parity" replay (gh-1605) lives in two layers:
/// the REG scenarios (`test/agent/finalize_gate_grader_parity_test.dart`)
/// write the fixture from Dart, and the IT replay
/// (`test/integration/fa_finalize_gate_test.dart`, IT-3) has the scripted
/// agent produce it via bash. Both must exercise the SAME evidence shape —
/// a produced entry point that resolves its dataset via the CWD and falls
/// back to a stale bundled table from any other directory — so the
/// dataset, the stale fallback and the awk aggregation are pinned here.
/// Adjusting the replay shape (e.g. a third divergence axis) means editing
/// this file, not the two consumers in lockstep.
library;

import 'dart:io';

/// The fixed dataset the trial's agent produced: Station 102's mean is
/// 30.3 — what the in-session run prints.
const nwbgy7aStationsCsv = 'station,temp\n101,-15.5\n102,30.3\n';

/// The stale bundled fallback: Station 102 collapsed to 15.5 — what the
/// verifier's clean-cwd run silently prints.
const nwbgy7aStationsCsvStale = 'station,temp\n101,-15.5\n102,15.5\n';

/// The evidence entry point: resolves its dataset via the CWD
/// (`[[ -f stations.csv ]]`) and falls back to the stale table next to
/// the script from anywhere else. Ends with a newline; embeds NO
/// interpolations — safe inside a quoted heredoc.
const nwbgy7aMeanSh = r'''#!/usr/bin/env bash
set -euo pipefail
if [[ -f stations.csv ]]; then
  data=stations.csv
else
  data="$(dirname "$0")/stations.csv.stale"
fi
awk -F, 'NR > 1 { sum[$1] += $2; n[$1]++ }
  END { for (s in sum) printf "Station %s mean temperature: %.1f C\n", s, sum[s]/n[s] }' "$data" | sort
''';

/// Shell `printf` writers for the two datasets — derived from the same
/// consts above, so the bash-produced fixture provably matches the
/// Dart-written one.
String _shellPrintf(String data, String target) =>
    "printf '${data.replaceAll('\n', r'\n')}' > $target";

final String nwbgy7aStationsCsvPrint = _shellPrintf(
  nwbgy7aStationsCsv,
  'stations.csv',
);
final String nwbgy7aStationsCsvStalePrint = _shellPrintf(
  nwbgy7aStationsCsvStale,
  'stations.csv.stale',
);

/// The REG layer's fixture writer: produces the full evidence shape under
/// [dir] (`stations.csv`, `stations.csv.stale`, `mean.sh`).
void writeNwbgy7aFixture(String dir) {
  File('$dir/stations.csv').writeAsStringSync(nwbgy7aStationsCsv);
  File('$dir/stations.csv.stale').writeAsStringSync(nwbgy7aStationsCsvStale);
  File('$dir/mean.sh').writeAsStringSync(nwbgy7aMeanSh);
}

/// The IT layer's turn-1 bash command: the scripted agent produces the
/// same fixture in its current directory (run it from the app directory —
/// `mkdir -p app && cd app &&` — to mirror the trial).
String nwbgy7aProduceCommand() => '$nwbgy7aStationsCsvPrint && '
    '$nwbgy7aStationsCsvStalePrint && '
    "cat > mean.sh <<'EOF'\n$nwbgy7aMeanSh"
    'EOF';
