part of 'fah.dart';

const _fallbackVersion = '0.1.0';

/// Reads the package version with four fallbacks so compiled binaries stay
/// accurate: `-DFA_VERSION=` baked at compile time (legacy AOT builds), then
/// a `version.txt` file alongside the `dart build cli` bundle, then the
/// `pubspec.yaml` next to the executable (source runs), then the constant.
String _packageVersion() {
  const fromEnv = String.fromEnvironment('FA_VERSION');
  if (fromEnv.isNotEmpty) return fromEnv;
  try {
    // Platform.resolvedExecutable always returns the full canonical path,
    // even when the binary was invoked via a bare name or relative path.
    // Platform.script may return a relative path on some platforms, which
    // makes exeDir = cwd instead of the binary's real directory.
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent;
    final bundleRoot = exeDir.parent;
    // Try bundle/version.txt first (dart build cli layout).
    final versionFile = File('${bundleRoot.path}/version.txt');
    if (versionFile.existsSync()) {
      final v = versionFile.readAsStringSync().trim();
      if (v.isNotEmpty) return v;
    }
    // Try <exe_dir>/version.txt (installer layout: version.txt next to fa).
    final dirVersionFile = File('${exeDir.path}/version.txt');
    if (dirVersionFile.existsSync()) {
      final v = dirVersionFile.readAsStringSync().trim();
      if (v.isNotEmpty) return v;
    }
    // Source run: pubspec.yaml sits two levels up from bin/.
    final pubspec = File('${bundleRoot.path}/pubspec.yaml');
    final doc = yaml.loadYaml(pubspec.readAsStringSync()) as Map;
    final value = doc['version'];
    if (value is String && value.isNotEmpty) return value;
  } on Object {
    // Fall back to the compile-time constant when nothing is available.
  }
  return _fallbackVersion;
}

Never _fail(String message) {
  stderr.writeln('fa: $message');
  stderr.writeln('Run with --help for usage.');
  exit(64);
}

Never _exitWithUsage(String version) {
  stdout.write(cliHelpText(version));
  exit(0);
}

/// Set once the first SIGTERM arrived in a headless run (issue #155): a
/// second one escalates from graceful to forced.
var _sigtermSeen = false;

/// The in-flight headless run, awaited by the SIGINT/SIGTERM graceful
/// exits (issue #155). Set before the signals can matter, read only from
/// the exit paths.
Future<int>? _headlessRun;

/// wire-serve (issue #1103): ends the transport (completing the serve
/// future) so a signal-driven exit tears down GRACEFULLY — runWireServe's
/// finally aborts any in-flight run, persists, and the process exits.
/// Null outside wire-serve mode.
void Function()? _wireServeSettle;

/// Graceful headless abort shared by SIGINT and SIGTERM (issue #155):
/// abort the run, wait for it to settle (bounded — a wedged provider
/// cannot hold the exit), flush the HEP stream, exit 130.
void _gracefulHeadlessExit(void Function() fireInterrupt) {
  fireInterrupt();
  _wireServeSettle?.call();
  final run = _headlessRun;
  unawaited(
    Future(() async {
      if (run != null) {
        await run.timeout(const Duration(seconds: 10), onTimeout: () => 130);
      }
      // gh-1455: drain the serialized line chain instead of a bare flush —
      // a flush racing the in-flight per-line flushes is the exact
      // "StreamSink is bound to a stream" teardown crash.
      await drainStdoutLines();
    }).whenComplete(() => exit(130)),
  );
}

/// gh-1455: the ONE write+flush chain for headless stdout (HEP v1 and
/// stream-json lines). `stdout.flush()` marks the sink "bound" while in
/// flight, so the old unawaited per-line `stdout.flush()` racing the next
/// `writeln` — or the exit paths' own flush — threw the synchronous
/// `StateError("StreamSink is bound to a stream")` from an event-callback
/// frame: an uncaught zone error that crashed shutdown (crash.log) and let
/// the process linger until the runner's stall-kill. Every link is
/// guarded, so the chain itself can never reject; nothing escapes after
/// teardown.
Future<void> _stdoutLineChain = Future<void>.value();

/// Appends one line to [_stdoutLineChain] — write, then flush, both
/// guarded. Never throws.
void _enqueueStdoutLine(String line) {
  _stdoutLineChain = _stdoutLineChain.then((_) async {
    try {
      stdout.writeln(line);
      await stdout.flush();
    } on Object {
      // The sink is being torn down (or its stream already closed): a
      // crashed writer must not surface as an uncaught zone error.
    }
  });
}

/// Drains the line chain and flushes once more — the exit paths call this
/// instead of a bare `await stdout.flush()` so a final flush can never
/// overlap an in-flight chain link. Re-drains while stragglers enqueue
/// behind us (bounded), so the final flush is the true last sink
/// operation. Never throws.
Future<void> drainStdoutLines() async {
  for (var round = 0; round < 8; round++) {
    final chain = _stdoutLineChain;
    await chain;
    if (identical(chain, _stdoutLineChain)) break;
  }
  try {
    await stdout.flush();
  } on Object {
    // Same teardown guard as [_enqueueStdoutLine].
  }
}

/// One HEP JSONL line to stdout, flushed immediately (issue #155): a
/// supervisor tailing the pipe must never wait on a buffer.
void _writeHepLine(String line) {
  _enqueueStdoutLine(line);
}

/// One stream-json NDJSON line to stdout, flushed immediately (issue
/// #695): same live-pipe contract as HEP — `| jq` consumers tail the
/// stream line by line, and jsonEncode output is always single-line.
void _writeStreamJsonLine(String line) {
  _enqueueStdoutLine(line);
}

/// The mime reported when the magic-byte sniff misses — callers treat it
/// as "not an image" (issue #196 `--attach` passthrough).
const _unknownAttachMime = 'application/octet-stream';

/// Image type by magic bytes (issue #155 `--attach`): the file extension
/// is untrusted; the first bytes are. png/jpeg/gif/webp covered, else
/// [_unknownAttachMime].
String _sniffMime(Uint8List bytes) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  const png = [137, 80, 78, 71, 13, 10, 26, 10];
  if (startsWith(png)) return 'image/png';
  if (startsWith([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith([0x52, 0x49, 0x46, 0x46]) &&
      bytes.length > 12 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return _unknownAttachMime;
}

Never _exitWithVersion(String version, {String? output}) {
  if (output == 'json') {
    // Machine-readable for supervisors (issue #155): version + HEP
    // protocol version, one JSON object.
    stdout.writeln(jsonEncode({'version': version, 'hep': hepVersion}));
    exit(0);
  }
  stdout.writeln('fa $version');
  exit(0);
}

/// Writes an uncaught error to `~/.fah/crash.log` and stderr, then exits
/// non-zero. This is the last-resort handler so users can report what
/// happened instead of the CLI silently disappearing.
void _handleUncaughtError(Object error, StackTrace stackTrace) {
  final message = 'fa crashed: $error';
  stderr.writeln(message);
  if (error is SessionException ||
      message.contains('Failed to create session directory')) {
    stderr.writeln(
      '\nTip: If this is a permission issue with session storage, you can fix it by running:\n'
      '  sudo chown -R \$(whoami) ~/Library/"Group Containers"/group.dev.fa1.shared\n'
      '  chmod -R u+rwx ~/Library/"Group Containers"/group.dev.fa1.shared\n'
      'Or start fa with a custom session storage path:\n'
      '  fa --session-root ~/.fah/sessions\n',
    );
  }
  try {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final dir = Directory('$home/.fah');
      dir.createSync(recursive: true);
      final log = File('${dir.path}/crash.log');
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final version = _packageVersion();
      final buffer = StringBuffer()
        ..writeln('timestamp: $timestamp')
        ..writeln('version: $version')
        ..writeln('type: ${error.runtimeType}')
        ..writeln('error: $error')
        ..writeln('stack:')
        ..writeln(stackTrace);
      log.writeAsStringSync('$buffer\n', mode: FileMode.append);
      stderr.writeln('details appended to ${log.path}');
    }
  } on Object catch (e) {
    stderr.writeln('could not write crash log: $e');
  }
  stderr.writeln('Run with --help for usage.');
  exit(1);
}
