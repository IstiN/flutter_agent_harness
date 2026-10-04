part of 'fah.dart';

/// [CliIO] bound to the real terminal: stdin lines, stdout writes, and a
/// broadcast interrupt channel fed by the SIGINT handler in `main`.
///
/// In [headless] mode diagnostics ([writeln]) go to stderr so stdout carries
/// only the assistant text, input is never read, and the CLI is never
/// interactive (approval/ask prompts resolve non-interactively).
final class _TerminalCliIO implements CliIO {
  _TerminalCliIO({this.headless = false});

  /// Whether the CLI runs a single headless prompt.
  final bool headless;

  final _interrupts = StreamController<void>.broadcast();
  StreamController<KeyEvent>? _keyController;
  StreamSubscription<List<int>>? _keySub;
  var _rawModeOk = true;

  void fireInterrupt() => _interrupts.add(null);

  @override
  Stream<String> get lines => headless
      ? const Stream<String>.empty()
      : stdin.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<KeyEvent> get keys {
    if (headless || !supportsRawMode) return const Stream<KeyEvent>.empty();
    _keyController ??= StreamController<KeyEvent>.broadcast(
      onListen: _startRawInput,
      onCancel: _stopRawInput,
    );
    return _keyController!.stream;
  }

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => stdout.write(text);

  @override
  void writeln(String text) =>
      headless ? stderr.writeln(text) : stdout.writeln(text);

  /// Piped input (no terminal) means no human can answer approval prompts:
  /// the CLI then denies prompt-policy tool calls with a reason. Headless
  /// mode is never interactive, terminal or not.
  @override
  bool get isInteractive => !headless && stdin.hasTerminal;

  @override
  bool get supportsRawMode => !headless && stdin.hasTerminal && _rawModeOk;

  @override
  int get columns {
    // stdout can be a pipe (session switch replay, headless-ish paths) —
    // terminalColumns throws StdoutException there (crash.log had two).
    try {
      return stdout.terminalColumns;
    } on StdoutException {
      return 80;
    }
  }

  @override
  int get rows {
    try {
      return stdout.terminalLines;
    } on StdoutException {
      return 24;
    }
  }

  void _startRawInput() {
    if (_keySub != null) return;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
    } on Exception {
      // Raw mode is not available in this terminal (e.g. embedded panels or
      // some Windows consoles). Fall back to canonical line input.
      _rawModeOk = false;
      _keyController?.close();
      return;
    }
    _keySub = stdin.listen(
      _onRawBytes,
      onDone: () => _keyController?.close(),
      onError: (_) => _keyController?.close(),
    );
  }

  void _stopRawInput() {
    _keySub?.cancel();
    _keySub = null;
    try {
      stdin.echoMode = true;
      stdin.lineMode = true;
    } on Exception {
      // May fail if the process is shutting down; ignore.
    }
  }

  /// Restores canonical terminal mode. Called before an idle Ctrl-C exits so
  /// the shell is not left in raw mode.
  void resetRawMode() => _stopRawInput();

  void _onRawBytes(List<int> bytes) {
    final controller = _keyController;
    if (controller == null || controller.isClosed) return;
    final events = _decodeKeys(bytes);
    for (final event in events) {
      controller.add(event);
    }
  }

  /// Decodes raw terminal bytes into [KeyEvent]s. Handles ASCII control
  /// characters and common ANSI escape sequences for arrow keys, home/end,
  /// and delete.
  List<KeyEvent> _decodeKeys(List<int> bytes) {
    final result = <KeyEvent>[];
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b == 0x1b) {
        // ANSI escape sequence.
        if (i + 2 < bytes.length && bytes[i + 1] == 0x5b) {
          final code = bytes[i + 2];
          switch (code) {
            case 0x41:
              result.add(const KeyEvent(type: KeyType.up));
            case 0x42:
              result.add(const KeyEvent(type: KeyType.down));
            case 0x43:
              result.add(const KeyEvent(type: KeyType.right));
            case 0x44:
              result.add(const KeyEvent(type: KeyType.left));
            case 0x48:
              result.add(const KeyEvent(type: KeyType.home));
            case 0x46:
              result.add(const KeyEvent(type: KeyType.end));
            case 0x33:
              if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                result.add(const KeyEvent(type: KeyType.delete));
                i += 3;
                continue;
              }
            case 0x31:
              if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                result.add(const KeyEvent(type: KeyType.home));
                i += 3;
                continue;
              }
            case 0x34:
              if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                result.add(const KeyEvent(type: KeyType.end));
                i += 3;
                continue;
              }
            default:
              result.add(const KeyEvent(type: KeyType.unknown));
          }
          i += 2;
        } else if (i + 1 < bytes.length && bytes[i + 1] == 0x4f) {
          // SS3 sequences: ESC O H / ESC O F on some terminals.
          if (i + 2 < bytes.length) {
            final code = bytes[i + 2];
            if (code == 0x48) {
              result.add(const KeyEvent(type: KeyType.home));
            } else if (code == 0x46) {
              result.add(const KeyEvent(type: KeyType.end));
            } else {
              result.add(const KeyEvent(type: KeyType.unknown));
            }
            i += 2;
          } else {
            result.add(const KeyEvent(type: KeyType.escape));
          }
        } else {
          result.add(const KeyEvent(type: KeyType.escape));
        }
      } else if (b == 0x09) {
        result.add(const KeyEvent(type: KeyType.tab));
      } else if (b == 0x0d || b == 0x0a) {
        result.add(const KeyEvent(type: KeyType.enter));
      } else if (b == 0x7f) {
        result.add(const KeyEvent(type: KeyType.backspace));
      } else if (b == 0x00) {
        // Ctrl-Space / null byte; ignore.
      } else if (b < 0x20) {
        // Ctrl+letter printable-ish range; treat as char for now.
        result.add(
          KeyEvent(
            char: String.fromCharCode(b + 0x40),
            type: KeyType.char,
            ctrl: true,
          ),
        );
      } else {
        result.add(KeyEvent(char: String.fromCharCode(b), type: KeyType.char));
      }
    }
    return result;
  }
}

/// `/browser connect` handle: runs the bridge server inside this process
/// over the launch-cwd messaging fabric (the DIP adapter — lib/ stays
/// dart:io-free).
final class _FaBrowserBridgeHandle implements BrowserBridgeHandle {
  _FaBrowserBridgeHandle({
    required LocalExecutionEnv env,
    required String sessionRoot,
    required String homeDir,
    required String faVersion,
    this.providers = const [],
    this.keys,
  }) : _messaging = _projectMessagingRepository(
         env: env,
         sessionRoot: sessionRoot,
         homeDir: homeDir,
       ),
       _projectRoot = env.cwd,
       _version = faVersion;

  final MessagingRepository _messaging;
  final String _projectRoot;
  final String _version;

  /// Saved custom providers: pushed (metadata) to every pairing that
  /// asks, and the key slots the LLM relay resolves against.
  final List<CustomProviderEntry> providers;

  /// Key lookups for copy-mode staging and the relay. Null = lookups miss.
  final SecureKeyCache? keys;
  BridgeServer? _server;
  _FaBrowserController? _controller;
  var _attached = false;

  /// The browser-tools controller seam over this handle's bridge server.
  BrowserController get browserController =>
      _controller ??= _FaBrowserController(this);

  /// Whether a PAIRED extension is connected (mailbox registered —
  /// mid-handshake sockets don't count).
  bool get hasPairedClient => (_server?.clients ?? const <BridgeConnection>[])
      .any((client) => client.mailboxId != null);

  /// The MOST RECENT paired connection (insertion order; with several
  /// paired extensions the newest handshake wins — a deliberate silent
  /// choice, see [_FaBrowserController] docs).
  BridgeConnection? get _activeClient {
    final clients = _server?.clients ?? const <BridgeConnection>[];
    if (clients.isEmpty) return null;
    return clients.lastWhere(
      (client) => client.mailboxId != null,
      orElse: () => clients.last,
    );
  }

  /// Connect/disconnect seam: forwards the paired-client truth value to
  /// the controller's availability hook on flips only.
  void _onClientsChanged() {
    final attached = hasPairedClient;
    if (attached == _attached) return;
    _attached = attached;
    _controller?.onAvailabilityChanged?.call(attached);
  }

  @override
  Future<BrowserBridgeSession> connect({
    int port = bridgeDefaultPort,
    bool copyKeys = false,
  }) async {
    final existing = _server;
    if (existing != null && existing.running) {
      return BrowserBridgeSession(
        url: existing.url,
        token: existing.mintToken(),
        alreadyRunning: true,
      );
    }
    final token = await BridgeTokenFile(_projectRoot).ensure();
    final server = BridgeServer(
      messaging: _messaging,
      root: _projectRoot,
      port: port,
      token: token,
      version: _version,
      onClientsChanged: _onClientsChanged,
      providers: providers,
      keys: keys,
      copyKeys: copyKeys,
    );
    await server.start();
    _server = server;
    return BrowserBridgeSession(
      url: server.url,
      token: server.mintToken(),
      alreadyRunning: false,
    );
  }

  @override
  Future<BrowserBridgeStatus> status() async {
    final server = _server;
    final mailboxes = await _messaging.directory();
    return BrowserBridgeStatus(
      running: server?.running ?? false,
      url: (server?.running ?? false) ? server!.url : null,
      extensions: [
        for (final client in server?.clients ?? const <BridgeConnection>[])
          ?client.mailboxId,
      ],
      mailboxes: [
        for (final mailbox in mailboxes) (id: mailbox.id, cwd: mailbox.cwd),
      ],
    );
  }
}

/// The [BrowserController] over this process' bridge server: every op
/// dispatches to the most recent PAIRED extension (deterministic: newest
/// handshake wins; a deliberate silent choice — several paired extensions
/// are not a supported steering surface, restart the bridge to reset).
/// No paired extension: every op fails fast with `no_target`. Dispatch
/// errors and timeouts surface as [BrowserToolException] with the wire
/// code intact.
final class _FaBrowserController implements BrowserController {
  _FaBrowserController(this._handle);

  final _FaBrowserBridgeHandle _handle;

  @override
  void Function(bool attached)? onAvailabilityChanged;

  @override
  bool get attached => _handle.hasPairedClient;

  Future<Map<String, dynamic>> _dispatch(
    String op,
    Map<String, dynamic> args,
  ) async {
    final connection = _handle._activeClient;
    if (connection == null) {
      throw BrowserToolException(
        'no_target',
        'no browser extension connected — run /browser connect and pair',
      );
    }
    final result = await connection.dispatch(op, args);
    if (result['ok'] == true) {
      return result['result'] as Map<String, dynamic>? ?? const {};
    }
    throw BrowserToolException(
      result['code'] as String? ?? 'no_target',
      result['error'] as String? ?? 'browser op failed',
    );
  }

  @override
  Future<BrowserNavigation> navigate(String url, {int? tabId}) async {
    final r = await _dispatch('navigate', {'url': url, 'tabId': ?tabId});
    return (
      tabId: r['tabId'] as int,
      url: r['url'] as String,
      title: r['title'] as String? ?? '',
    );
  }

  @override
  Future<List<BrowserTab>> listTabs() async {
    final r = await _dispatch('tabs', const {});
    return [
      for (final tab in (r['tabs'] as List? ?? const []).cast<Map>())
        (
          id: tab['id'] as int,
          url: tab['url'] as String? ?? '',
          title: tab['title'] as String? ?? '',
          active: tab['active'] as bool? ?? false,
          groupId: tab['groupId'] as int?,
        ),
    ];
  }

  @override
  Future<void> switchTab(int tabId) =>
      _dispatch('switch_tab', {'tabId': tabId});

  @override
  Future<void> click(String selector, {int? tabId}) =>
      _dispatch('click', {'selector': selector, 'tabId': ?tabId});

  @override
  Future<void> type(
    String selector,
    String text, {
    bool submit = false,
    int? tabId,
  }) => _dispatch('type', {
    'selector': selector,
    'text': text,
    if (submit) 'submit': true,
    'tabId': ?tabId,
  });

  @override
  Future<void> pressKey(String key, {String? selector, int? tabId}) =>
      _dispatch('press_key', {
        'key': key,
        'selector': ?selector,
        'tabId': ?tabId,
      });

  @override
  Future<void> select(String selector, String value, {int? tabId}) => _dispatch(
    'select',
    {'selector': selector, 'value': value, 'tabId': ?tabId},
  );

  @override
  Future<BrowserDom> readDom({
    String? selector,
    int? maxNodes,
    bool includeShadow = false,
    int? tabId,
  }) async {
    final r = await _dispatch('read_dom', {
      'selector': ?selector,
      'maxNodes': ?maxNodes,
      if (includeShadow) 'includeShadow': true,
      'tabId': ?tabId,
    });
    return (
      dom: r['dom'] as String? ?? '',
      nodeCount: r['nodeCount'] as int? ?? 0,
      truncated: r['truncated'] as bool? ?? false,
    );
  }

  @override
  Future<Object?> evalCode(String code, {int? tabId}) async {
    final r = await _dispatch('eval', {'code': code, 'tabId': ?tabId});
    return r['result'];
  }

  @override
  Future<Uint8List> screenshot({int? tabId}) async {
    final r = await _dispatch('screenshot', {'tabId': ?tabId});
    return base64Decode(r['pngBase64'] as String);
  }

  @override
  Future<BrowserWaitResult> waitFor({
    String? selector,
    String? text,
    required int timeoutMs,
    int? tabId,
  }) async {
    final r = await _dispatch('wait_for', {
      'selector': ?selector,
      'text': ?text,
      'timeoutMs': timeoutMs,
      'tabId': ?tabId,
    });
    return (
      found: r['found'] as bool? ?? true,
      waitedMs: r['waitedMs'] as int? ?? 0,
    );
  }

  @override
  Future<void> taskEnd() => _dispatch('task_end', const {});
}
