/// Wire contract between a JS extension and the host (section 5 of the
/// js-extension design): the global functions the JS bootstrap guarantees to
/// the host, and the `jsr.ext.*` bridge method names the host guarantees to
/// JS. Pure data — every constant here is mirrored by the JS sources in
/// `ext_bootstrap_js.dart`.
library;

/// Names of the global JS functions every engine bootstrap defines (host → JS
/// entry points). Adapters call them after the extension's `main.js` has been
/// evaluated.
abstract final class ExtJsGlobals {
  /// `__extCommit()` → `Map` — the buffered registration payload:
  /// `{tools:[{name,description,parameters,tier,handle}],
  ///   hooks:[{event,handle}],
  ///   slash:[{name,description,handle}],
  ///   flows:[{id,title,description,fields:[{name,label,secret}],handle}]}`.
  /// Called by the adapter after `main.js` evaluation; invalid shapes are
  /// rejected Dart-side with [ExtProtocolException].
  static const String commit = '__extCommit';

  /// `__extInvoke(handle, args)` → tool/hook/slash/flow callback result. The
  /// result may be a Promise — adapters await settlement. Handles are integers
  /// bound to callbacks by `__extCommit`'s buffer.
  static const String invoke = '__extInvoke';

  /// `__extPing()` → engine identity string (`'<engineId>'`), used by parity
  /// fixtures to prove which transport answered.
  static const String ping = '__extPing';
}

/// JS → host bridge method names. The bootstrap transports every call as
/// `__extTransport.call(method, args)`; the host dispatches on these strings.
/// Errors reach JS as rejected promises carrying `{error: '<message>'}`.
abstract final class ExtBridgeMethods {
  /// `{name,description,parameters?,tier?,handle}` → `null` (buffered;
  /// validated at commit time).
  static const String registerTool = 'register.tool';

  /// `{event,handle}` → `null`.
  static const String registerHook = 'register.hook';

  /// `{name,description,handle}` → `null`.
  static const String registerSlash = 'register.slash';

  /// `{id,title,description,fields,handle}` → `null` (menus capability).
  static const String registerFlow = 'register.flow';

  /// `{text}` → `null`.
  static const String sessionAppendNote = 'session.appendNote';

  /// `{text}` → `null`.
  static const String sessionEnqueueFollowUp = 'session.enqueueFollowUp';

  /// `{path}` → String content (fs capability; confined to the project root).
  static const String fsReadFile = 'fs.readFile';

  /// `{command,args,timeoutMs?}` →
  /// `{exitCode:int, stdout:String, stderr:String, timedOut:bool}`
  /// (exec capability; allowlist-gated).
  static const String execRun = 'exec.run';

  /// `{text}` → `null` (no newline).
  static const String ioWrite = 'io.write';

  /// `{text}` → `null` (newline appended by the host).
  static const String ioWriteln = 'io.writeln';

  /// `{name}` → `{granted:bool, name:String}` — never a key value.
  static const String keysRequest = 'keys.request';

  /// `{capability}` → bool.
  static const String has = 'has';

  /// Every documented bridge method.
  static const Set<String> all = {
    registerTool,
    registerHook,
    registerSlash,
    registerFlow,
    sessionAppendNote,
    sessionEnqueueFollowUp,
    fsReadFile,
    execRun,
    ioWrite,
    ioWriteln,
    keysRequest,
    has,
  };
}

/// Tool permission tier vocabulary carried in `register.tool` /
/// `__extCommit` tool entries; `exec` is the default when absent.
abstract final class ExtTiers {
  static const String read = 'read';
  static const String write = 'write';
  static const String exec = 'exec';

  /// Tiers a tool declaration may carry.
  static const Set<String> all = {read, write, exec};
}

/// The commit payload (or a bridge response) did not match the wire contract.
class ExtProtocolException implements Exception {
  /// Human-readable description, usually every accumulated problem joined
  /// with `'; '`.
  final String message;

  const ExtProtocolException(this.message);

  @override
  String toString() => message;
}
