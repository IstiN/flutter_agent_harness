/// Settled-memory probe for the app test suites (issue #1850 AC4/AC5).
///
/// The GC stream's per-test `oldGrowthMb` deltas double-count promoted
/// garbage that a later full collection reclaims — per-file "old-space
/// growth" numbers are dominated by that smear, not by real retention.
/// This probe measures the truth instead: force a full GC at suite end
/// and record the per-class LIVE set (`bytesCurrent`).
///
/// It is inert in normal runs: `dart:developer`'s [dev.Service.getInfo]
/// returns a null server URI whenever the VM service is disabled (the
/// default for `flutter test`). The measurement workflow in
/// `docs/memory-churn.md` enables the service with
/// `flutter test --start-paused` (and unblocks the paused tester with a
/// one-shot VM service client), at which point [settleMemoryProbe]
/// writes `../.bench/settled_<tag>.json` and holds the tester for 60 s.
///
/// Usage inside a suite's `main()`:
///
/// ```dart
/// tearDownAll(() => settleMemoryProbe('my_suite'));
/// ```
library;

import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:vm_service/vm_service.dart' as vs;
import 'package:vm_service/vm_service_io.dart' as vsio;

/// Where the probe writes, relative to the flutter_app working directory.
const settledProbeOutputDir = '../.bench';

/// Force a full GC and write the per-class live set to
/// `$settledProbeOutputDir/settled_[tag].json`. No-op when the VM service
/// is off (plain `flutter test`), so suites can call it unconditionally.
///
/// After the snapshot the isolate idles for 60 s so an external client
/// (the measurement workflow's resume client) can take its own snapshot.
Future<void> settleMemoryProbe(String tag) async {
  final info = await dev.Service.getInfo();
  final uri = info.serverUri;
  if (uri == null) return; // plain pass: service disabled
  final vm = await vsio.vmServiceConnectUri(
    uri.toString().replaceFirst('http://', 'ws://'),
  );
  final vm0 = await vm.getVM();
  final iso = vm0.isolates!.first;
  await vm.getAllocationProfile(iso.id!, gc: true);
  final profile = await vm.getAllocationProfile(iso.id!);
  final rows = (profile.members ?? <vs.ClassHeapStats>[])
      .map((m) => {
            'class': m.classRef?.name ?? '?',
            'lib': m.classRef?.library?.uri ?? '',
            'liveBytes': m.bytesCurrent,
            'liveInstances': m.instancesCurrent,
          })
      .toList()
    ..sort((a, b) =>
        ((b['liveBytes'] ?? 0) as int).compareTo((a['liveBytes'] ?? 0) as int));
  final total =
      rows.fold<int>(0, (s, r) => s + ((r['liveBytes'] ?? 0) as int));
  Directory(settledProbeOutputDir).createSync(recursive: true);
  File('$settledProbeOutputDir/settled_$tag.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'totalLiveBytes': total,
      'top': rows.take(80).toList(),
    }),
  );
  // Keep the tester alive so the external client can also snapshot.
  await Future<void>.delayed(const Duration(seconds: 60));
}
