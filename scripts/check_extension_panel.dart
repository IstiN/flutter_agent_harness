// Self-check for the browser extension panel: launches real Chrome in the
// new headless mode (extensions supported), opens the panel page, and reads
// its console through the DevTools Protocol — no manual relay needed.
//
// Usage (from the repo root):
//   CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
//     dart run scripts/check_extension_panel.dart [seconds]
//
// Exit code 0 = no fatal errors. CDN-CSP blocks (jsdelivr — the opt-in
// on-device LLM features) are reported but allowlisted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  final watchSecs = args.isNotEmpty ? int.tryParse(args[0]) ?? 10 : 10;
  final extDir = Directory('browser_ext').absolute.path;
  final ourId = extensionIdForPath(extDir);
  // Branded Google Chrome >= 137 silently ignores --load-extension; Chrome
  // for Testing still honours it. Auto-provision a CfT copy when needed.
  var chrome =
      Platform.environment['FA_TEST_CHROME'] ??
      Platform.environment['CHROME_PATH'] ??
      'google-chrome';
  if (Platform.environment['FA_TEST_CHROME'] == null &&
      await brandedIgnoresLoadExtension(chrome, extDir)) {
    chrome = await ensureChromeForTesting();
  }
  if (!File('$extDir/manifest.json').existsSync()) {
    stderr.writeln('run from the repo root: browser_ext/manifest.json missing');
    exit(2);
  }
  final panelUrl =
      'chrome-extension://${extensionIdForPath(extDir)}/panel/panel.html';
  final tmp = await Directory.systemTemp.createTemp('fa_ext_check');
  final wsUrlCompleter = Completer<String>();
  final proc = await Process.start(chrome, [
    '--headless=new',
    '--user-data-dir=${tmp.path}',
    '--load-extension=$extDir',
    '--remote-debugging-port=0',
    '--no-first-run',
    '--disable-gpu',
    'about:blank',
  ]);
  late final StreamSubscription<String> errSub;
  errSub = proc.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
        final m = RegExp(r'DevTools listening on (ws://\S+)').firstMatch(l);
        if (m != null && !wsUrlCompleter.isCompleted) {
          wsUrlCompleter.complete(m.group(1)!);
        }
      });
  final wsUrl = await wsUrlCompleter.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () => throw StateError('chrome devtools endpoint never came up'),
  );
  final ws = await WebSocket.connect(wsUrl);
  var msgId = 0;
  final pending = <int, Completer<Map<dynamic, dynamic>>>{};
  final errors = <String>[];
  final warnings = <String>[];
  var panelSession = '';
  late final StreamSubscription<dynamic> wsSub;
  wsSub = ws.listen((raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = msg['id'] as int?;
    if (id != null && pending.containsKey(id)) {
      pending
          .remove(id)!
          .complete(msg['result'] as Map<dynamic, dynamic>? ?? {});
      return;
    }
    if ((msg['sessionId'] as String?) != panelSession) return;
    final method = msg['method'] as String?;
    final params = (msg['params'] ?? {}) as Map<String, dynamic>;
    if (method == 'Log.entryAdded') {
      final e = params['entry'] as Map<String, dynamic>;
      final line =
          "[${e['level']}] ${e['source']} @${e['url']}:${e['lineNumber']}: ${e['text']}";
      (e['level'] == 'error' ? errors : warnings).add(line);
    } else if (method == 'Runtime.exceptionThrown') {
      final d = params['exceptionDetails'] as Map<String, dynamic>;
      errors.add('[exception] ${jsonEncode(d['exception'] ?? d)}');
    } else if (method == 'Runtime.consoleAPICalled' &&
        params['type'] == 'error') {
      final text = (params['args'] as List)
          .map((a) => (a as Map<String, dynamic>)['value'] ?? a['description'])
          .join(' ');
      errors.add('[console.error] $text');
    }
  });
  Future<Map<dynamic, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
    String? session,
  ]) {
    final id = ++msgId;
    final c = Completer<Map<dynamic, dynamic>>();
    pending[id] = c;
    ws.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': ?params,
        'sessionId': ?session,
      }),
    );
    return c.future;
  }

  // The unpacked id comes from a hash of the load path — don't recompute
  // it, read it off the extension's own background target.
  // The extension service worker can take a few seconds to register.
  Map<dynamic, dynamic> targets = {};
  var loaded = false;
  for (var attempt = 0; attempt < 20 && !loaded; attempt++) {
    targets = await send('Target.getTargets');
    loaded = (targets['targetInfos'] as List).any(
      (t) => ((t as Map)['url'] as String?)!.startsWith(
        'chrome-extension://$ourId/',
      ),
    );
    if (!loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  if (!loaded) {
    stderr.writeln(
      'FATAL: extension $ourId did not load under this chrome binary',
    );
    proc.kill();
    exit(3);
  }
  final realPanelUrl = panelUrl.replaceFirst(
    RegExp(r'chrome-extension://[a-p]+/'),
    'chrome-extension://$ourId/',
  );
  stderr.writeln('=== ext id: $ourId panel: $realPanelUrl');
  // Open the panel page and subscribe to its console.
  // Attach to the extension background to sanity-check the panel file.
  final bgTargets = (targets['targetInfos'] as List)
      .map((t) => t as Map)
      .where((t) => (t['url'] as String?)!.startsWith('chrome-extension://'))
      .toList();
  final bg = await send('Target.attachToTarget', {
    'targetId': bgTargets.first['targetId'],
    'flatten': true,
  });
  final bgSession = bg['sessionId'] as String;
  await send('Runtime.enable', null, bgSession);
  await Future<void>.delayed(const Duration(seconds: 1));
  final fetchProbe = await send('Runtime.evaluate', {
    'expression':
        "fetch(chrome.runtime.getURL('panel/panel.html')).then(r => r.status).catch(e => 'ERR ' + e)",
    'returnByValue': true,
    'awaitPromise': true,
  }, bgSession);
  stderr.writeln(
    '=== bg fetch panel.html: ${jsonEncode(fetchProbe['result'])}',
  );

  final target = await send('Target.createTarget', {'url': realPanelUrl});
  final attached = await send('Target.attachToTarget', {
    'targetId': target['targetId'],
    'flatten': true,
  });
  panelSession = attached['sessionId'] as String;
  await send('Runtime.enable', null, panelSession);
  await send('Log.enable', null, panelSession);
  await Future<void>.delayed(Duration(seconds: watchSecs));
  final probe = await send('Runtime.evaluate', {
    'expression':
        "location.href + ' | ready=' + document.readyState + ' | flutter=' + (typeof window._flutter !== 'undefined')",
    'returnByValue': true,
  }, panelSession);
  stderr.writeln('=== probe: ${jsonEncode(probe)}');

  final allow = RegExp(r'jsdelivr\.net|cdn\.jsdelivr');
  final fatal = errors.where(
    (e) => !allow.hasMatch(e) && !e.contains('is not defined'),
  );
  stderr.writeln('=== panel console over $watchSecs s ===');
  for (final e in errors) {
    stderr.writeln(e.length > 600 ? '${e.substring(0, 600)}…' : e);
  }
  stderr.writeln('--- warnings (non-fatal) ---');
  for (final w in warnings.take(8)) {
    stderr.writeln(w.length > 160 ? '${w.substring(0, 160)}…' : w);
  }
  stderr.writeln(
    'fatal=${fatal.length} cdnBlocked=${errors.length - fatal.length}',
  );
  wsSub.cancel();
  errSub.cancel();
  proc.kill();
  await tmp.delete(recursive: true).catchError((_) => tmp);
  exit(fatal.isEmpty ? 0 : 1);
}

/// The unpacked-extension id: SHA-256 of the manifest `key` (DER public
/// key) when present, else of the absolute load path — first 16 bytes,
/// hex digits mapped 0-9a-f → a-p.
String extensionIdForPath(String path) {
  final manifest =
      jsonDecode(File('$path/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final key = manifest['key'] as String?;
  final List<int> input = key != null ? base64Decode(key) : utf8.encode(path);
  final digest = sha256.convert(input).bytes;
  const letters = 'abcdefghijklmnop';
  return digest
      .take(16)
      .map((b) => letters[(b >> 4) & 0xf] + letters[b & 0xf])
      .join();
}

/// Returns true when the binary ignores --load-extension (our extension's
/// id never shows up among targets).
Future<bool> brandedIgnoresLoadExtension(String chrome, String extDir) async {
  final ourId = extensionIdForPath(extDir);
  final tmp = await Directory.systemTemp.createTemp('fa_ext_probe');
  final proc = await Process.start(chrome, [
    '--headless=new',
    '--user-data-dir=${tmp.path}',
    '--load-extension=$extDir',
    '--remote-debugging-port=0',
    '--no-first-run',
    'about:blank',
  ]);
  final out = await proc.stderr.transform(utf8.decoder).join();
  final m = RegExp(r'DevTools listening on (ws://\S+)').firstMatch(out);
  if (m == null) {
    proc.kill();
    await tmp.delete(recursive: true).catchError((_) => tmp);
    return false; // cannot tell; let the main flow report
  }
  final ws = await WebSocket.connect(m.group(1)!);
  final targets = Completer<String>();
  ws.listen((raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    if (msg['id'] == 1 && !targets.isCompleted) {
      targets.complete(jsonEncode(msg['result']));
    }
  });
  ws.add(jsonEncode({'id': 1, 'method': 'Target.getTargets'}));
  final body = await targets.future.timeout(const Duration(seconds: 10));
  ws.close();
  proc.kill();
  await tmp.delete(recursive: true).catchError((_) => tmp);
  return !body.contains(ourId);
}

/// Downloads (once) and returns the path of a Chrome-for-Testing binary.
Future<String> ensureChromeForTesting() async {
  final cache = Directory(
    '${Platform.environment['HOME']}/.cache/fa-chrome-for-testing',
  );
  final existing = await _findCftBinary(cache);
  if (existing != null) return existing;
  stderr.writeln('provisioning Chrome for Testing (one-time download)…');
  final client = HttpClient();
  final meta = await client
      .getUrl(
        Uri.parse(
          'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json',
        ),
      )
      .then((r) => r.close())
      .then((r) => r.transform(utf8.decoder).join());
  final json = jsonDecode(meta) as Map<String, dynamic>;
  final downloads =
      (((json['channels'] as Map)['Stable'] as Map)['downloads']
              as Map)['chrome']
          as List;
  final mac = downloads.firstWhere(
    (d) =>
        (d as Map)['platform'] == 'mac-arm64' &&
        (d['url'] as String).endsWith('.zip'),
  );
  final url = (mac as Map)['url'] as String;
  final zipPath = '${cache.path}/cft.zip';
  await cache.create(recursive: true);
  await client
      .getUrl(Uri.parse(url))
      .then((r) => r.close())
      .then((r) => r.pipe(File(zipPath).openWrite()));
  await Process.run('unzip', ['-q', zipPath, '-d', cache.path]);
  File(zipPath).deleteSync();
  final bin = await _findCftBinary(cache);
  if (bin == null) {
    throw StateError('Chrome for Testing downloaded but binary not found');
  }
  await Process.run('xattr', ['-dr', 'com.apple.quarantine', bin]);
  return bin;
}

Future<String?> _findCftBinary(Directory cache) async {
  if (!cache.existsSync()) return null;
  await for (final e in cache.list(recursive: true, followLinks: false)) {
    if (e.path.endsWith(
      '/chrome-mac-arm64/Google Chrome for Testing.app/'
      'Contents/MacOS/Google Chrome for Testing',
    )) {
      return e.path;
    }
  }
  return null;
}
