// Headless Chrome driver for the browser-extension integration suite
// (issue #23 G5 acceptance tests): spawns Chrome with the unpacked
// browser_ext/ extension, parses the DevTools endpoint from stderr, and
// speaks raw CDP over a dart:io WebSocket — hand-rolled id-correlated
// frames instead of a puppeteer dependency.
//
// NO CHROME, NO TEST: every test file goes through [HeadlessChrome.launch],
// which fails LOUDLY (ChromeLaunchException with the binary list and the
// captured stderr) when Chrome is missing or exits early. There is
// deliberately no silent skip — a machine without Chrome must fail, and the
// `integration` tag keeps the suite out of default `dart test` runs.
//
// Local runs: bash scripts/build_browser_ext.sh first (sw/agent.js is a
// build artifact); CI installs Chrome via browser-actions/setup-chrome and
// exports CHROME_PATH.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Chrome is missing, never printed a DevTools endpoint, or died during
/// startup. [stderr] carries everything Chrome printed before dying.
final class ChromeLaunchException implements Exception {
  ChromeLaunchException(this.message, this.stderr);

  final String message;
  final String stderr;

  @override
  String toString() =>
      'ChromeLaunchException: $message\n--- chrome stderr ---\n'
      '$stderr\n----------------------';
}

/// A CDP command/response error (`error` frame on a send).
final class CdpException implements Exception {
  CdpException(this.method, this.message);

  final String method;
  final String message;

  @override
  String toString() => 'CdpException($method): $message';
}

/// One flattened CDP session (attached to a page or service-worker target).
/// Collects console errors and uncaught exceptions while enabled.
final class CdpSession {
  CdpSession._(this._chrome, this.sessionId);

  final HeadlessChrome _chrome;
  final String sessionId;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Set for extension-SW sessions: re-wakes the worker and returns a
  /// fresh session when this one's target vanished (MV3 workers idle out
  /// whenever Chrome feels like it, killing every attached session).
  Future<CdpSession> Function()? revive;

  /// Captured `Runtime.consoleAPICalled` (type error) messages and
  /// `Runtime.exceptionThrown` details, filled after [enableErrorCapture].
  final consoleErrors = <String>[];
  final exceptions = <String>[];

  /// CDP events for this target (already routed by sessionId).
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]) => _chrome._command(sessionId, method, params);

  /// Runtime.enable + Log.enable and start recording errors/exceptions.
  /// Enable BEFORE the activity under test so boot noise is not missed.
  Future<void> enableErrorCapture() async {
    await send('Runtime.enable');
    await send('Log.enable');
    unawaited(
      events.forEach((event) {
        switch (event['method']) {
          case 'Runtime.consoleAPICalled':
            final call = event['params'] as Map<String, dynamic>;
            if (call['type'] != 'error') return;
            consoleErrors.add(
              (call['args'] as List? ?? const [])
                  .map((a) => a['value'] ?? a['description'] ?? '')
                  .join(' '),
            );
          case 'Runtime.exceptionThrown':
            final detail =
                (event['params'] as Map<String, dynamic>)['exceptionDetails']
                    as Map<String, dynamic>;
            final exception = detail['exception'] as Map<String, dynamic>?;
            exceptions.add(
              '${detail['text']} ${exception?['description'] ?? ''}'.trim(),
            );
          case 'Log.entryAdded':
            final entry =
                (event['params'] as Map<String, dynamic>)['entry']
                    as Map<String, dynamic>;
            if (entry['level'] == 'error') {
              consoleErrors.add('${entry['text']}');
            }
        }
      }),
    );
  }

  /// Runtime.evaluate with returnByValue → the unwrapped Dart value.
  /// Throws [CdpException] on a JS exception or a non-zero `wasThrown`.
  /// One automatic retry through [revive] when the worker died between calls
  /// ("Session with given id not found" — the MV3 idle shutdown).
  Future<dynamic> evaluate(
    String expression, {
    bool awaitPromise = false,
  }) async {
    try {
      return await _evaluateRaw(expression, awaitPromise: awaitPromise);
    } on CdpException catch (e) {
      final fresh = revive;
      if (fresh == null || !_deadSessionMessage(e.message)) rethrow;
      return (await fresh())._evaluateRaw(
        expression,
        awaitPromise: awaitPromise,
      );
    }
  }

  static bool _deadSessionMessage(String message) =>
      message.contains('Session with given id not found') ||
      message.contains('No session with given id');

  Future<dynamic> _evaluateRaw(
    String expression, {
    required bool awaitPromise,
  }) async {
    final res = await send('Runtime.evaluate', {
      'expression': expression,
      'awaitPromise': awaitPromise,
      'returnByValue': true,
    });
    final detail = res['exceptionDetails'] as Map<String, dynamic>?;
    if (detail != null) {
      final exception = detail['exception'] as Map<String, dynamic>?;
      throw CdpException(
        'Runtime.evaluate',
        '${detail['text']} ${exception?['description'] ?? ''}',
      );
    }
    return (res['result'] as Map<String, dynamic>)['value'];
  }

  Future<void> detach() async {
    await _chrome._command(null, 'Target.detachFromTarget', {
      'sessionId': sessionId,
    });
  }
}

/// Best-effort recursive delete of a Chrome-owned temp dir. Lingering
/// subprocesses (crashpad, GPU helpers) can repopulate the tree between
/// listing and unlink — Directory.delete then throws errno 39 ENOTEMPTY,
/// which failed whole suites in tearDownAll. Retry briefly, then give up:
/// profile cleanup must never fail a test run.
Future<void> deleteDirBestEffort(Directory dir) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (!await dir.exists()) return;
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

/// A launched headless Chrome with the unpacked browser_ext/ extension.
/// One browser-level WebSocket carries every flattened target session.
final class HeadlessChrome {
  HeadlessChrome._(this._process, this._wsUrl, this._userDataDir, this._stderr);

  final Process _process;
  final String _wsUrl;
  final Directory _userDataDir;
  final StringBuffer _stderr;

  /// Everything Chrome printed on stderr so far (launch diagnostics).
  String get capturedStderr => _stderr.toString();

  WebSocket? _ws;
  var _nextId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _sessions = <String, CdpSession>{};

  /// TCP port of the DevTools endpoint (parsed from the listening line).
  int get debugPort =>
      int.parse(RegExp(r'ws://[^/:]+:(\d+)/').firstMatch(_wsUrl)!.group(1)!);

  /// The unpacked extension's pinned id — computed from the manifest "key"
  /// (sha256 over the key's DER SPKI, first 16 bytes hex, digits mapped
  /// 0-9a-f -> a-p: Chrome's id_util::GenerateId) so the key and the id
  /// cannot drift. Current pinned value: abneclhjikpjmpknjkbcgfojmeoaddkk.
  static String get extensionId => _extensionId ??= _computeExtensionId();
  static String? _extensionId;

  static String _computeExtensionId() {
    final source = File(
      '${_repoRoot()}/browser_ext/manifest.json',
    ).readAsStringSync();
    // The manifest carries // comments (Chrome's parser is lenient);
    // strip them — jsonDecode is not.
    final json = source.replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');
    final key = (jsonDecode(json) as Map<String, dynamic>)['key'] as String;
    final hex = sha256.convert(base64.decode(key)).toString();
    return hex
        .substring(0, 32)
        .split('')
        .map(
          (c) =>
              String.fromCharCode('a'.codeUnitAt(0) + int.parse(c, radix: 16)),
        )
        .join();
  }

  /// Locates a Chrome binary: `$CHROME_PATH`, then the usual PATH names.
  /// Throws [ChromeLaunchException] listing everything tried.
  static String resolveBinary() {
    final tried = <String>[];
    final candidates = [
      if (Platform.environment['CHROME_PATH'] case final String env
          when env.isNotEmpty)
        env,
      'google-chrome',
      'google-chrome-stable',
      'chromium',
      'chromium-browser',
    ];
    for (final name in candidates) {
      final hit = which(name);
      if (hit != null) return hit;
      tried.add(name);
    }
    throw ChromeLaunchException(
      'Chrome not found — install Chrome/Chromium or export CHROME_PATH. '
          'Tried: ${tried.join(', ')}',
      '',
    );
  }

  /// PATH lookup (dart:io has none built in).
  static String? which(String name) {
    if (name.contains('/')) {
      final f = File(name);
      return f.existsSync() ? name : null;
    }
    for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
      if (dir.isEmpty) continue;
      final candidate = '$dir/$name';
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Spawns Chrome: temp user-data-dir, headless=new, the unpacked
  /// extension, an ephemeral DevTools port. On Linux, sandbox/GPU flags are
  /// added unconditionally (CI and containers need them). Resolves only
  /// after Chrome prints its DevTools endpoint; exits early → loud failure
  /// with the captured stderr.
  static Future<HeadlessChrome> launch() async {
    final binary = resolveBinary();
    final userDataDir = await Directory.systemTemp.createTemp('fa-ext-test-');
    // --load-extension needs an absolute path to browser_ext/.
    final repoRoot = _repoRoot();
    final flags = [
      '--headless=new',
      '--disable-gpu',
      '--remote-debugging-port=0',
      '--user-data-dir=${userDataDir.path}',
      '--no-first-run',
      '--no-default-browser-check',
      if (Platform.isLinux) ...['--no-sandbox', '--disable-dev-shm-usage'],
      '--load-extension=$repoRoot/browser_ext',
      'about:blank',
    ];
    final stderrBuf = StringBuffer();
    final process = await Process.start(binary, flags);
    // Chrome must never block on a full stdout pipe nobody reads.
    unawaited(process.stdout.drain<void>());
    final listening = Completer<String>();
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderrBuf.writeln(line);
          final match = RegExp(
            r'DevTools listening on (ws://\S+)',
          ).firstMatch(line);
          if (match != null && !listening.isCompleted) {
            listening.complete(match.group(1)!);
          }
        });
    process.exitCode.then((code) {
      if (!listening.isCompleted) {
        listening.completeError(
          ChromeLaunchException(
            'chrome exited early (code $code) before printing a DevTools '
            'endpoint',
            stderrBuf.toString(),
          ),
        );
      }
    });
    String wsUrl;
    try {
      wsUrl = await listening.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      process.kill();
      throw ChromeLaunchException(
        'chrome never printed "DevTools listening on ..." within 45s',
        stderrBuf.toString(),
      );
    } on ChromeLaunchException {
      unawaited(deleteDirBestEffort(userDataDir));
      rethrow;
    }
    return HeadlessChrome._(process, wsUrl, userDataDir, stderrBuf);
  }

  /// The repo root (dart test runs with the package root as CWD): the
  /// nearest ancestor that owns browser_ext/.
  static String _repoRoot() {
    var dir = Directory.current.resolveSymbolicLinksSync();
    for (var i = 0; i < 6; i++) {
      if (Directory('$dir/browser_ext').existsSync()) return dir;
      dir = '$dir/..';
    }
    throw StateError(
      'repo root with browser_ext/ not found above ${Directory.current.path}',
    );
  }

  /// GET /json/list — the current target list (pages, service workers, …).
  Future<List<dynamic>> jsonList() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$debugPort/json/list'),
      );
      final response = await request.close();
      return jsonDecode(await response.transform(utf8.decoder).join())
          as List<dynamic>;
    } finally {
      client.close();
    }
  }

  /// Polls [jsonList] until [test] matches a target; returns it.
  Future<Map<String, dynamic>> waitForTarget(
    bool Function(Map<String, dynamic> target) test, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final raw in await jsonList()) {
        final target = raw as Map<String, dynamic>;
        if (test(target)) return target;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'no CDP target matching the predicate within ${timeout.inSeconds}s',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// The extension service worker target (url .../sw/main.js).
  Future<Map<String, dynamic>> serviceWorkerTarget({
    Duration timeout = const Duration(seconds: 30),
  }) => waitForTarget(
    (t) =>
        t['type'] == 'service_worker' &&
        (t['url'] as String? ?? '').endsWith('/sw/main.js'),
    timeout: timeout,
  );

  /// Attaches a flattened session to [targetId] over the browser socket.
  Future<CdpSession> attachToTarget(String targetId) async {
    await _ensureSocket();
    final res = await _command(null, 'Target.attachToTarget', {
      'targetId': targetId,
      'flatten': true,
    });
    final session = CdpSession._(this, res['sessionId'] as String);
    _sessions[session.sessionId] = session;
    return session;
  }

  /// Session on the extension's panel page opened as a regular tab — a
  /// stable, always-listed page target whose `chrome.runtime` calls wake
  /// the MV3 service worker (the SW's own CDP target only exists while it
  /// runs; Chrome idles it out aggressively).
  CdpSession? _panel;

  Future<CdpSession> _panelSession() async {
    final cached = _panel;
    if (cached != null) return cached;
    final target = await openTab(
      'chrome-extension://$extensionId/panel/panel.html',
    );
    return _panel = await attachToTarget(target['targetId'] as String);
  }

  /// Fires `chrome.runtime.sendMessage({type:'status'})` from the panel page
  /// and polls /json/list until the sw/main.js service-worker target exists.
  /// Fire-and-forget on purpose: awaiting the sendMessage promise can hang
  /// while the worker boots. Returns the FRESH target — its id changes
  /// across wake cycles. A dead panel (chrome.runtime.reload() destroys
  /// every extension page) is re-opened once.
  Future<Map<String, dynamic>> wakeServiceWorker({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await _wakeVia(await _panelSession(), timeout);
    } on CdpException {
      _panel = null;
      return _wakeVia(await _panelSession(), timeout);
    }
  }

  Future<Map<String, dynamic>> _wakeVia(
    CdpSession panel,
    Duration timeout,
  ) async {
    await panel.send('Runtime.evaluate', {
      'expression':
          "chrome.runtime.sendMessage({type:'status'}).catch(() => {})",
      'returnByValue': true,
    });
    try {
      return await serviceWorkerTarget(timeout: timeout);
    } on TimeoutException {
      throw TimeoutException(
        'extension service worker never appeared within '
        '${timeout.inSeconds}s of waking it. Extension load/start errors '
        'would be on Chrome stderr:\n${capturedStderr.trim()}',
      );
    }
  }

  /// Attaches to the extension SW: wake it first (its CDP target exists
  /// only while it runs), then attach to the freshly discovered target.
  Future<CdpSession> attachServiceWorker({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final target = await wakeServiceWorker(timeout: timeout);
    final session = await attachToTarget(target['id'] as String);
    // A worker idled out mid-test kills this session; revive re-wakes and
    // reattaches once (see CdpSession.evaluate).
    session.revive = attachServiceWorker;
    return session;
  }

  /// Opens a new tab ([Target.createTarget]) and returns its target info
  /// (targetId, type, url, …) — getTargetInfo nests it under `targetInfo`.
  Future<Map<String, dynamic>> openTab(String url) async {
    await _ensureSocket();
    final res = await _command(null, 'Target.createTarget', {'url': url});
    final info = await _command(null, 'Target.getTargetInfo', {
      'targetId': res['targetId'],
    });
    return info['targetInfo'] as Map<String, dynamic>;
  }

  Future<void> closeTab(String targetId) async {
    await _ensureSocket();
    await _command(null, 'Target.closeTarget', {'targetId': targetId});
  }

  Future<void> _ensureSocket() async {
    if (_ws != null) return;
    final ws = await WebSocket.connect(_wsUrl);
    ws.listen((data) => _onFrame(data as String), onDone: () => _ws = null);
    _ws = ws;
  }

  void _onFrame(String raw) {
    final Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return;
    }
    if (frame['id'] is int) {
      _pending.remove(frame['id'])?.complete(frame);
      return;
    }
    final sessionId = frame['sessionId'] as String?;
    if (sessionId != null) _sessions[sessionId]?._events.add(frame);
  }

  /// One correlated command; flat when [sessionId] is null (browser-level).
  Future<Map<String, dynamic>> _command(
    String? sessionId,
    String method,
    Map<String, dynamic>? params,
  ) async {
    await _ensureSocket();
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _ws!.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': ?params,
        'sessionId': ?sessionId,
      }),
    );
    final frame = await completer.future.timeout(const Duration(seconds: 35));
    final error = frame['error'] as Map<String, dynamic>?;
    if (error != null) {
      throw CdpException(method, '${error['message'] ?? error}');
    }
    return (frame['result'] as Map<String, dynamic>?) ?? const {};
  }

  /// Kills the Chrome process tree and deletes the temp profile. Safe to
  /// call more than once.
  Future<void> dispose() async {
    try {
      await _ws?.close();
    } on Object {
      // Socket already gone.
    }
    _ws = null;
    _process.kill();
    try {
      await _process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process.kill(ProcessSignal.sigkill);
          return _process.exitCode;
        },
      );
    } on Object {
      // Best effort — the profile cleanup below is what matters.
    }
    await deleteDirBestEffort(_userDataDir);
  }
}

/// Polls [probe] until [test] holds; fails with [description] + the last
/// value on timeout. The suite's one waiting primitive.
Future<T> pollUntil<T>(
  Future<T> Function() probe,
  bool Function(T value) test, {
  required String description,
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  T last;
  while (true) {
    last = await probe();
    if (test(last)) return last;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'timed out waiting for $description (last: $last)',
      );
    }
    await Future<void>.delayed(interval);
  }
}

/// Evaluates [expression] inside a fresh session on the extension SW.
Future<dynamic> evaluateInServiceWorker(
  HeadlessChrome chrome,
  String expression, {
  bool awaitPromise = false,
}) async {
  final session = await chrome.attachServiceWorker();
  return session.evaluate(expression, awaitPromise: awaitPromise);
}

/// Runs one browser op through the SW dispatcher (`faSw.dispatch`) and
/// returns the raw envelope: {ok: true, result} | {ok: false, error, code?}.
/// Each call resolves exactly once — dispatch's contract.
Future<Map<String, dynamic>> dispatchOp(
  HeadlessChrome chrome,
  String op, [
  Map<String, dynamic>? args,
]) async {
  final result = await evaluateInServiceWorker(
    chrome,
    'globalThis.faSw.dispatch(${jsonEncode(op)}, ${jsonEncode(args ?? {})})',
    awaitPromise: true,
  );
  return result as Map<String, dynamic>;
}

/// Tiny static file server for test/browser_ext/fixture/ — binds an
/// ephemeral loopback port; [url] is the fixture index.html base.
final class FixtureServer {
  FixtureServer(this._root);

  final String _root;
  HttpServer? _server;

  int get port => _server!.port;

  String get url => 'http://127.0.0.1:$port/';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_server!.forEach(_serve));
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path == '/' ? '/index.html' : request.uri.path;
    final file = File('$_root$path');
    if (!file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response.headers.contentType = path.endsWith('.js')
        ? ContentType('text', 'javascript', charset: 'utf-8')
        : ContentType.html;
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
