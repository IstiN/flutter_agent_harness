// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_git/dart_git.dart' as dart_git;
import 'package:dart_git/exceptions.dart';
import 'package:dart_git/plumbing/commit_iterator.dart';
import 'package:dart_git/plumbing/git_hash.dart';
import 'package:dart_git/plumbing/objects/blob.dart';
import 'package:dart_git/plumbing/objects/object.dart';
import 'package:dart_git/plumbing/reference.dart';
import 'package:dart_git/status.dart';
import 'package:dart_git/utils/file_mode.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:path/path.dart' as p;

import 'package:fa/sandbox/git_smart_http.dart';
import 'package:fa/sandbox/shell_parser.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:http/http.dart' as http;

/// The slice of [WasiSandboxShell] the git porcelain needs: sandbox path
/// mapping, the current directory, the shared HTTP client and the WASM
/// `tar` runner (clone-from-tarball). An interface, so the command set is
/// unit-testable against a plain Dart host (no WASM modules required).
abstract interface class GitShellHost {
  /// Host directory exposed to the WASM guest at `/`.
  String? get sandboxHostPath;

  /// Current working directory of the shell.
  String get shellCwd;

  /// Host path for a sandbox-absolute path.
  String hostPathOf(String sandboxPath);

  /// HTTP client used by network builtins (smart HTTP / tarball clone).
  http.Client get shellHttpClient;

  /// Runs a sandbox command (the `tar` extraction of a tarball clone).
  Future<Result<StageResult, ExecutionError>> runSandboxCommand(
    String command,
    List<String> args,
  );
}

/// Pure split of the `git [-C <path>]` prologue (issue #475): scans for
/// the FIRST `-C` — at any position, as the old router did — removes it
/// with its value, and returns the option value (`cDir`, `null` when
/// absent) plus `rest`, the remaining command line. `error` is set when
/// `-C` has no value; an empty `rest` means "no command given" (the
/// caller answers with the usage line, as before).
({String? error, String? cDir, List<String> rest}) parseGitPrologue(
  List<String> args,
) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] != '-C') continue;
    if (i + 1 >= args.length) {
      return (
        error: 'fatal: option -C requires a value',
        cDir: null,
        rest: const <String>[],
      );
    }
    return (
      error: null,
      cDir: args[i + 1],
      rest: [...args.sublist(0, i), ...args.sublist(i + 2)],
    );
  }
  return (error: null, cDir: null, rest: args);
}

/// One `git <command>` handler bound to an invocation's repo/context.
typedef _GitCommandHandler =
    FutureOr<Result<StageResult, ExecutionError>> Function(List<String> args);

/// Pure-Dart git porcelain for the WASM sandbox, backed by `dart_git` for
/// local operations and the GitHub tarball API for `git clone`.
final class GitSandboxCommands {
  /// Creates the command set bound to [shell].
  GitSandboxCommands(this._shell);

  final GitShellHost _shell;

  /// Runs the parsed git command line against the sandbox repository.
  ///
  /// Route-table dispatch (the `JsAppEngine._faCall` pattern, issue #475):
  /// the old if-chain + 17-case switch was CC 29 / CRAP 870 at 0% coverage
  /// — the app ratchet's worst. The `-C` prologue, the version answer and
  /// the repo-free/repo-bound routing keep their exact previous semantics,
  /// including the not-a-repository and unknown-command errors.
  Future<Result<StageResult, ExecutionError>> run(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final prologue = parseGitPrologue(stage.args);
    final prologueError = prologue.error;
    if (prologueError != null) return _gitError(prologueError);
    if (prologue.rest.isEmpty) {
      return _gitError(
        'usage: git [--version] [--help] [-C <path>] <command> [<args>]',
      );
    }

    final subcommand = prologue.rest.first;
    final env = options?.env;
    final hostCwd = _shell.hostPathOf(
      prologue.cDir ?? options?.cwd ?? _shell.shellCwd,
    );

    // Commands that do not require an existing repository (plus the
    // --version answer) route first, exactly as before.
    final repoFree = _repoFreeCommands(hostCwd, env)[subcommand];
    if (repoFree != null) return repoFree(prologue.rest.sublist(1));

    final root = _findGitRoot(hostCwd);
    if (root == null) {
      return _gitError(
        'fatal: not a git repository (or any of the parent directories): .git',
      );
    }

    try {
      final repo = dart_git.GitRepository.load(root);
      final handler = _repoCommands(repo, hostCwd, env)[subcommand];
      if (handler == null) {
        return _gitError('git: \'$subcommand\' is not a git command.');
      }
      return await handler(prologue.rest.sublist(1));
    } catch (e) {
      return _gitError('error: $e');
    }
  }

  /// Command families that run without an existing repository. Built per
  /// invocation: the handlers bind this call's cwd and environment.
  Map<String, _GitCommandHandler> _repoFreeCommands(
    String hostCwd,
    Map<String, String>? env,
  ) => {
    '--version': _gitVersion,
    '-v': _gitVersion,
    'clone': (args) => _gitClone(args, hostCwd, env),
    'init': (args) => _gitInit(args, hostCwd),
  };

  /// Command families that require a loaded repository. Built per
  /// invocation: the handlers bind this call's repo, cwd and environment.
  Map<String, _GitCommandHandler> _repoCommands(
    dart_git.GitRepository repo,
    String hostCwd,
    Map<String, String>? env,
  ) => {
    'add': (args) => _gitAdd(repo, args, hostCwd),
    'rm': (args) => _gitRm(repo, args, hostCwd),
    'commit': (args) => _gitCommit(repo, args, env),
    'log': (args) => _gitLog(repo, args),
    'status': (_) => _gitStatus(repo),
    'branch': (args) => _gitBranch(repo, args),
    'checkout': (args) => _gitCheckout(repo, args, hostCwd),
    'remote': (args) => _remoteGuarded(() => _gitRemote(repo, args)),
    'fetch': (args) => _gitFetch(repo, args, env),
    'push': (args) => _gitPush(repo, args, env),
    'show': (args) => _gitShow(repo, args),
    'cat-file': (args) => _gitCatFile(repo, args),
    'hash-object': (args) => _gitHashObject(repo, args, hostCwd),
    'ls-tree': (args) => _gitLsTree(repo, args),
    'write-tree': (_) => _gitWriteTree(repo),
    'merge-base': (args) => _gitMergeBase(repo, args),
    'reset': (args) => _gitReset(repo, args),
  };

  /// The `git --version` / `git -v` answer (identical string as before).
  Result<StageResult, ExecutionError> _gitVersion(List<String> _) => Ok(
    StageResult(
      stdout: utf8.encode('git version 2.47.0-Fa\n'),
      stderr: const [],
      exitCode: 0,
    ),
  );

  Result<StageResult, ExecutionError> _gitError(String message) => Ok(
    StageResult(
      stdout: const [],
      stderr: utf8.encode('$message\n'),
      exitCode: 1,
    ),
  );

  Future<Result<StageResult, ExecutionError>> _gitClone(
    List<String> args,
    String hostCwd,
    Map<String, String>? env,
  ) async {
    if (args.isEmpty) {
      return _gitError('usage: git clone <repository> [<directory>]');
    }
    final repoUrl = args[0];
    final dest = cloneDestination(repoUrl, args);
    final hostDest = _resolveGitPath(dest, hostCwd);
    final notEmpty = _cloneDestNotEmpty(hostDest, dest);
    if (notEmpty != null) return _gitError(notEmpty);
    return _cloneByTransport(repoUrl, dest, hostDest, env);
  }

  /// Routes a clone to its transport: SSH URLs over dartssh2, http(s)
  /// over smart HTTP (falling back to the GitHub tarball API only when
  /// the endpoint did not speak the protocol before any local state was
  /// created), and everything else straight to the tarball API.
  Future<Result<StageResult, ExecutionError>> _cloneByTransport(
    String repoUrl,
    String dest,
    String hostDest,
    Map<String, String>? env,
  ) async {
    // SSH URLs (git@host:owner/repo.git, ssh://...) go over dartssh2.
    final sshTransport = _sshTransportFor(repoUrl, env);
    if (sshTransport != null) {
      try {
        await GitSmartHttp(
          transport: sshTransport,
        ).cloneInto(url: repoUrl, hostDir: hostDest);
        return _clonedInto(dest);
      } catch (e) {
        return _gitError('fatal: unable to clone: $e');
      }
    }

    // Preferred path: a real smart-HTTP clone (works with any public git
    // remote, not just GitHub).
    if (repoUrl.startsWith('http://') || repoUrl.startsWith('https://')) {
      try {
        await GitSmartHttp(
          client: _shell.shellHttpClient,
        ).cloneInto(url: repoUrl, hostDir: hostDest);
        return _clonedInto(dest);
      } catch (e) {
        // Fall back to the GitHub tarball API only when the smart path
        // failed BEFORE creating any local state (i.e. the endpoint does
        // not speak the protocol). A later failure is reported as-is so the
        // original error is not masked by the fallback's GitRepoExists.
        final partial = io.Directory(p.join(hostDest, '.git')).existsSync();
        if (partial || _parseGitHubRepo(repoUrl) == null) {
          return _gitError('fatal: unable to clone: $e');
        }
      }
    }

    return _gitCloneGitHubTarball(repoUrl, dest, hostDest);
  }

  /// The success answer for a finished clone.
  Result<StageResult, ExecutionError> _clonedInto(String dest) => Ok(
    StageResult(
      stdout: utf8.encode('Cloned into \'$dest\'\n'),
      stderr: const [],
      exitCode: 0,
    ),
  );

  /// Pure destination pick for `git clone` (issue #475): the explicit
  /// non-flag argument, else the URL's basename without extension.
  static String cloneDestination(String repoUrl, List<String> args) =>
      args.length > 1 && !args[1].startsWith('-')
      ? args[1]
      : p.basenameWithoutExtension(repoUrl);

  /// Real git refuses to clone into a non-empty directory; returns the
  /// fatal message when [hostDest] exists with a `.git` or any content,
  /// `null` when the destination is usable.
  String? _cloneDestNotEmpty(String hostDest, String dest) {
    final destDir = io.Directory(hostDest);
    if (!destDir.existsSync()) return null;
    final hasGitDir = io.Directory(p.join(hostDest, '.git')).existsSync();
    final isEmpty = destDir.listSync(followLinks: false).isEmpty;
    if (hasGitDir || !isEmpty) {
      return "fatal: destination path '$dest' already exists and is not an "
          'empty directory.';
    }
    return null;
  }

  Future<Result<StageResult, ExecutionError>> _gitCloneGitHubTarball(
    String repoUrl,
    String dest,
    String hostDest,
  ) async {
    final githubRepo = _parseGitHubRepo(repoUrl);
    if (githubRepo == null) {
      return _gitError(
        'git clone: unsupported repository URL '
        '(smart HTTP failed and this is not a GitHub URL)',
      );
    }
    final (:owner, :repo) = githubRepo;
    final archiveUrl = 'https://api.github.com/repos/$owner/$repo/tarball';

    try {
      final response = await _shell.shellHttpClient.get(Uri.parse(archiveUrl));
      if (response.statusCode != 200) {
        return _gitError(
          'git clone: failed to download archive: HTTP ${response.statusCode}',
        );
      }

      final archiveFile = io.File(p.join(hostDest, '.fah_clone.tar.gz'));
      await archiveFile.parent.create(recursive: true);
      await archiveFile.writeAsBytes(response.bodyBytes);

      final tarFile = io.File(p.join(hostDest, '.fah_clone.tar'));
      await tarFile.writeAsBytes(io.gzip.decode(archiveFile.readAsBytesSync()));

      final tarSandboxPath = _sandboxPath(tarFile.path);
      final destSandboxPath = _sandboxPath(hostDest);
      final tarResult = await _shell.runSandboxCommand('tar', [
        '-xf',
        tarSandboxPath,
        '-C',
        destSandboxPath,
      ]);
      if (tarResult.isErr) return tarResult;
      final tarData = tarResult.valueOrNull!;
      if (tarData.exitCode != 0) {
        final errMsg = utf8.decode(tarData.stderr, allowMalformed: true);
        return _gitError('git clone: tar extraction failed: $errMsg');
      }
      await archiveFile.delete();
      await tarFile.delete();

      // GitHub tarballs unpack into a single `owner-repo-sha` directory.
      // Move the contents up so the destination itself is the repository root.
      final entries = await io.Directory(hostDest).list().toList();
      final innerDir = entries.whereType<io.Directory>().firstOrNull;
      if (innerDir != null) {
        await for (final entity in innerDir.list()) {
          final name = p.basename(entity.path);
          final target = p.join(hostDest, name);
          await entity.rename(target);
        }
        await innerDir.delete();
      }

      // Initialize a git repo so subsequent git commands work on the clone.
      dart_git.GitRepository.init(hostDest);

      return Ok(
        StageResult(
          stdout: utf8.encode('Cloned into \'$dest\'\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: unable to clone: $e');
    }
  }

  ({String owner, String repo})? _parseGitHubRepo(String url) {
    final https = RegExp(r'https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$');
    final match = https.firstMatch(url);
    if (match != null) {
      return (owner: match.group(1)!, repo: match.group(2)!);
    }
    final ssh = RegExp(r'git@github\.com:([^/]+)/([^/]+?)(?:\.git)?/?$');
    final sshMatch = ssh.firstMatch(url);
    if (sshMatch != null) {
      return (owner: sshMatch.group(1)!, repo: sshMatch.group(2)!);
    }
    return null;
  }

  /// Builds an [SshGitTransport] for `git@host:path` / `ssh://` URLs, or
  /// `null` for non-SSH URLs. The private key comes from `GIT_SSH_KEY`
  /// (inline PEM), `GIT_SSH_KEY_PATH` (a sandbox path), or the default
  /// `/.ssh/id_ed25519` / `/.ssh/id_rsa` files when present.
  SshGitTransport? _sshTransportFor(String repoUrl, Map<String, String>? env) {
    String? host;
    String? username;
    String? repoPath;
    var port = 22;

    final scpLike = RegExp(r'^([\w.-]+)@([\w.-]+):(.+)$').firstMatch(repoUrl);
    if (scpLike != null) {
      username = scpLike.group(1)!;
      host = scpLike.group(2)!;
      repoPath = '/${scpLike.group(3)!}';
    } else if (repoUrl.startsWith('ssh://')) {
      final uri = Uri.parse(repoUrl);
      host = uri.host;
      username = uri.userInfo.isNotEmpty ? uri.userInfo : 'git';
      if (uri.hasPort) port = uri.port;
      repoPath = uri.path;
    } else {
      return null;
    }

    final pem = resolveSshKeyPem(
      env: env,
      platformEnv: io.Platform.environment,
      hostPathOf: _shell.hostPathOf,
    );
    if (pem == null) {
      throw StateError(
        'no SSH key: set GIT_SSH_KEY (PEM) or GIT_SSH_KEY_PATH, '
        'or place a key at /.ssh/id_ed25519',
      );
    }
    return SshGitTransport(
      host: host,
      username: username,
      repoPath: repoPath,
      privateKeyPem: pem,
      port: port,
    );
  }


  /// PEM body of the SSH key the git SSH transport should present:
  /// `GIT_SSH_KEY` (inline) or `GIT_SSH_KEY_PATH` from [env] then the
  /// process environment, then the sandbox defaults `/.ssh/id_ed25519` and
  /// `/.ssh/id_rsa`. [platformEnv] and [hostPathOf] are injectable for the
  /// unit tables (issue #568). Returns null when nothing holds a PEM body.
  static String? resolveSshKeyPem({
    Map<String, String>? env,
    required Map<String, String> platformEnv,
    required String Function(String) hostPathOf,
  }) {
    final inline = env?['GIT_SSH_KEY'] ?? platformEnv['GIT_SSH_KEY'];
    if (inline != null && inline.contains('PRIVATE KEY')) return inline;
    final keyPath =
        env?['GIT_SSH_KEY_PATH'] ?? platformEnv['GIT_SSH_KEY_PATH'];
    final candidates = <String>[?keyPath, '/.ssh/id_ed25519', '/.ssh/id_rsa'];
    for (final candidate in candidates) {
      final pem = _pemAt(hostPathOf(candidate));
      if (pem != null) return pem;
    }
    return null;
  }

  /// [path]'s contents when it exists and holds a PEM body, else null.
  static String? _pemAt(String path) {
    final file = io.File(path);
    if (!file.existsSync()) return null;
    final content = file.readAsStringSync();
    return content.contains('PRIVATE KEY') ? content : null;
  }

  Future<Result<StageResult, ExecutionError>> _gitInit(
    List<String> args,
    String hostCwd,
  ) async {
    var path = hostCwd;
    String? virtualName;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--bare' || arg == '--shared') {
        return _gitError('git init: unsupported flag $arg');
      }
      if (arg == '-b' || arg == '--initial-branch') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option $arg requires a value');
        }
        i++;
        continue;
      }
      if (!arg.startsWith('-')) {
        virtualName = arg;
        path = _resolveGitPath(arg, hostCwd);
      }
    }

    try {
      dart_git.GitRepository.init(path);
      final display = virtualName ?? path;
      return Ok(
        StageResult(
          stdout: utf8.encode(
            'Initialized empty Git repository in $display/.git/\n',
          ),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitAdd(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git add <pathspec>...');
    }
    try {
      for (final arg in args.where((a) => !a.startsWith('-'))) {
        repo.add(_resolveGitPath(arg, hostCwd));
      }
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitRm(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git rm <pathspec>...');
    }
    try {
      for (final arg in args.where((a) => !a.startsWith('-'))) {
        repo.rm(_resolveGitPath(arg, hostCwd));
      }
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitCommit(
    dart_git.GitRepository repo,
    List<String> args,
    Map<String, String>? env,
  ) {
    String? message;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-m' || arg == '--message') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option $arg requires a value');
        }
        message = args[i + 1];
        i++;
      }
    }
    if (message == null || message.isEmpty) {
      return _gitError(
        'fatal: cannot create an empty commit without a message',
      );
    }

    final author = _gitAuthor(env);
    try {
      final commit = repo.commit(
        message: message,
        author: author,
        committer: author,
      );
      return Ok(
        StageResult(
          stdout: utf8.encode(
            '[${repo.currentBranch()} ${commit.hash.toOid()}] $message\n',
          ),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } on GitEmptyCommit {
      return _gitError(
        'On branch ${repo.currentBranch()}\nnothing to commit, working tree clean',
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  dart_git.GitAuthor _gitAuthor(Map<String, String>? env) {
    final name =
        env?['GIT_AUTHOR_NAME'] ??
        io.Platform.environment['GIT_AUTHOR_NAME'] ??
        'Fa';
    final email =
        env?['GIT_AUTHOR_EMAIL'] ??
        io.Platform.environment['GIT_AUTHOR_EMAIL'] ??
        'fa@example.com';
    return dart_git.GitAuthor(name: name, email: email);
  }

  Result<StageResult, ExecutionError> _gitLog(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    var maxCount = 0;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-n' || arg == '--max-count') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option $arg requires a value');
        }
        maxCount = int.tryParse(args[i + 1]) ?? 0;
        i++;
      }
    }

    try {
      final from = repo.headHash();
      final commits = commitIteratorBFS(
        objStorage: repo.objStorage,
        from: from,
      );
      final lines = <String>[];
      var count = 0;
      for (final commit in commits) {
        if (maxCount > 0 && count >= maxCount) break;
        final msg = commit.message.trim().split('\n').first;
        lines.add('${commit.hash.toOid()} $msg');
        count++;
      }
      return Ok(
        StageResult(
          stdout: utf8.encode(lines.isEmpty ? '' : '${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitStatus(dart_git.GitRepository repo) {
    try {
      final result = repo.status();
      bool notGitEntry(String f) =>
          f != '.git' && !f.endsWith('/.git') && !f.contains('/.git/');
      final added = result.added.where(notGitEntry).toList();
      final modified = result.modified.where(notGitEntry).toList();
      final removed = result.removed.where(notGitEntry).toList();

      final lines = <String>[];
      if (added.isNotEmpty) {
        lines.add('Untracked:');
        for (final f in added) {
          lines.add('  ${repo.toPathSpec(f)}');
        }
      }
      if (modified.isNotEmpty) {
        lines.add('Modified:');
        for (final f in modified) {
          lines.add('  ${repo.toPathSpec(f)}');
        }
      }
      if (removed.isNotEmpty) {
        lines.add('Deleted:');
        for (final f in removed) {
          lines.add('  ${repo.toPathSpec(f)}');
        }
      }
      if (lines.isEmpty) {
        lines.add('nothing to commit, working tree clean');
      }
      return Ok(
        StageResult(
          stdout: utf8.encode('${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitBranch(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    final parsed = parseBranchArgs(args);
    final branchError = parsed.error;
    if (branchError != null) return _gitError(branchError);
    final positional = parsed.positional;

    try {
      if (parsed.delete) {
        if (positional.isEmpty) {
          return _gitError('usage: git branch -d <branch>');
        }
        repo.deleteBranch(positional.first);
        return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
      }
      if (parsed.listRemote || parsed.listAll) {
        return _branchListWithRemotes(repo, listAll: parsed.listAll);
      }
      if (positional.isEmpty) return _branchListLocal(repo);
      repo.createBranch(positional.first);
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  /// `git branch [-r | -a]`: local branches (with `-a`) then remote
  /// tracking refs — the same line shapes the old inline block produced.
  Result<StageResult, ExecutionError> _branchListWithRemotes(
    dart_git.GitRepository repo, {
    required bool listAll,
  }) {
    final lines = <String>[
      if (listAll) ..._localListingLines(repo),
      ..._remoteListingLines(repo),
    ];
    return Ok(
      StageResult(
        stdout: utf8.encode(lines.isEmpty ? '' : '${lines.join('\n')}\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  /// Sorted local branches, `* ` on the current one (the plain `git branch`
  /// and `-a` listing body).
  List<String> _localListingLines(dart_git.GitRepository repo) {
    final current = repo.currentBranch();
    final branches = repo.branches()..sort();
    return [for (final b in branches) b == current ? '* $b' : '  $b'];
  }

  /// Sorted remote-tracking ref names, `refs/remotes/` stripped.
  List<String> _remoteListingLines(dart_git.GitRepository repo) {
    final remoteRefs = repo.refStorage.listReferences('refs/remotes/')
      ..sort((a, b) => a.name.value.compareTo(b.name.value));
    return [
      for (final ref in remoteRefs)
        ref.name.value.substring('refs/remotes/'.length),
    ];
  }

  /// `git branch` with no arguments: sorted local branches, `* ` on the
  /// current one.
  Result<StageResult, ExecutionError> _branchListLocal(
    dart_git.GitRepository repo,
  ) {
    final lines = _localListingLines(repo);
    return Ok(
      StageResult(
        stdout: utf8.encode('${lines.join('\n')}\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  /// Pure arg split for `git branch` (issue #475): `-r` / `-a` list
  /// flags, `-d`/`-D` delete, any other option is the same unknown-option
  /// error as before; everything non-flag is positional.
  static ({
    String? error,
    bool listRemote,
    bool listAll,
    bool delete,
    List<String> positional,
  })
  parseBranchArgs(List<String> args) {
    var listRemote = false;
    var listAll = false;
    var delete = false;
    final positional = <String>[];
    for (final arg in args) {
      if (arg == '-r') {
        listRemote = true;
      } else if (arg == '-a') {
        listAll = true;
      } else if (arg == '-d' || arg == '-D') {
        delete = true;
      } else if (arg.startsWith('-')) {
        return (
          error: 'git branch: unknown option $arg',
          listRemote: false,
          listAll: false,
          delete: false,
          positional: const <String>[],
        );
      } else {
        positional.add(arg);
      }
    }
    return (
      error: null,
      listRemote: listRemote,
      listAll: listAll,
      delete: delete,
      positional: positional,
    );
  }

  /// Pure arg split for `git push` (issue #568): flags are ignored, the
  /// first two positionals are `[remote] [branch]`; the branch defaults to
  /// the current branch (null when detached — the caller answers with the
  /// not-on-branch fatal, exactly as before).
  static ({String remoteName, String? branch}) parsePushArgs(
    List<String> args,
    String? currentBranch,
  ) {
    final positional = <String>[
      for (final arg in args)
        if (!arg.startsWith('-')) arg,
    ];
    return (
      remoteName: positional.isNotEmpty ? positional[0] : 'origin',
      branch: positional.length > 1 ? positional[1] : currentBranch,
    );
  }

  /// Env var names a push token may ride, in precedence order.
  static const _pushTokenVars = ['GITHUB_TOKEN', 'GIT_TOKEN', 'FAH_GIT_TOKEN'];

  /// Token auth for GitHub-style HTTPS push remotes: the shell environment
  /// ([env]) first, then the process environment — the same precedence as
  /// the old inline `??` chain. [platformEnv] injects
  /// `io.Platform.environment` for the unit tables.
  static String? resolvePushToken(
    Map<String, String>? env,
    Map<String, String> platformEnv,
  ) => _firstDefined(env, _pushTokenVars) ??
      _firstDefined(platformEnv, _pushTokenVars);

  static String? _firstDefined(Map<String, String>? env, List<String> names) {
    for (final name in names) {
      final value = env?[name];
      if (value != null) return value;
    }
    return null;
  }

  /// `dart_git` work trees carry a trailing slash; the smart-HTTP host dir
  /// must not (pure).
  static String stripTrailingSlash(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// Updates `refs/remotes/<remoteName>/<branch>` to the just-pushed local
  /// hash after a successful push (best-effort: no local branch → no-op).
  static void trackPushedRef(
    dart_git.GitRepository repo,
    String remoteName,
    String branch,
  ) {
    final localRef = repo.resolveReferenceName(ReferenceName.branch(branch));
    if (localRef == null) return;
    repo.refStorage.saveRef(
      HashReference(ReferenceName.remote(remoteName, branch), localRef.hash),
    );
  }

  /// `git checkout [-b] <branch>|<path>`: a local branch switches, a
  /// resolvable hash/remote-ref detaches HEAD, anything else restores a
  /// path — each form in its own helper below.
  Result<StageResult, ExecutionError> _gitCheckout(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    var create = false;
    final positional = <String>[];
    for (final arg in args) {
      if (arg == '-b') {
        create = true;
      } else if (!arg.startsWith('-')) {
        positional.add(arg);
      }
    }
    if (positional.isEmpty) {
      return _gitError('usage: git checkout [-b] <branch>|<path>');
    }
    final target = positional.first;

    try {
      if (create) {
        return _checkoutNewBranch(
          repo,
          target,
          startPoint: positional.length > 1 ? positional[1] : 'HEAD',
        );
      }
      if (repo.branches().contains(target)) {
        repo.checkoutBranch(target);
        return Ok(
          StageResult(
            stdout: utf8.encode('Switched to branch \'$target\'\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      return _checkoutDetachedOrPath(repo, target, hostCwd);
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  /// `git checkout -b <branch> [<start-point>]`: create from the resolved
  /// start point (HEAD by default) and switch to it.
  Result<StageResult, ExecutionError> _checkoutNewBranch(
    dart_git.GitRepository repo,
    String target, {
    required String startPoint,
  }) {
    final hash = _gitResolveHash(repo, startPoint);
    if (hash == null) {
      return _gitError(
        "fatal: '$startPoint' is not a commit and a branch "
        "'$target' cannot be created from it",
      );
    }
    repo.createBranch(target, hash: hash);
    repo.checkoutBranch(target);
    return Ok(
      StageResult(
        stdout: utf8.encode('Switched to a new branch \'$target\'\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  /// Not a local branch: a resolvable remote ref / full hash is a
  /// detached-HEAD checkout, anything else is a path checkout.
  Result<StageResult, ExecutionError> _checkoutDetachedOrPath(
    dart_git.GitRepository repo,
    String target,
    String hostCwd,
  ) {
    final hash = _gitResolveHash(repo, target);
    if (hash != null) {
      repo.refStorage.saveRef(HashReference(ReferenceName.HEAD(), hash));
      repo.checkout(repo.workTree);
      return Ok(
        StageResult(
          stdout: utf8.encode(
            'Note: switching to \'$target\'.\n'
            'You are in \'detached HEAD\' state.\n'
            'HEAD is now at ${hash.toOid()}\n',
          ),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }
    // Otherwise treat the target as a path checkout.
    final count = repo.checkout(_resolveGitPath(target, hostCwd));
    return Ok(
      StageResult(
        stdout: utf8.encode('Updated $count paths\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  /// Resolves [spec] to a commit hash: HEAD, a local branch, a remote ref
  /// (e.g. `origin/main`), or a full 40-char hash. Returns `null` when the
  /// spec cannot be resolved.
  GitHash? _gitResolveHash(dart_git.GitRepository repo, String spec) {
    try {
      if (spec == 'HEAD') return repo.headHash();
      if (repo.branches().contains(spec)) {
        return repo.resolveReferenceName(ReferenceName.branch(spec))!.hash;
      }
      if (spec.contains('/')) {
        final remoteRef = repo.resolveReferenceName(
          ReferenceName('refs/remotes/$spec'),
        );
        if (remoteRef != null) return remoteRef.hash;
      }
      if (RegExp(r'^[0-9a-f]{40}$').hasMatch(spec)) return GitHash(spec);
    } on Object {
      return null;
    }
    return null;
  }

  /// `git remote` dispatch (issue #475): one helper per subcommand, the
  /// same usage/not-found errors and the same remote exception mapping
  /// the old inline chain produced (via [_remoteGuarded]).
  Result<StageResult, ExecutionError> _gitRemote(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.isEmpty) return _remoteList(repo);
    final action = args[0];
    switch (action) {
      case '-v':
      case '--verbose':
        return _remoteVerbose(repo);
      case 'add':
        return _remoteAdd(repo, args);
      case 'remove':
      case 'rm':
        return _remoteRemove(repo, args);
      case 'get-url':
        return _remoteGetUrl(repo, args);
    }
    return _gitError('git remote: unknown subcommand $action');
  }

  /// Exception mapping for the remote family: dart_git's typed remote
  /// errors become the same fatal lines the old chain produced. Action
  /// helpers run under it; the unknown-subcommand answer routes through
  /// it too, so the error shape stays identical.
  Result<StageResult, ExecutionError> _remoteGuarded(
    Result<StageResult, ExecutionError> Function() action,
  ) {
    try {
      return action();
    } on GitRemoteAlreadyExists catch (e) {
      return _gitError('fatal: remote ${e.name} already exists.');
    } on GitRemoteNotFound catch (e) {
      return _gitError('fatal: No such remote: ${e.name}');
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  /// `git remote`: sorted remote names, newline-separated.
  Result<StageResult, ExecutionError> _remoteList(dart_git.GitRepository repo) {
    final names = repo.config.remotes.map((r) => r.name).toList()..sort();
    return Ok(
      StageResult(
        stdout: utf8.encode(names.isEmpty ? '' : '${names.join('\n')}\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  /// `git remote -v`: one `name\turl (fetch|push)` line pair per remote.
  Result<StageResult, ExecutionError> _remoteVerbose(
    dart_git.GitRepository repo,
  ) {
    final lines = <String>[
      for (final r in repo.config.remotes) ...[
        '${r.name}\t${r.url} (fetch)',
        '${r.name}\t${r.url} (push)',
      ],
    ];
    return Ok(
      StageResult(
        stdout: utf8.encode(lines.isEmpty ? '' : '${lines.join('\n')}\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  /// `git remote add <name> <url>`.
  Result<StageResult, ExecutionError> _remoteAdd(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 3) {
      return _gitError('usage: git remote add <name> <url>');
    }
    repo.addRemote(args[1], args[2]);
    return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
  }

  /// `git remote remove <name>` / `git remote rm <name>`.
  Result<StageResult, ExecutionError> _remoteRemove(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _gitError('usage: git remote remove <name>');
    }
    repo.removeRemote(args[1]);
    return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
  }

  /// `git remote get-url <name>`.
  Result<StageResult, ExecutionError> _remoteGetUrl(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _gitError('usage: git remote get-url <name>');
    }
    final remote = repo.config.remote(args[1]);
    if (remote == null) {
      return _gitError("fatal: No such remote '${args[1]}'");
    }
    return Ok(
      StageResult(
        stdout: utf8.encode('${remote.url}\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _gitFetch(
    dart_git.GitRepository repo,
    List<String> args,
    Map<String, String>? env,
  ) async {
    final remoteName = args.isEmpty ? 'origin' : args.first;
    final remote = repo.config.remote(remoteName);
    if (remote == null) {
      return _gitError(
        "fatal: '$remoteName' does not appear to be a git repository",
      );
    }
    final url = remote.url;
    if (url.isEmpty) {
      return _gitError('fatal: no URL configured for remote $remoteName');
    }

    try {
      final moved =
          await GitSmartHttp(
            client: _shell.shellHttpClient,
            transport: _sshTransportFor(url, env),
          ).fetchInto(
            url: url,
            hostDir: repo.workTree.endsWith('/')
                ? repo.workTree.substring(0, repo.workTree.length - 1)
                : repo.workTree,
            remoteName: remoteName,
          );
      final lines = <String>['From $url'];
      for (final branch in moved) {
        lines.add(' * [new branch] $branch -> $remoteName/$branch');
      }
      return Ok(
        StageResult(
          stdout: utf8.encode('${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: unable to fetch: $e');
    }
  }

  Future<Result<StageResult, ExecutionError>> _gitPush(
    dart_git.GitRepository repo,
    List<String> args,
    Map<String, String>? env,
  ) async {
    final targets = parsePushArgs(args, _safeCurrentBranch(repo));
    if (targets.branch == null) {
      return _gitError('fatal: You are not currently on a branch.');
    }
    final remote = repo.config.remote(targets.remoteName);
    if (remote == null) {
      return _gitError(
        "fatal: '${targets.remoteName}' does not appear to be a git repository",
      );
    }
    if (remote.url.isEmpty) {
      return _gitError(
        'fatal: no URL configured for remote ${targets.remoteName}',
      );
    }
    return _pushToRemote(repo, targets.remoteName, remote.url, targets.branch!, env);
  }

  /// Pushes [branch] to the guarded remote URL and updates the local
  /// remote-tracking ref on success (the old inline tail of `_gitPush`).
  Future<Result<StageResult, ExecutionError>> _pushToRemote(
    dart_git.GitRepository repo,
    String remoteName,
    String url,
    String branch,
    Map<String, String>? env,
  ) async {
    try {
      final report =
          await GitSmartHttp(
            client: _shell.shellHttpClient,
            transport: _sshTransportFor(url, env),
          ).pushInto(
            url: url,
            hostDir: stripTrailingSlash(repo.workTree),
            branch: branch,
            token: resolvePushToken(env, io.Platform.environment),
          );
      // Update the local remote-tracking ref after a successful push.
      trackPushedRef(repo, remoteName, branch);
      return Ok(
        StageResult(
          stdout: utf8.encode('To $url\n * $branch -> $branch\n$report\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: unable to push: $e');
    }
  }

  String? _safeCurrentBranch(dart_git.GitRepository repo) {
    try {
      return repo.currentBranch();
    } on Object {
      return null;
    }
  }

  Result<StageResult, ExecutionError> _gitShow(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    final spec = args.isEmpty
        ? 'HEAD'
        : args.firstWhere((a) => !a.startsWith('-'));
    final colonIdx = spec.indexOf(':');
    try {
      if (colonIdx == -1) {
        final commit = _gitResolveCommit(repo, spec);
        final lines = <String>[
          'commit ${commit.hash}',
          'Author: ${commit.author.name} <${commit.author.email}>',
          'Date:   ${commit.author.date}',
          '',
          commit.message.trim(),
        ];
        return Ok(
          StageResult(
            stdout: utf8.encode('${lines.join('\n')}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }

      final commitish = spec.substring(0, colonIdx);
      final pathSpec = spec.substring(colonIdx + 1);
      final commit = _gitResolveCommit(repo, commitish);
      final tree = repo.objStorage.readTree(commit.treeHash);
      final entry = repo.objStorage.refSpec(tree, pathSpec);
      final blob = repo.objStorage.readBlob(entry.hash);
      return Ok(
        StageResult(stdout: blob.blobData, stderr: const [], exitCode: 0),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  dart_git.GitCommit _gitResolveCommit(
    dart_git.GitRepository repo,
    String spec,
  ) {
    if (spec == 'HEAD') return repo.headCommit();
    if (repo.branches().contains(spec)) {
      final commit = repo.branchCommit(spec);
      if (commit != null) return commit;
    }
    // Treat as a full hash.
    final hash = GitHash(spec);
    return repo.objStorage.readCommit(hash);
  }

  Result<StageResult, ExecutionError> _gitCatFile(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _gitError('usage: git cat-file (-p|-t) <object>');
    }
    final flag = args[0];
    final spec = args[1];
    try {
      GitObject? obj;
      final colonIdx = spec.indexOf(':');
      if (colonIdx != -1) {
        final commitish = spec.substring(0, colonIdx);
        final pathSpec = spec.substring(colonIdx + 1);
        final commit = _gitResolveCommit(repo, commitish);
        final tree = repo.objStorage.readTree(commit.treeHash);
        final entry = repo.objStorage.refSpec(tree, pathSpec);
        obj = repo.objStorage.read(entry.hash);
      } else {
        GitHash hash;
        if (spec == 'HEAD') {
          hash = repo.headHash();
        } else if (repo.branches().contains(spec)) {
          hash = repo.resolveReferenceName(ReferenceName.branch(spec))!.hash;
        } else {
          hash = GitHash(spec);
        }
        obj = repo.objStorage.read(hash);
      }
      if (obj == null) throw Exception('object not found');

      if (flag == '-t') {
        return Ok(
          StageResult(
            stdout: utf8.encode('${obj.formatStr()}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      if (flag == '-p') {
        if (obj is GitBlob) {
          return Ok(
            StageResult(stdout: obj.blobData, stderr: const [], exitCode: 0),
          );
        }
        return Ok(
          StageResult(
            stdout: utf8.encode(
              '${utf8.decode(obj.serializeData(), allowMalformed: true)}\n',
            ),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      return _gitError('git cat-file: unsupported flag $flag');
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitHashObject(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    var write = false;
    String? path;
    for (final arg in args) {
      if (arg == '-w') {
        write = true;
      } else if (!arg.startsWith('-')) {
        path = arg;
      }
    }
    if (path == null) {
      return _gitError('usage: git hash-object [-w] <file>');
    }
    try {
      final data = io.File(_resolveGitPath(path, hostCwd)).readAsBytesSync();
      final blob = GitBlob(data, null);
      final hash = GitHash.computeForObject(blob);
      if (write) {
        repo.objStorage.writeObject(blob);
      }
      return Ok(
        StageResult(
          stdout: utf8.encode('$hash\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitLsTree(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git ls-tree <tree-ish>');
    }
    final spec = args.lastWhere((a) => !a.startsWith('-'));
    try {
      GitHash hash;
      if (repo.branches().contains(spec)) {
        final commit = repo.branchCommit(spec)!;
        hash = commit.treeHash;
      } else if (spec == 'HEAD') {
        hash = repo.headCommit().treeHash;
      } else {
        hash = GitHash(spec);
      }
      final tree = repo.objStorage.readTree(hash);
      final lines = tree.entries.map((e) {
        final mode = e.mode.val.toRadixString(8).padLeft(6, '0');
        final typeStr = e.mode == GitFileMode.Dir
            ? 'tree'
            : e.mode == GitFileMode.Submodule
            ? 'commit'
            : 'blob';
        return '$mode $typeStr ${e.hash}\t${e.name}';
      });
      return Ok(
        StageResult(
          stdout: utf8.encode('${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitWriteTree(
    dart_git.GitRepository repo,
  ) {
    try {
      final index = repo.indexStorage.readIndex();
      final hash = repo.writeTree(index);
      return Ok(
        StageResult(
          stdout: utf8.encode('$hash\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitMergeBase(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _gitError('usage: git merge-base <commit> <commit>');
    }
    try {
      final a = _gitResolveCommit(repo, args[0]);
      final b = _gitResolveCommit(repo, args[1]);
      final bases = repo.mergeBase(a, b);
      if (bases.isEmpty) {
        return _gitError('fatal: no merge base found');
      }
      return Ok(
        StageResult(
          stdout: utf8.encode('${bases.first.hash}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<StageResult, ExecutionError> _gitReset(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git reset [--hard] <commit>');
    }
    var hard = false;
    String? target;
    for (final arg in args) {
      if (arg == '--hard') {
        hard = true;
      } else if (!arg.startsWith('-')) {
        target = arg;
      }
    }
    if (!hard) {
      return _gitError('git reset: only --hard is supported');
    }
    if (target == null) {
      return _gitError('usage: git reset --hard <commit>');
    }
    try {
      final commit = _gitResolveCommit(repo, target);
      repo.resetHard(commit.hash);
      return Ok(
        StageResult(
          stdout: utf8.encode('HEAD is now at ${commit.hash.toOid()}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  String _sandboxPath(String hostPath) {
    final host = _shell.sandboxHostPath ?? '';
    if (host.isEmpty) return hostPath;
    final prefix = host.endsWith('/') ? host : '$host/';
    if (hostPath.startsWith(prefix)) {
      return '/${hostPath.substring(prefix.length)}';
    }
    return hostPath;
  }

  String _resolveGitPath(String arg, String hostCwd) {
    if (arg.startsWith('/')) return _shell.hostPathOf(arg);
    return p.normalize(p.join(hostCwd, arg));
  }

  String? _findGitRoot(String hostPath) {
    var dir = hostPath;
    while (true) {
      if (io.Directory(p.join(dir, '.git')).existsSync()) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }
}
