// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

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

import 'git_smart_http.dart';
import 'shell_parser.dart';
import 'wasm_shell.dart';

/// Pure-Dart git porcelain for the WASM sandbox, backed by `dart_git` for
/// local operations and the GitHub tarball API for `git clone`.
final class GitSandboxCommands {
  /// Creates the command set bound to [shell].
  GitSandboxCommands(this._shell);

  final WasiSandboxShell _shell;

  /// Runs the parsed git command line against the sandbox repository.
  Future<Result<StageResult, ExecutionError>> run(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final args = List<String>.from(stage.args);
    String cwd = options?.cwd ?? _shell.shellCwd;

    // Parse a single global -C option (common for git).
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-C') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option -C requires a value');
        }
        cwd = args[i + 1];
        args.removeRange(i, i + 2);
        break;
      }
    }

    if (args.isEmpty) {
      return _gitError(
        'usage: git [--version] [--help] [-C <path>] <command> [<args>]',
      );
    }

    final subcommand = args[0];
    final subArgs = args.sublist(1);

    if (subcommand == '--version' || subcommand == '-v') {
      return Ok(
        StageResult(
          stdout: utf8.encode('git version 2.47.0-fah\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }

    final hostCwd = _shell.hostPathOf(cwd);

    // Commands that do not require an existing repository.
    if (subcommand == 'clone') {
      return _gitClone(subArgs, hostCwd);
    }
    if (subcommand == 'init') {
      return _gitInit(subArgs, hostCwd);
    }

    final root = _findGitRoot(hostCwd);
    if (root == null) {
      return _gitError(
        'fatal: not a git repository (or any of the parent directories): .git',
      );
    }

    try {
      final repo = dart_git.GitRepository.load(root);
      switch (subcommand) {
        case 'add':
          return _gitAdd(repo, subArgs, hostCwd);
        case 'rm':
          return _gitRm(repo, subArgs, hostCwd);
        case 'commit':
          return _gitCommit(repo, subArgs, options?.env);
        case 'log':
          return _gitLog(repo, subArgs);
        case 'status':
          return _gitStatus(repo);
        case 'branch':
          return _gitBranch(repo, subArgs);
        case 'checkout':
          return _gitCheckout(repo, subArgs, hostCwd);
        case 'remote':
          return _gitRemote(repo, subArgs);
        case 'fetch':
          return _gitFetch(repo, subArgs);
        case 'show':
          return _gitShow(repo, subArgs);
        case 'cat-file':
          return _gitCatFile(repo, subArgs);
        case 'hash-object':
          return _gitHashObject(repo, subArgs, hostCwd);
        case 'ls-tree':
          return _gitLsTree(repo, subArgs);
        case 'write-tree':
          return _gitWriteTree(repo);
        case 'merge-base':
          return _gitMergeBase(repo, subArgs);
        case 'reset':
          return _gitReset(repo, subArgs);
        default:
          return _gitError('git: \'$subcommand\' is not a git command.');
      }
    } catch (e) {
      return _gitError('error: $e');
    }
  }

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
  ) async {
    if (args.isEmpty) {
      return _gitError('usage: git clone <repository> [<directory>]');
    }
    final repoUrl = args[0];
    String dest;
    if (args.length > 1 && !args[1].startsWith('-')) {
      dest = args[1];
    } else {
      dest = p.basenameWithoutExtension(repoUrl);
    }
    final hostDest = _resolveGitPath(dest, hostCwd);

    // Real git refuses to clone into a non-empty directory.
    final destDir = io.Directory(hostDest);
    if (destDir.existsSync()) {
      final hasGitDir = io.Directory(p.join(hostDest, '.git')).existsSync();
      final isEmpty = destDir.listSync(followLinks: false).isEmpty;
      if (hasGitDir || !isEmpty) {
        return _gitError(
          "fatal: destination path '$dest' already exists and is not an "
          'empty directory.',
        );
      }
    }

    // Preferred path: a real smart-HTTP clone (works with any public git
    // remote, not just GitHub).
    if (repoUrl.startsWith('http://') || repoUrl.startsWith('https://')) {
      try {
        await GitSmartHttp(
          client: _shell.shellHttpClient,
        ).cloneInto(url: repoUrl, hostDir: hostDest);
        return Ok(
          StageResult(
            stdout: utf8.encode('Cloned into \'$dest\'\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
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
        'fah';
    final email =
        env?['GIT_AUTHOR_EMAIL'] ??
        io.Platform.environment['GIT_AUTHOR_EMAIL'] ??
        'fah@example.com';
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
        return _gitError('git branch: unknown option $arg');
      } else {
        positional.add(arg);
      }
    }

    try {
      if (delete) {
        if (positional.isEmpty) {
          return _gitError('usage: git branch -d <branch>');
        }
        repo.deleteBranch(positional.first);
        return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
      }

      if (listRemote || listAll) {
        final lines = <String>[];
        if (listAll) {
          final current = repo.currentBranch();
          final branches = repo.branches()..sort();
          lines.addAll(branches.map((b) => b == current ? '* $b' : '  $b'));
        }
        final remoteRefs = repo.refStorage.listReferences('refs/remotes/')
          ..sort((a, b) => a.name.value.compareTo(b.name.value));
        for (final ref in remoteRefs) {
          lines.add('  ${ref.name.value.substring('refs/remotes/'.length)}');
        }
        return Ok(
          StageResult(
            stdout: utf8.encode(lines.isEmpty ? '' : '${lines.join('\n')}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }

      if (positional.isEmpty) {
        final current = repo.currentBranch();
        final branches = repo.branches()..sort();
        final lines = branches.map((b) => b == current ? '* $b' : '  $b');
        return Ok(
          StageResult(
            stdout: utf8.encode('${lines.join('\n')}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }

      repo.createBranch(positional.first);
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

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
        final startPoint = positional.length > 1 ? positional[1] : 'HEAD';
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

      // A remote ref or a full hash: detached HEAD checkout.
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
    } catch (e) {
      return _gitError('fatal: $e');
    }
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

  Result<StageResult, ExecutionError> _gitRemote(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    try {
      if (args.isEmpty) {
        final names = repo.config.remotes.map((r) => r.name).toList()..sort();
        return Ok(
          StageResult(
            stdout: utf8.encode(names.isEmpty ? '' : '${names.join('\n')}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }

      final action = args[0];
      if (action == '-v' || action == '--verbose') {
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
      if (action == 'add') {
        if (args.length < 3) {
          return _gitError('usage: git remote add <name> <url>');
        }
        repo.addRemote(args[1], args[2]);
        return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
      }
      if (action == 'remove' || action == 'rm') {
        if (args.length < 2) {
          return _gitError('usage: git remote remove <name>');
        }
        repo.removeRemote(args[1]);
        return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
      }
      if (action == 'get-url') {
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
      return _gitError('git remote: unknown subcommand $action');
    } on GitRemoteAlreadyExists catch (e) {
      return _gitError('fatal: remote ${e.name} already exists.');
    } on GitRemoteNotFound catch (e) {
      return _gitError('fatal: No such remote: ${e.name}');
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Future<Result<StageResult, ExecutionError>> _gitFetch(
    dart_git.GitRepository repo,
    List<String> args,
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
      final moved = await GitSmartHttp(client: _shell.shellHttpClient)
          .fetchInto(
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
