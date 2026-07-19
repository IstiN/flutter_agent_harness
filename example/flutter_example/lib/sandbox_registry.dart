// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The central registry of sandbox shell commands.
///
/// This file is the single source of truth for "which commands exist in the
/// agent's shell" per platform:
///
/// - The shells themselves resolve commands against the ground-truth name
///   sets below: the web `MemoryShell` uses [webShellCommandNames]; the
///   mobile `WasiSandboxShell` uses [mobileCoreutilsApplets],
///   [mobileBuiltinCommands], and [mobileModuleCommands]. A command added to
///   a set becomes runnable — and advertiseable — from one place.
/// - The Fa system prompt renders [formatSandboxCommandSection] into the
///   `{{commands}}` placeholder of `prompts/sandbox_system.md` (wired in
///   `AgentService`), so the model is told exactly what exists on the current
///   platform instead of guessing (`node`, `apt-get`, ...) and hitting 127.
/// - Any future UI/help surface ("what can the sandbox do?") should consume
///   [sandboxCommandsFor] / [sandboxCommandNamesFor] rather than re-listing
///   commands.
library;

/// The platform whose shell the registry describes.
enum SandboxPlatform {
  /// Browser: the pure-Dart `MemoryShell` over an in-memory filesystem.
  web,

  /// iOS/Android: the `WasiSandboxShell` running WASI modules rooted at a
  /// sandboxed host directory.
  mobile,

  /// macOS/Linux/Windows: the host shell via `LocalExecutionEnv` — every
  /// tool installed on the machine is available, so there is no fixed list.
  desktop,
}

/// One advertised sandbox command and its one-line summary for the prompt.
final class SandboxCommand {
  /// Creates an entry.
  const SandboxCommand(this.name, this.summary);

  /// The command name as typed in the shell (e.g. `qjs`).
  final String name;

  /// A short one-line description rendered next to the name.
  final String summary;
}

// ---------------------------------------------------------------------------
// Ground-truth command name sets (consumed by the shells themselves)
// ---------------------------------------------------------------------------

/// Commands the web `MemoryShell` resolves (ground truth for `which` and for
/// "command not found").
///
/// `ssh`/`scp`/`sftp` and `lua` are registered so `which` finds them, but
/// they always fail with exit 127 (browsers cannot open raw TCP connections
/// and there is no browser Lua build). They are therefore excluded from the
/// advertised list ([sandboxCommandsFor]) and called out in the section's
/// NOT-available line instead.
const Set<String> webShellCommandNames = {
  'awk',
  'base64',
  'basename',
  'bunzip2',
  'bzip2',
  'cat',
  'cd',
  'command',
  'cp',
  'curl',
  'diff',
  'dig',
  'dirname',
  'echo',
  'env',
  'export',
  'false',
  'file',
  'find',
  'git',
  'grep',
  'gunzip',
  'gzip',
  'head',
  'jq',
  'js',
  'ls',
  'lua',
  'md5sum',
  'mkdir',
  'mv',
  'nslookup',
  'patch',
  'pip',
  'pip3',
  'printf',
  'pwd',
  'python',
  'python3',
  'qjs',
  'realpath',
  'rg',
  'rm',
  'rmdir',
  'scp',
  'sed',
  'sftp',
  'sha1sum',
  'sha224sum',
  'sha256sum',
  'sha384sum',
  'sha512sum',
  'sort',
  'sqlite3',
  'ssh',
  'tail',
  'tar',
  'test',
  'touch',
  'tr',
  'tree',
  'true',
  'unset',
  'unxz',
  'unzip',
  'wc',
  'wget',
  'which',
  'whoami',
  'whois',
  'xargs',
  'xz',
  'yq',
  'zip',
  '[',
};

/// Applets exported by the mobile `coreutils.wasm` multicall binary.
const Set<String> mobileCoreutilsApplets = {
  'arch',
  'b2sum',
  'base32',
  'base64',
  'basename',
  'basenc',
  'cat',
  'cksum',
  'comm',
  'cp',
  'csplit',
  'cut',
  'date',
  'dd',
  'dir',
  'dircolors',
  'dirname',
  'echo',
  'expand',
  'factor',
  'false',
  'fmt',
  'fold',
  'head',
  'join',
  'link',
  'ln',
  'ls',
  'md5sum',
  'mkdir',
  'mktemp',
  'mv',
  'nl',
  'nproc',
  'numfmt',
  'od',
  'paste',
  'pathchk',
  'pr',
  'printenv',
  'printf',
  'ptx',
  'pwd',
  'readlink',
  'realpath',
  'rm',
  'rmdir',
  'seq',
  'sha1sum',
  'sha224sum',
  'sha256sum',
  'sha384sum',
  'sha512sum',
  'shred',
  'shuf',
  'sleep',
  'sort',
  'split',
  'sum',
  'tail',
  'tee',
  'touch',
  'tr',
  'true',
  'truncate',
  'tsort',
  'tty',
  'uname',
  'unexpand',
  'uniq',
  'unlink',
  'vdir',
  'wc',
  'yes',
};

/// Mobile shell builtins implemented in Dart. These do not need a WASM
/// module and do not increase the IPA size.
const Set<String> mobileBuiltinCommands = {
  'curl',
  'wget',
  'git',
  'jq',
  'yq',
  'env',
  'test',
  '[',
  'which',
  'command',
  'whoami',
  'xargs',
  'tr',
  'cd',
  'pwd',
  'export',
  'unset',
  'grep',
  'du',
  'stat',
  'tac',
  'expr',
  'id',
  'relpath',
  'diff',
  'patch',
  'nslookup',
  'dig',
  'whois',
  'ssh',
  'scp',
  'sftp',
  'tree',
  'file',
  'xz',
  'unxz',
  'bzip2',
  'bunzip2',
  'pip',
  'pip3',
};

/// Mobile commands served by a dedicated WASI module (`rg.wasm`,
/// `python.wasm`, `qjs.wasm`, ...).
const Set<String> mobileModuleCommands = {
  'rg',
  'find',
  'sed',
  'awk',
  'tar',
  'gzip',
  'zip',
  'unzip',
  'python',
  'python3',
  'qjs',
  'js',
  'sqlite3',
  'lua',
};

/// Every command name the platform's shell resolves.
///
/// Desktop returns the empty set: it uses the host shell, so the command set
/// is unbounded (whatever is installed on the machine).
Set<String> sandboxCommandNamesFor(SandboxPlatform platform) =>
    switch (platform) {
      SandboxPlatform.web => webShellCommandNames,
      SandboxPlatform.mobile => {
        ...mobileCoreutilsApplets,
        ...mobileBuiltinCommands,
        ...mobileModuleCommands,
      },
      SandboxPlatform.desktop => const {},
    };

// ---------------------------------------------------------------------------
// Advertised commands (rendered into the Fa system prompt)
// ---------------------------------------------------------------------------

// Shared entries, identical on web and mobile.
const _curl = SandboxCommand('curl', 'HTTP(S) requests and downloads');
const _wget = SandboxCommand('wget', 'HTTP(S) requests and downloads');
const _nslookup = SandboxCommand('nslookup', 'DNS lookup (over HTTPS)');
const _dig = SandboxCommand('dig', 'DNS lookup (over HTTPS)');
const _whois = SandboxCommand('whois', 'domain/IP lookup (RDAP over HTTPS)');
const _jq = SandboxCommand('jq', 'JSON processor');
const _yq = SandboxCommand('yq', 'YAML processor');
const _rg = SandboxCommand('rg', 'fast text search');
const _grep = SandboxCommand('grep', 'fast text search');
const _sed = SandboxCommand('sed', 'stream editor');
const _awk = SandboxCommand('awk', 'pattern-directed text processing');
const _diff = SandboxCommand('diff', 'compare and patch files');
const _patch = SandboxCommand('patch', 'compare and patch files');
const _tar = SandboxCommand('tar', 'tar archives');
const _gzip = SandboxCommand('gzip', 'gzip compression');
const _gunzip = SandboxCommand('gunzip', 'gzip compression');
const _zip = SandboxCommand('zip', 'zip archives');
const _unzip = SandboxCommand('unzip', 'zip archives');
const _xz = SandboxCommand('xz', 'xz decompression only');
const _unxz = SandboxCommand('unxz', 'xz decompression only');
const _bzip2 = SandboxCommand('bzip2', 'bzip2 decompression only');
const _bunzip2 = SandboxCommand('bunzip2', 'bzip2 decompression only');
const _tree = SandboxCommand('tree', 'directory tree view');
const _file = SandboxCommand('file', 'file type detection');
const _base64 = SandboxCommand('base64', 'base64 encode/decode');
const _md5sum = SandboxCommand('md5sum', 'checksums');
const _sha1sum = SandboxCommand('sha1sum', 'checksums');
const _sha224sum = SandboxCommand('sha224sum', 'checksums');
const _sha256sum = SandboxCommand('sha256sum', 'checksums');
const _sha384sum = SandboxCommand('sha384sum', 'checksums');
const _sha512sum = SandboxCommand('sha512sum', 'checksums');
const _qjs = SandboxCommand(
  'qjs',
  'QuickJS JavaScript engine (ES2023) — the ONLY JavaScript runtime; '
      'there is NO node/npm',
);
const _js = SandboxCommand(
  'js',
  'QuickJS JavaScript engine (ES2023) — the ONLY JavaScript runtime; '
      'there is NO node/npm',
);

/// The commands the Fa system prompt advertises for [platform], in prompt
/// order. Consecutive entries with an identical summary render merged as
/// `name1/name2 — summary`.
///
/// This is a curated view of [sandboxCommandNamesFor]: every advertised name
/// must resolve there, but the long tail of POSIX utilities is summarized by
/// the section's `core utilities:` line instead of individual bullets.
/// Desktop returns the empty list — the host shell has no fixed set.
List<SandboxCommand> sandboxCommandsFor(SandboxPlatform platform) =>
    switch (platform) {
      SandboxPlatform.web => _webCommands,
      SandboxPlatform.mobile => _mobileCommands,
      SandboxPlatform.desktop => const [],
    };

const _webCommands = <SandboxCommand>[
  SandboxCommand(
    'git',
    'local operations only (dart_git) — remote clone/fetch/push is '
        'blocked by browser CORS',
  ),
  _curl,
  _wget,
  _nslookup,
  _dig,
  _whois,
  _jq,
  _yq,
  _rg,
  _grep,
  _sed,
  _awk,
  _diff,
  _patch,
  _tar,
  _gzip,
  _gunzip,
  _zip,
  _unzip,
  _xz,
  _unxz,
  _bzip2,
  _bunzip2,
  _tree,
  _file,
  _base64,
  _md5sum,
  _sha1sum,
  _sha224sum,
  _sha256sum,
  _sha384sum,
  _sha512sum,
  SandboxCommand('sqlite3', 'SQLite CLI (sql.js, in-browser)'),
  SandboxCommand(
    'python3',
    'Python via pyodide (runs in the browser); no sockets',
  ),
  SandboxCommand(
    'python',
    'Python via pyodide (runs in the browser); no sockets',
  ),
  SandboxCommand('pip3', 'installs pure-Python wheels (micropip)'),
  SandboxCommand('pip', 'installs pure-Python wheels (micropip)'),
  _qjs,
  _js,
];

const _mobileCommands = <SandboxCommand>[
  SandboxCommand(
    'git',
    'local and remote: clone/fetch/push over HTTPS and SSH',
  ),
  SandboxCommand('ssh', 'remote access with key auth from ~/.ssh'),
  SandboxCommand('scp', 'remote access with key auth from ~/.ssh'),
  SandboxCommand('sftp', 'remote access with key auth from ~/.ssh'),
  _curl,
  _wget,
  _nslookup,
  _dig,
  _whois,
  _jq,
  _yq,
  _rg,
  _grep,
  _sed,
  _awk,
  _diff,
  _patch,
  _tar,
  // The gzip.wasm module handles both directions via -d; there is no
  // separate gunzip applet on mobile.
  SandboxCommand('gzip', 'gzip compression (-d to decompress)'),
  _zip,
  _unzip,
  _xz,
  _unxz,
  _bzip2,
  _bunzip2,
  _tree,
  _file,
  _base64,
  _md5sum,
  _sha1sum,
  _sha224sum,
  _sha256sum,
  _sha384sum,
  _sha512sum,
  SandboxCommand('sqlite3', 'SQLite CLI'),
  SandboxCommand(
    'python3',
    'CPython 3.14 with the standard library; no sockets',
  ),
  SandboxCommand(
    'python',
    'CPython 3.14 with the standard library; no sockets',
  ),
  SandboxCommand('pip3', 'installs pure-Python wheels only'),
  SandboxCommand('pip', 'installs pure-Python wheels only'),
  _qjs,
  _js,
  SandboxCommand('lua', 'Lua 5.1 interpreter'),
];

// ---------------------------------------------------------------------------
// Prompt section rendering
// ---------------------------------------------------------------------------

/// Shell-grammar commands covered by the "cd and exported variables persist"
/// bullet rather than the `core utilities:` line.
const _shellStateCommands = {
  'cd',
  'pwd',
  'export',
  'unset',
  'env',
  'true',
  'false',
  'test',
  '[',
  'which',
  'command',
  'whoami',
};

/// Web commands that are registered but always fail with exit 127 (see
/// [webShellCommandNames]); they are excluded from the `core utilities:` line
/// and named in the NOT-available line instead.
const _webNonFunctional = {'ssh', 'scp', 'sftp', 'lua'};

/// Renders the shell-capability section of the Fa system prompt for
/// [platform]: the sandboxed shells get the exact command list plus the
/// negative guidance (no node, no apt-get); desktop gets the host-shell
/// description.
String formatSandboxCommandSection(SandboxPlatform platform) {
  if (platform == SandboxPlatform.desktop) {
    return '- Shell: the host machine\'s full shell — bash runs directly on '
        'this machine, so any installed tool works (git, node, python3, '
        'make, ...).\n'
        '- cd and exported variables persist between bash calls. Your '
        'working directory is your workspace.';
  }

  final commands = sandboxCommandsFor(platform);
  final advertised = commands.map((c) => c.name).toSet();
  final coreNames =
      sandboxCommandNamesFor(platform)
          .difference(advertised)
          .difference(_shellStateCommands)
          .difference(
            platform == SandboxPlatform.web
                ? _webNonFunctional
                : const <String>{},
          )
          .toList()
        ..sort();

  final buffer = StringBuffer()
    ..writeln(
      '- Shell (sandboxed — ONLY the commands below exist; anything else '
      'fails with exit 127 "command not found"):',
    )
    ..writeln('  - core utilities: ${coreNames.join(' ')}');

  var i = 0;
  while (i < commands.length) {
    var j = i + 1;
    while (j < commands.length && commands[j].summary == commands[i].summary) {
      j++;
    }
    final label = commands.sublist(i, j).map((c) => c.name).join('/');
    buffer.writeln('  - $label — ${commands[i].summary}');
    i = j;
  }

  buffer
    ..writeln(
      '- cd and exported variables persist between bash calls. The sandbox '
      'root / is your writable workspace.',
    )
    ..write('- NOT available: ${_notAvailable(platform)}');
  return buffer.toString();
}

/// The per-platform negative guidance: what the model must NOT attempt.
String _notAvailable(SandboxPlatform platform) {
  const noNode = 'node/npm (JavaScript here is qjs/js — QuickJS, NOT node)';
  const noPackages =
      'There is no package manager and no root: NEVER run apt-get/sudo or '
      'try to install system packages.';
  return switch (platform) {
    SandboxPlatform.web =>
      '$noNode, make, gcc/cc, ssh/scp/sftp (browsers cannot open raw TCP '
          'connections), lua, remote git (blocked by CORS). $noPackages',
    SandboxPlatform.mobile => '$noNode, make, gcc/cc. $noPackages',
    SandboxPlatform.desktop => '',
  };
}
