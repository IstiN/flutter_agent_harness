// End-to-end typing-latency repro for issue #43.
//
// Spawns the REAL `dart bin/fah.dart` REPL in a PTY against a local mock
// endpoint that streams `reasoning_content` deltas at a controlled rate
// (the "a lot of agent thoughts" scenario), types a key every 150ms, and
// measures how long each key takes to become visible in the PTY output.
//
// Usage: dart run tool/tui_e2e_typing_repro.dart [--deltas-per-sec N]
//        [--seconds N] [--delta-chars N]
import 'package:vm_service/vm_service.dart' as vms;
import 'package:vm_service/vm_service_io.dart' as vms_io;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

Future<void> main(List<String> args) async {
  int opt(String name, int def) {
    final i = args.indexOf('--$name');
    return i >= 0 ? int.parse(args[i + 1]) : def;
  }

  final deltasPerSec = opt('deltas-per-sec', 100);
  final seconds = opt('seconds', 20);
  final deltaChars = opt('delta-chars', 60);

  // ── Mock endpoint: slow reasoning_content stream ────────────────────────
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  server.listen((request) async {
    final path = request.uri.path;
    if (request.method == 'GET' && path.endsWith('/models')) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'object': 'list',
          'data': [
            {'id': 'mock-model', 'object': 'model'},
          ],
        }),
      );
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && path.endsWith('/chat/completions')) {
      await utf8.decoder.bind(request).drain();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final words = List.generate(24, (i) => 'word$i');
      var wi = 0;
      final interval = Duration(microseconds: 1000000 ~/ deltasPerSec);
      final nDeltas = deltasPerSec * seconds;
      for (var i = 0; i < nDeltas; i++) {
        var text = '';
        for (var c = 0; c < deltaChars ~/ 7; c++) {
          text += '${words[wi++ % words.length]} ';
        }
        final chunk = {
          'id': 'chatcmpl-mock',
          'object': 'chat.completion.chunk',
          'model': 'mock-model',
          'choices': [
            {
              'index': 0,
              'delta': {'reasoning_content': text},
              'finish_reason': null,
            },
          ],
        };
        request.response.write('data: ${jsonEncode(chunk)}\n\n');
        await request.response.flush();
        await Future<void>.delayed(interval);
      }
      const done = {
        'id': 'chatcmpl-mock',
        'object': 'chat.completion.chunk',
        'model': 'mock-model',
        'choices': [
          {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
        ],
      };
      request.response.write('data: ${jsonEncode(done)}\n\n');
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  });

  // ── Temp HOME with the mock provider wired ──────────────────────────────
  final tmpHome = await Directory.systemTemp.createTemp('fa43_repro');
  final fahDir = Directory('${tmpHome.path}/.fah')..createSync(recursive: true);
  File('${fahDir.path}/config.yaml').writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: http://127.0.0.1:$port/v1
approvalMode: yolo
''');

  // ── PTY spawn of the real CLI ────────────────────────────────────────────
  const columns = 120;
  const rows = 40;
  final pty = await PseudoTerminal.start(
    'dart',
    [
      if (Platform.environment['FA43_OBSERVE'] != null) ...[
        '--disable-service-auth-codes',
        '--profiler',
        '--observe=${Platform.environment['FA43_OBSERVE']}',
      ],
      'bin/fah.dart',
    ],
    workingDirectory: Directory.current.path,
    environment: {
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'HOME': tmpHome.path,
      'OPENAI_API_KEY': 'sk-mock',
      'PATH': Platform.environment['PATH'] ?? '',
      if (Platform.environment['PUB_CACHE'] != null)
        'PUB_CACHE': Platform.environment['PUB_CACHE']!,
      if (Platform.environment['FA_TUI_TRACE'] != null)
        'FA_TUI_TRACE': Platform.environment['FA_TUI_TRACE']!,
    },
    raw: true,
  );
  pty.resize(columns, rows);
  final terminal = Terminal(maxLines: rows * 4);
  terminal.resize(columns, rows);
  terminal.onOutput = pty.write; // answer terminal capability queries

  var outBytes = 0;
  final echoes = <int>[]; // microseconds per key
  final pending = <String, int>{};
  // Sentinels absent from the mock stream and UI chrome.
  const sentinels = ['@', '#', r'$', '%', '^', '&', '+', '=', '~'];
  final bootBuf = StringBuffer();
  final outSub = pty.out.listen((text) {
    bootBuf.write(text);
    outBytes += text.length;
    for (final s in sentinels) {
      if (pending.containsKey(s) && text.contains(s)) {
        echoes.add(DateTime.now().microsecondsSinceEpoch - pending[s]!);
        pending.remove(s);
      }
    }
  });

  // Boot: wait for the banner's model line via raw output accumulation.
  final bootDeadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(bootDeadline)) {
    if (bootBuf.toString().contains('mock-model')) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (!bootBuf.toString().contains('mock-model')) {
    final raw = bootBuf.toString();
    stderr.writeln('BOOT FAILED. Raw tail:');
    stderr.writeln(raw.substring(raw.length > 3000 ? raw.length - 3000 : 0));
    exit(2);
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // Submit a prompt (the mock ignores content).
  pty.write('hi');
  await Future<void>.delayed(const Duration(milliseconds: 200));
  pty.write('\r');
  // Let the run start (thinking begins).
  await Future<void>.delayed(const Duration(milliseconds: 1500));

  // Type sentinels while the stream floods; one outstanding key at a time
  // per sentinel char keeps the echo attribution unambiguous.
  final typing = Timer.periodic(const Duration(milliseconds: 150), (_) {
    for (final s in sentinels) {
      if (!pending.containsKey(s)) {
        pending[s] = DateTime.now().microsecondsSinceEpoch;
        pty.write(s);
        return;
      }
    }
  });

  // Optional mid-flood CPU sampling via the VM service (FA43_OBSERVE=port).
  final observe = Platform.environment['FA43_OBSERVE'];
  if (observe != null) {
    try {
      vms.VmService? vm;
      for (var attempt = 0; attempt < 20 && vm == null; attempt++) {
        try {
          vm = await vms_io.vmServiceConnectUri('ws://127.0.0.1:$observe/ws');
        } on Object {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      if (vm == null) throw StateError('vm service unreachable');
      final isolateId = (await vm.getVM()).isolates!.first.id!;
      await Future<void>.delayed(const Duration(seconds: 8));
      final t1 = DateTime.now().millisecondsSinceEpoch;
      await Future<void>.delayed(const Duration(seconds: 5));
      final t2 = DateTime.now().millisecondsSinceEpoch;
      final samples = await vm.getCpuSamples(isolateId, t1 * 1000, t2 * 1000);
      final leafTicks = <String, int>{};
      final funcs = {for (final f in samples.functions!) f: f};
      String nameOf(vms.ProfileFunction f) {
        final fn = f.function;
        return fn is vms.FuncRef
            ? '${f.resolvedUrl}:${fn.name ?? '?'}'
            : '${f.resolvedUrl}:${fn.runtimeType}';
      }

      for (final s in samples.samples!) {
        if (s.stack == null || s.stack!.isEmpty) continue;
        final name = nameOf(funcs[s.stack!.last]!);
        leafTicks[name] = (leafTicks[name] ?? 0) + 1;
      }
      final top = leafTicks.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final total = top.fold<int>(0, (a, e) => a + e.value);
      stdout.writeln('--- CPU leaf top (ticks over 5s window) ---');
      for (final e in top.take(18)) {
        stdout.writeln(
          '${(100 * e.value / (total == 0 ? 1 : total)).toStringAsFixed(1)}% '
          '${e.key}',
        );
      }
      await vm.dispose();
    } on Object catch (e) {
      stdout.writeln('CPU sampling failed: $e');
    }
  }

  await Future<void>.delayed(Duration(seconds: (seconds - 13).clamp(0, 3600)));
  typing.cancel();
  outSub.cancel();
  pty.kill();
  await pty.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  server.close(force: true);
  await tmpHome.delete(recursive: true);

  final sorted = List<int>.of(echoes)..sort();
  int pct(double p) =>
      sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).floor()];
  final mean = sorted.isEmpty
      ? 0
      : sorted.reduce((a, b) => a + b) ~/ sorted.length;
  stdout.writeln(
    'E2E repro: $deltasPerSec/s x ${deltaChars}chars, ${seconds}s, ${columns}x$rows',
  );
  stdout.writeln(
    'keys echoed=${sorted.length} ptyBytes=$outBytes '
    '(${(outBytes / (seconds + 3) / 1024).toStringAsFixed(1)} KiB/s)',
  );
  stdout.writeln(
    'echo ms: p50=${pct(0.5) / 1000} p90=${pct(0.9) / 1000} '
    'p99=${pct(0.99) / 1000} max=${pct(1) / 1000} mean=${mean / 1000}',
  );
  exit(0);
}
