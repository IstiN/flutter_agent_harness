// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_git/dart_git.dart';
import 'package:dart_git/exceptions.dart';
import 'package:dart_git/plumbing/commit_iterator.dart';
import 'package:dart_git/plumbing/git_hash.dart';
import 'package:dart_git/plumbing/index.dart';
import 'package:dart_git/plumbing/objects/blob.dart';
import 'package:dart_git/plumbing/objects/object.dart';
import 'package:dart_git/plumbing/reference.dart';
import 'package:dart_git/storage/interfaces.dart';
import 'package:dart_git/utils/file_mode.dart';
import 'package:file/file.dart' as pf;
import 'package:file/memory.dart' as pf;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:path/path.dart' as p;

/// Local git for the web sandbox: pure-Dart porcelain on top of `dart_git`
/// with a [pf.MemoryFileSystem] store, bridged to the harness in-memory FS.
///
/// Network subcommands (clone/fetch/push/pull) report a clear error: browser
/// CORS blocks the git smart HTTP protocol, and no proxy is used.
///
/// Two implementation notes:
/// - dart_git's own checkout uses `chmodSync`, which throws on web, so tree
///   checkouts are done by the local [_checkoutTree] walker instead.
/// - dart_git's status crashes on deleted tracked files (`fsEntity!`), so
///   status is computed directly from index vs worktree vs HEAD.
final class WebGitCommands {
  /// Creates the command set bound to the harness in-memory [fs].
  WebGitCommands(this._fs);

  final MemoryFileSystem _fs;

  /// The git store (worktree + `.git`), kept across commands.
  final pf.MemoryFileSystem _gitFs = pf.MemoryFileSystem();

  final _repos = <String, GitRepository>{};

  // ---------------------------------------------------------------------------
  // Sync bridge: harness FS <-> gitFs (the '/sessions' dir is preserved)
  // ---------------------------------------------------------------------------

  Future<void> _pushToGitFs() async {
    final root = _gitFs.directory('/');
    if (root.existsSync()) {
      for (final entity in root.listSync()) {
        if (entity.basename == '.git') continue;
        entity.deleteSync(recursive: true);
      }
    }
    await _copyHarnessToGit('/', _gitFs);
  }

  Future<void> _copyHarnessToGit(
    String harnessDir,
    pf.MemoryFileSystem gitFs,
  ) async {
    final listed = await _fs.listDir(harnessDir);
    if (listed.isErr) return;
    for (final info in listed.valueOrNull!) {
      if (info.path == '/sessions' || info.path.startsWith('/sessions/')) {
        continue;
      }
      if (info.kind == FileKind.directory) {
        gitFs.directory(info.path).createSync(recursive: true);
        await _copyHarnessToGit(info.path, gitFs);
      } else {
        final bytes = await _fs.readBinaryFile(info.path);
        if (bytes.isOk) {
          gitFs.file(info.path)
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes.valueOrNull!);
        }
      }
    }
  }

  Future<void> _pullFromGitFs() async {
    final root = await _fs.listDir('/');
    if (root.isOk) {
      for (final info in root.valueOrNull!) {
        if (info.path == '/sessions') continue;
        await _fs.remove(info.path, recursive: true, force: true);
      }
    }
    final gitRoot = _gitFs.directory('/');
    if (!gitRoot.existsSync()) return;
    for (final entity in gitRoot.listSync(recursive: true)) {
      if (entity.path == '/.git' || entity.path.startsWith('/.git/')) continue;
      if (entity is pf.File) {
        await _fs.writeBinaryFile(entity.path, entity.readAsBytesSync());
      } else if (entity is pf.Directory) {
        await _fs.createDir(entity.path);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Command dispatch
  // ---------------------------------------------------------------------------

  /// Runs `git <args>` inside the sandbox. [cwd] is the shell's current
  /// directory (sandbox-absolute).
  Future<({String stdout, String stderr, int exitCode})> run(
    List<String> args, {
    required String cwd,
    Map<String, String>? env,
  }) async {
    if (args.isEmpty) {
      return _error(
        'usage: git [--version] [--help] [-C <path>] <command> [<args>]',
      );
    }
    args = List<String>.from(args);

    // Global -C option.
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-C') {
        if (i + 1 >= args.length) {
          return _error('fatal: option -C requires a value');
        }
        cwd = args[i + 1];
        args.removeRange(i, i + 2);
        break;
      }
    }
    if (args.isEmpty) {
      return _error(
        'usage: git [--version] [--help] [-C <path>] <command> [<args>]',
      );
    }

    final subcommand = args[0];
    final subArgs = args.sublist(1);

    if (subcommand == '--version' || subcommand == '-v') {
      return _ok('git version 2.47.0-fah-web\n');
    }

    const networkCommands = {
      'clone',
      'fetch',
      'push',
      'pull',
      'ls-remote',
      'merge',
      'rebase',
    };
    if (networkCommands.contains(subcommand)) {
      return _error(
        'git $subcommand: network access is not available on web '
        '(browsers block the git protocol via CORS)',
      );
    }

    await _pushToGitFs();
    try {
      final result = await _run(subcommand, subArgs, cwd: cwd, env: env);
      await _pullFromGitFs();
      return result;
    } catch (e) {
      await _pullFromGitFs();
      return _error('fatal: $e');
    }
  }

  Future<({String stdout, String stderr, int exitCode})> _run(
    String subcommand,
    List<String> args, {
    required String cwd,
    Map<String, String>? env,
  }) async {
    if (subcommand == 'init') {
      return _init(args, cwd);
    }

    final root = _findGitRoot(cwd);
    if (root == null) {
      return _error(
        'fatal: not a git repository (or any of the parent directories): .git',
      );
    }
    final repo = _repo(root);

    return switch (subcommand) {
      'add' => _add(repo, args, cwd),
      'rm' => _rm(repo, args, cwd),
      'commit' => _commit(repo, args, env),
      'log' => _log(repo, args),
      'status' => _status(repo),
      'branch' => _branch(repo, args),
      'checkout' => _checkout(repo, args, cwd),
      'show' => _show(repo, args),
      'cat-file' => _catFile(repo, args),
      'hash-object' => _hashObject(repo, args, cwd),
      'ls-tree' => _lsTree(repo, args),
      'write-tree' => _writeTree(repo),
      'merge-base' => _mergeBase(repo, args),
      'reset' => _reset(repo, args),
      'remote' => _remote(repo, args),
      _ => _error("git: '$subcommand' is not a git command."),
    };
  }

  GitRepository _repo(String root) {
    return _repos.putIfAbsent(root, () {
      final repo = GitRepository.load(root, fs: _gitFs);
      // dart_git's default object storage uses dart:io's zlib, which does not
      // exist on web: swap in a pure-Dart zlib storage.
      repo.objStorage = _LooseObjectStorage(repo.gitDir, _gitFs);
      return repo;
    });
  }

  /// Rewrites index entry modes to a sane git file mode.
  ///
  /// package:file's MemoryFileSystem reports `stat.mode == 0o3567`, which is
  /// not a valid git tree mode (its 4-char octal form corrupts tree
  /// serialization), so entries are normalized to regular/executable.
  void _normalizeIndexModes(GitRepository repo) {
    final index = repo.indexStorage.readIndex();
    var changed = false;
    for (var i = 0; i < index.entries.length; i++) {
      final e = index.entries[i];
      if (e.mode == GitFileMode.Regular ||
          e.mode == GitFileMode.Executable ||
          e.mode == GitFileMode.Dir) {
        continue;
      }
      index.entries[i] = GitIndexEntry(
        cTime: e.cTime,
        mTime: e.mTime,
        dev: e.dev,
        ino: e.ino,
        mode: GitFileMode.Regular,
        uid: e.uid,
        gid: e.gid,
        fileSize: e.fileSize,
        hash: e.hash,
        stage: e.stage,
        path: e.path,
      );
      changed = true;
    }
    if (changed) repo.indexStorage.writeIndex(index);
  }

  String? _findGitRoot(String cwd) {
    var dir = cwd;
    while (true) {
      if (_gitFs.directory(p.join(dir, '.git')).existsSync()) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  String _resolvePath(String path, String cwd) {
    if (path.startsWith('/')) return _normalize(path);
    return _normalize('$cwd/$path');
  }

  String _normalize(String path) {
    final segments = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return '/${segments.join('/')}';
  }

  ({String stdout, String stderr, int exitCode}) _ok(String stdout) =>
      (stdout: stdout, stderr: '', exitCode: 0);

  ({String stdout, String stderr, int exitCode}) _error(String message) =>
      (stdout: '', stderr: '$message\n', exitCode: 1);

  // ---------------------------------------------------------------------------
  // init
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _init(
    List<String> args,
    String cwd,
  ) {
    var path = cwd;
    var display = cwd;
    for (final arg in args) {
      if (arg.startsWith('-')) continue;
      path = _resolvePath(arg, cwd);
      display = arg;
    }
    try {
      GitRepository.init(path, fs: _gitFs);
      return _ok('Initialized empty Git repository in $display/.git/\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // add / rm
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _add(
    GitRepository repo,
    List<String> args,
    String cwd,
  ) {
    if (args.isEmpty) return _error('usage: git add <pathspec>...');
    try {
      for (final arg in args.where((a) => !a.startsWith('-'))) {
        repo.add(_resolvePath(arg, cwd));
      }
      _normalizeIndexModes(repo);
      return _ok('');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  ({String stdout, String stderr, int exitCode}) _rm(
    GitRepository repo,
    List<String> args,
    String cwd,
  ) {
    if (args.isEmpty) return _error('usage: git rm <pathspec>...');
    try {
      for (final arg in args.where((a) => !a.startsWith('-'))) {
        repo.rm(_resolvePath(arg, cwd));
      }
      return _ok('');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // commit
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _commit(
    GitRepository repo,
    List<String> args,
    Map<String, String>? env,
  ) {
    String? message;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-m' || arg == '--message') {
        if (i + 1 >= args.length) {
          return _error('fatal: option $arg requires a value');
        }
        message = args[i + 1];
        i++;
      }
    }
    if (message == null || message.isEmpty) {
      return _error('fatal: cannot create an empty commit without a message');
    }

    final author = GitAuthor(
      name: env?['GIT_AUTHOR_NAME'] ?? 'fah',
      email: env?['GIT_AUTHOR_EMAIL'] ?? 'fah@example.com',
    );
    try {
      final commit = repo.commit(
        message: message,
        author: author,
        committer: author,
      );
      return _ok('[${repo.currentBranch()} ${commit.hash.toOid()}] $message\n');
    } on GitEmptyCommit {
      return _error(
        'On branch ${repo.currentBranch()}\n'
        'nothing to commit, working tree clean',
      );
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // log / show / cat-file
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _log(
    GitRepository repo,
    List<String> args,
  ) {
    var maxCount = 0;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-n' || args[i] == '--max-count') {
        if (i + 1 >= args.length) {
          return _error('fatal: option ${args[i]} requires a value');
        }
        maxCount = int.tryParse(args[i + 1]) ?? 0;
        i++;
      }
    }
    try {
      final commits = commitIteratorBFS(
        objStorage: repo.objStorage,
        from: repo.headHash(),
      );
      final lines = <String>[];
      var count = 0;
      for (final commit in commits) {
        if (maxCount > 0 && count >= maxCount) break;
        final msg = commit.message.trim().split('\n').first;
        lines.add('${commit.hash.toOid()} $msg');
        count++;
      }
      return _ok(lines.isEmpty ? '' : '${lines.join('\n')}\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  ({String stdout, String stderr, int exitCode}) _show(
    GitRepository repo,
    List<String> args,
  ) {
    final spec = args.isEmpty
        ? 'HEAD'
        : args.firstWhere((a) => !a.startsWith('-'));
    final colonIdx = spec.indexOf(':');
    try {
      if (colonIdx == -1) {
        final commit = _resolveCommit(repo, spec);
        final lines = <String>[
          'commit ${commit.hash}',
          'Author: ${commit.author.name} <${commit.author.email}>',
          'Date:   ${commit.author.date}',
          '',
          commit.message.trim(),
        ];
        return _ok('${lines.join('\n')}\n');
      }
      final commit = _resolveCommit(repo, spec.substring(0, colonIdx));
      final tree = repo.objStorage.readTree(commit.treeHash);
      final entry = repo.objStorage.refSpec(tree, spec.substring(colonIdx + 1));
      final blob = repo.objStorage.readBlob(entry.hash);
      return (
        stdout: utf8.decode(blob.blobData, allowMalformed: true),
        stderr: '',
        exitCode: 0,
      );
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  ({String stdout, String stderr, int exitCode}) _catFile(
    GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _error('usage: git cat-file (-p|-t) <object>');
    }
    final flag = args[0];
    final spec = args[1];
    try {
      GitObject? obj;
      final colonIdx = spec.indexOf(':');
      if (colonIdx != -1) {
        final commit = _resolveCommit(repo, spec.substring(0, colonIdx));
        final tree = repo.objStorage.readTree(commit.treeHash);
        final entry = repo.objStorage.refSpec(
          tree,
          spec.substring(colonIdx + 1),
        );
        obj = repo.objStorage.read(entry.hash);
      } else {
        obj = repo.objStorage.read(_resolveHash(repo, spec)!);
      }
      if (obj == null) return _error('fatal: object not found: $spec');

      if (flag == '-t') return _ok('${obj.formatStr()}\n');
      if (flag == '-p') {
        if (obj is GitBlob) {
          return (
            stdout: utf8.decode(obj.blobData, allowMalformed: true),
            stderr: '',
            exitCode: 0,
          );
        }
        return _ok(
          '${utf8.decode(obj.serializeData(), allowMalformed: true)}\n',
        );
      }
      return _error('git cat-file: unsupported flag $flag');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  GitCommit _resolveCommit(GitRepository repo, String spec) {
    if (spec == 'HEAD') return repo.headCommit();
    if (repo.branches().contains(spec)) {
      final commit = repo.branchCommit(spec);
      if (commit != null) return commit;
    }
    return repo.objStorage.readCommit(GitHash(spec));
  }

  GitHash? _resolveHash(GitRepository repo, String spec) {
    try {
      if (spec == 'HEAD') return repo.headHash();
      if (repo.branches().contains(spec)) {
        return repo.resolveReferenceName(ReferenceName.branch(spec))!.hash;
      }
      if (RegExp(r'^[0-9a-f]{40}$').hasMatch(spec)) return GitHash(spec);
    } on Object {
      return null;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // status (index vs worktree vs HEAD, no dart_git status: it crashes on
  // deleted tracked files)
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _status(GitRepository repo) {
    try {
      final index = repo.indexStorage.readIndex();
      final indexPaths = <String, GitHash>{
        for (final entry in index.entries) entry.path: entry.hash,
      };

      final untracked = <String>[];
      final modified = <String>[];
      final deleted = <String>[];

      final workTreeFiles = <String>{};
      final rootDir = _gitFs.directory(repo.workTree);
      if (rootDir.existsSync()) {
        for (final entity in rootDir.listSync(recursive: true)) {
          if (entity.path.startsWith('${repo.workTree}.git')) continue;
          if (entity is! pf.File) continue;
          workTreeFiles.add(entity.path.substring(repo.workTree.length));
        }
      }

      for (final path in workTreeFiles) {
        final indexHash = indexPaths[path];
        if (indexHash == null) {
          untracked.add(path);
          continue;
        }
        final bytes = _gitFs.file('${repo.workTree}$path').readAsBytesSync();
        final blob = GitBlob(bytes, null);
        if (blob.hash != indexHash) modified.add(path);
      }
      for (final path in indexPaths.keys) {
        if (!workTreeFiles.contains(path)) deleted.add(path);
      }

      final lines = <String>[];
      if (untracked.isNotEmpty) {
        lines.add('Untracked:');
        lines.addAll(untracked.map((f) => '  $f'));
      }
      if (modified.isNotEmpty) {
        lines.add('Modified:');
        lines.addAll(modified.map((f) => '  $f'));
      }
      if (deleted.isNotEmpty) {
        lines.add('Deleted:');
        lines.addAll(deleted.map((f) => '  $f'));
      }
      if (lines.isEmpty) lines.add('nothing to commit, working tree clean');
      return _ok('${lines.join('\n')}\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // branch / checkout
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _branch(
    GitRepository repo,
    List<String> args,
  ) {
    var delete = false;
    final positional = <String>[];
    for (final arg in args) {
      if (arg == '-d' || arg == '-D') {
        delete = true;
      } else if (arg == '-r' || arg == '-a') {
        // No remotes on web: list behaves like a plain branch listing.
      } else if (arg.startsWith('-')) {
        return _error('git branch: unknown option $arg');
      } else {
        positional.add(arg);
      }
    }

    try {
      if (delete) {
        if (positional.isEmpty) return _error('usage: git branch -d <branch>');
        repo.deleteBranch(positional.first);
        return _ok('');
      }
      if (positional.isEmpty) {
        final current = repo.currentBranch();
        final branches = repo.branches()..sort();
        final lines = branches.map((b) => b == current ? '* $b' : '  $b');
        return _ok('${lines.join('\n')}\n');
      }
      repo.createBranch(positional.first);
      return _ok('');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  Future<({String stdout, String stderr, int exitCode})> _checkout(
    GitRepository repo,
    List<String> args,
    String cwd,
  ) async {
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
      return _error('usage: git checkout [-b] <branch>|<path>');
    }
    final target = positional.first;

    try {
      if (create) {
        final startPoint = positional.length > 1 ? positional[1] : 'HEAD';
        final hash = _resolveHash(repo, startPoint);
        if (hash == null) {
          return _error(
            "fatal: '$startPoint' is not a commit and a branch "
            "'$target' cannot be created from it",
          );
        }
        repo.createBranch(target, hash: hash);
        await _checkoutTree(repo, hash);
        repo.refStorage.saveRef(
          SymbolicReference(ReferenceName.HEAD(), ReferenceName.branch(target)),
        );
        return _ok('Switched to a new branch \'$target\'\n');
      }

      if (repo.branches().contains(target)) {
        final commit = repo.branchCommit(target)!;
        await _checkoutTree(repo, commit.hash);
        repo.refStorage.saveRef(
          SymbolicReference(ReferenceName.HEAD(), ReferenceName.branch(target)),
        );
        return _ok('Switched to branch \'$target\'\n');
      }

      final hash = _resolveHash(repo, target);
      if (hash != null) {
        await _checkoutTree(repo, hash);
        repo.refStorage.saveRef(HashReference(ReferenceName.HEAD(), hash));
        return _ok(
          'Note: switching to \'$target\'.\n'
          'You are in \'detached HEAD\' state.\n'
          'HEAD is now at ${hash.toOid()}\n',
        );
      }

      return _error("error: pathspec '$target' did not match any");
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  /// Writes [commit]'s tree into the worktree and rebuilds the index.
  ///
  /// Used instead of dart_git's checkout, which calls `chmodSync` (throws on
  /// web) and depends on racy index state.
  Future<void> _checkoutTree(GitRepository repo, GitHash commitHash) async {
    // Wipe the worktree (keep .git).
    final workTree = _gitFs.directory(repo.workTree);
    if (workTree.existsSync()) {
      for (final entity in workTree.listSync()) {
        if (entity.basename == '.git') continue;
        entity.deleteSync(recursive: true);
      }
    }

    final commit = repo.objStorage.readCommit(commitHash);
    void writeTree(GitHash treeHash, String prefix) {
      final tree = repo.objStorage.readTree(treeHash);
      for (final entry in tree.entries) {
        final path = '$prefix${entry.name}';
        if (entry.mode == GitFileMode.Dir) {
          _gitFs.directory(path).createSync(recursive: true);
          writeTree(entry.hash, '$path/');
        } else {
          final blob = repo.objStorage.readBlob(entry.hash);
          _gitFs.file(path)
            ..createSync(recursive: true)
            ..writeAsBytesSync(blob.blobData);
        }
      }
    }

    writeTree(commit.treeHash, repo.workTree);

    // Rebuild the index from the worktree so status is clean afterwards.
    repo.indexStorage.writeIndex(GitIndex(versionNo: 2));
    repo.add(repo.workTree);
    _normalizeIndexModes(repo);
  }

  // ---------------------------------------------------------------------------
  // Plumbing: hash-object / ls-tree / write-tree / merge-base / reset
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _hashObject(
    GitRepository repo,
    List<String> args,
    String cwd,
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
    if (path == null) return _error('usage: git hash-object [-w] <file>');
    try {
      final data = _gitFs.file(_resolvePath(path, cwd)).readAsBytesSync();
      final blob = GitBlob(data, null);
      if (write) repo.objStorage.writeObject(blob);
      return _ok('${blob.hash}\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  ({String stdout, String stderr, int exitCode}) _lsTree(
    GitRepository repo,
    List<String> args,
  ) {
    if (args.isEmpty) return _error('usage: git ls-tree <tree-ish>');
    final spec = args.lastWhere((a) => !a.startsWith('-'));
    try {
      final hash = _resolveHash(repo, spec);
      if (hash == null) return _error('fatal: not a tree object: $spec');
      final commit = repo.objStorage.readCommit(hash);
      final tree = repo.objStorage.readTree(commit.treeHash);
      final lines = tree.entries.map((e) {
        final mode = e.mode.val.toRadixString(8).padLeft(6, '0');
        final typeStr = e.mode == GitFileMode.Dir
            ? 'tree'
            : e.mode == GitFileMode.Submodule
            ? 'commit'
            : 'blob';
        return '$mode $typeStr ${e.hash}\t${e.name}';
      });
      return _ok('${lines.join('\n')}\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  ({String stdout, String stderr, int exitCode}) _writeTree(
    GitRepository repo,
  ) {
    try {
      final hash = repo.writeTree(repo.indexStorage.readIndex());
      return _ok('$hash\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  ({String stdout, String stderr, int exitCode}) _mergeBase(
    GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _error('usage: git merge-base <commit> <commit>');
    }
    try {
      final a = _resolveCommit(repo, args[0]);
      final b = _resolveCommit(repo, args[1]);
      final bases = repo.mergeBase(a, b);
      if (bases.isEmpty) return _error('fatal: no merge base found');
      return _ok('${bases.first.hash}\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  Future<({String stdout, String stderr, int exitCode})> _reset(
    GitRepository repo,
    List<String> args,
  ) async {
    var hard = false;
    String? target;
    for (final arg in args) {
      if (arg == '--hard') {
        hard = true;
      } else if (!arg.startsWith('-')) {
        target = arg;
      }
    }
    if (!hard) return _error('git reset: only --hard is supported');
    if (target == null) return _error('usage: git reset --hard <commit>');
    try {
      final hash = _resolveHash(repo, target);
      if (hash == null) return _error('fatal: ambiguous argument: $target');
      final branch = repo.currentBranch();
      repo.refStorage.saveRef(
        HashReference(ReferenceName.branch(branch), hash),
      );
      await _checkoutTree(repo, hash);
      return _ok('HEAD is now at ${hash.toOid()}\n');
    } catch (e) {
      return _error('fatal: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // remote (config only; no network on web)
  // ---------------------------------------------------------------------------

  ({String stdout, String stderr, int exitCode}) _remote(
    GitRepository repo,
    List<String> args,
  ) {
    try {
      if (args.isEmpty) {
        final names = repo.config.remotes.map((r) => r.name).toList()..sort();
        return _ok(names.isEmpty ? '' : '${names.join('\n')}\n');
      }
      final action = args[0];
      if (action == '-v' || action == '--verbose') {
        final lines = <String>[
          for (final r in repo.config.remotes) ...[
            '${r.name}\t${r.url} (fetch)',
            '${r.name}\t${r.url} (push)',
          ],
        ];
        return _ok(lines.isEmpty ? '' : '${lines.join('\n')}\n');
      }
      if (action == 'add') {
        if (args.length < 3)
          return _error('usage: git remote add <name> <url>');
        repo.addRemote(args[1], args[2]);
        return _ok('');
      }
      if (action == 'remove' || action == 'rm') {
        if (args.length < 2) return _error('usage: git remote remove <name>');
        repo.removeRemote(args[1]);
        return _ok('');
      }
      if (action == 'get-url') {
        if (args.length < 2) return _error('usage: git remote get-url <name>');
        final remote = repo.config.remote(args[1]);
        if (remote == null) return _error("fatal: No such remote '${args[1]}'");
        return _ok('${remote.url}\n');
      }
      return _error('git remote: unknown subcommand $action');
    } on GitRemoteAlreadyExists catch (e) {
      return _error('fatal: remote ${e.name} already exists.');
    } on GitRemoteNotFound catch (e) {
      return _error('fatal: No such remote: ${e.name}');
    } catch (e) {
      return _error('fatal: $e');
    }
  }
}

/// Loose-object storage for the web sandbox: identical layout to dart_git's
/// `ObjectStorageFS` (`.git/objects/aa/bb...`, zlib-compressed envelopes) but
/// using package:archive's pure-Dart zlib, which works in the browser where
/// dart:io's zlib does not exist.
final class _LooseObjectStorage implements ObjectStorage {
  _LooseObjectStorage(this._gitDir, this._fs);

  final String _gitDir;
  final pf.FileSystem _fs;

  String _pathFor(GitHash hash) {
    final sha = hash.toString();
    return p.join(_gitDir, 'objects', sha.substring(0, 2), sha.substring(2));
  }

  @override
  GitObject? read(GitHash hash) {
    final path = _pathFor(hash);
    if (!_fs.isFileSync(path)) {
      throw GitObjectNotFound(hash);
    }
    final raw = Uint8List.fromList(
      ZLibDecoder().decodeBytes(_fs.file(path).readAsBytesSync()),
    );

    // Object envelope: "<type> <size>\x00<data>".
    const space = 0x20;
    final x = raw.indexOf(space);
    if (x == -1) throw GitObjectCorruptedMissingType();
    final fmt = raw.sublist(0, x);
    final y = raw.indexOf(0x0, x);
    if (y == -1) throw GitObjectCorruptedMissingSize();
    final size = int.tryParse(ascii.decode(raw.sublist(x, y)));
    if (size == null) throw GitObjectCorruptedInvalidIntSize();
    if (size != (raw.length - y - 1)) {
      throw GitObjectCorruptedBadSize();
    }
    final fmtStr = ascii.decode(fmt);
    final rawData = raw.sublist(y + 1);
    return createObject(ObjectTypes.getType(fmtStr), rawData, hash);
  }

  @override
  GitHash writeObject(GitObject obj) {
    final result = GitObject.envelope(
      data: obj.serializeData(),
      format: obj.format(),
    );
    final hash = obj.hash;
    final path = _pathFor(hash);
    _fs.directory(p.dirname(path)).createSync(recursive: true);
    if (_fs.isFileSync(path)) return hash;
    _fs.file(path).openSync(mode: pf.FileMode.writeOnly)
      ..writeFromSync(ZLibEncoder().encode(result))
      ..closeSync();
    return hash;
  }

  @override
  void close() {}
}
