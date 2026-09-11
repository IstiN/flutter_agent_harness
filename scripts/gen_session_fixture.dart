// Generates a deterministic JSONL session fixture for windowed-loading
// experiments (issue #135: 300 MB / 100k-record scale check).
//
// The file layout matches what the app writes: one `session` header line
// followed by `message` record lines chained by `parentId`, each ~3 KB of
// text so byte volume scales with record count.
//
// Usage:
//   dart run scripts/gen_session_fixture.dart --records 100000 \
//       --out /tmp/big-session.jsonl
//   dart run scripts/gen_session_fixture.dart --records 100000 \
//       --out /tmp/big-session.jsonl --measure
//
// `--measure` opens the file through WindowedSessionStorage and logs the
// AC numbers: open+tail latency, countRecords, resident bounds, and the
// cost of a few loadOlder pages.
import 'dart:io';

import 'package:flutter_agent_harness/src/env/io_execution_env.dart';
import 'package:flutter_agent_harness/src/session/windowed_session_storage.dart';

const _iso = '2026-01-01T00:00:00.000Z';

/// One 3 KB filler paragraph, chunked into content blocks.
final String _filler = () {
  final word = List.filled(96, 'lorem-ipsum-dolor-sit-amet').join(' ');
  return (word * 10).substring(0, 3 * 1024 - 130); // fits a ~3 KB line
}();

Future<void> main(List<String> args) async {
  int records = 100000;
  String out = '/tmp/big-session.jsonl';
  var measure = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? next = i + 1 < args.length ? args[i + 1] : null;
    if (next != null && next.startsWith('--')) next = null;
    if (arg.startsWith('--records=')) {
      records = int.parse(arg.substring('--records='.length));
    } else if (arg == '--records' && next != null) {
      records = int.parse(next);
      i++;
    } else if (arg.startsWith('--out=')) {
      out = arg.substring('--out='.length);
    } else if (arg == '--out' && next != null) {
      out = next;
      i++;
    } else if (arg == '--measure') {
      measure = true;
    } else {
      stderr.writeln('unknown arg: $arg');
      exitCode = 2;
      return;
    }
  }

  final sw = Stopwatch()..start();
  await _generate(out, records);
  final file = File(out);
  final mb = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
  stdout.writeln(
    'generated $records records, $mb MB, in '
    '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s -> $out',
  );

  if (measure) await _measure(out);
}

Future<void> _generate(String out, int records) async {
  final sink = File(out).openWrite();
  sink.write(
    '{"type":"session","version":3,"id":"fixture","timestamp":"$_iso",'
    '"cwd":"/work"}\n',
  );
  for (var i = 0; i < records; i++) {
    sink.write(
      '{"type":"message","id":"e$i","parentId":'
      '${i == 0 ? 'null' : '"e${i - 1}"'},"timestamp":"$_iso",'
      '"message":{"role":"${i.isEven ? 'user' : 'assistant'}","content":'
      '[{"type":"text","text":"message $i: $_filler"}]}}\n',
    );
  }
  await sink.flush();
  await sink.close();
}

Future<void> _measure(String out) async {
  final storage = await WindowedSessionStorage.open(LocalFileSystem(), out);

  var sw = Stopwatch()..start();
  final total = await storage.countRecords();
  stdout.writeln(
    'countRecords: $total records in '
    '${sw.elapsedMilliseconds}ms',
  );

  sw = Stopwatch()..start();
  final tail = await storage.getEntries();
  stdout.writeln(
    'open+tail: ${tail.length} resident records, '
    '${storage.residentWindowBytes ~/ 1024} KiB resident window, in '
    '${sw.elapsedMilliseconds}ms',
  );

  sw = Stopwatch()..start();
  var loaded = 0;
  for (var page = 0; page < 5; page++) {
    loaded += (await storage.loadOlder()).length;
  }
  stdout.writeln(
    'loadOlder x5: $loaded records joined in ${sw.elapsedMilliseconds}ms, '
    'resident now ${storage.residentCount} / '
    '${storage.residentWindowBytes ~/ 1024} KiB',
  );

  sw = Stopwatch()..start();
  final leaf = await storage.getLeafId();
  final path = leaf == null ? <String>[] : await storage.getPathToRoot(leaf);
  stdout.writeln(
    'getPathToRoot: ${path.length} records in ${sw.elapsedMilliseconds}ms',
  );
}

