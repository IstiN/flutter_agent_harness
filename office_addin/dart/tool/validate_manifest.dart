import 'dart:io';
import '../src/manifest.dart';

void main(List<String> args) {
  final dev = args.contains('--dev');
  final paths = args.where((a) => a != '--dev').toList();
  if (paths.length != 1) {
    stderr.writeln(
      'usage: dart run tool/validate_manifest.dart <manifest.xml> [--dev]',
    );
    exit(2);
  }
  final report = validateOutlookManifest(
    File(paths.single).readAsStringSync(),
    dev: dev,
  );
  for (final issue in report.issues) {
    stderr.writeln('issue: $issue');
  }
  stdout.writeln(
    report.ok
        ? 'manifest OK'
        : 'manifest INVALID (${report.issues.length} issue(s))',
  );
  exit(report.ok ? 0 : 1);
}
