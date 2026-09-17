// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the sandbox git porcelain (`GitSandboxCommands`, issue
/// #475). The command set runs against a plain-Dart [GitShellHost] fake —
/// no WASM modules, no network: `git clone` exercises only its validation
/// and tarball paths through a canned in-memory HTTP client, and the
/// tarball's `tar` extraction runs the host `tar` binary with the same
/// argv the WASM module would see.
///
/// Every family test pins the EXACT stdout/stderr/exit-code triple the
/// old switch router produced (golden arg-vector fixtures, issue #475
/// AC5) — the refactor must be invisible to shell users.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_git/dart_git.dart' as dart_git;
import 'package:dart_git/plumbing/git_hash.dart';
import 'package:dart_git/plumbing/reference.dart';
import 'package:fa/sandbox/shell_parser.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:fa/sandbox/wasm_shell_git.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// HTTP client that fails like a socket would — unit tests never dial.
final class ThrowingHttpClient implements http.Client {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw const io.SocketException('unit tests never touch the network');
  }

  @override
  void close() {}
}

/// Plain-Dart host: sandbox `/` maps onto a temp directory; the WASM `tar`
/// runner is replaced by the host `tar` binary with identical semantics.
final class FakeGitShellHost implements GitShellHost {
  FakeGitShellHost(this.root);
  final String root;
  @override
  http.Client shellHttpClient = ThrowingHttpClient();

  @override
  String? get sandboxHostPath => root;

  @override
  String get shellCwd => '/';

  @override
  String hostPathOf(String sandboxPath) => sandboxPath.startsWith('/')
      ? '$root/${sandboxPath.substring(1)}'
      : sandboxPath;

  @override
  Future<Result<StageResult, ExecutionError>> runSandboxCommand(
    String command,
    List<String> args,
  ) async {
    if (command != 'tar') {
      return Err(
        ExecutionError(ExecutionErrorCode.unknown, 'no $command in tests'),
      );
    }
    // The WASM tar sees sandbox paths; map -xf/-C operands to the host.
    final hostArgs = <String>[
      for (var i = 0; i < args.length; i++)
        args[i].startsWith('/') ? hostPathOf(args[i]) : args[i],
    ];
    final proc = await io.Process.run('tar', hostArgs);
    return Ok(
      StageResult(
        stdout: utf8.encode('${proc.stdout}'),
        stderr: utf8.encode('${proc.stderr}'),
        exitCode: proc.exitCode,
      ),
    );
  }
}

/// Canned HTTP client: serves one tarball response, fails like a socket
/// would for anything else — no real network in unit tests.
final class CannedTarballClient extends http.BaseClient {
  CannedTarballClient(this.tarball);
  final List<int> tarball;
  final List<Uri> requested = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requested.add(request.url);
    if (request.url.host.endsWith('api.github.com') &&
        request.url.path.endsWith('/tarball')) {
      return http.StreamedResponse(
        Stream.value(tarball),
        200,
        contentLength: tarball.length,
      );
    }
    throw const io.SocketException('unit tests never touch the network');
  }

  @override
  void close() {}
}

void main() {
  late io.Directory temp;
  late FakeGitShellHost host;
  late GitSandboxCommands git;

  setUp(() async {
    temp = await io.Directory.systemTemp.createTemp('fa475_git');
    host = FakeGitShellHost(temp.path);
    git = GitSandboxCommands(host);
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// Runs a raw git argv and returns (stdout, stderr, exitCode) as text.
  Future<(String, String, int)> runGit(
    List<String> args, {
    Map<String, String>? env,
    String? cwd,
  }) async {
    final result = await git.run(
      Stage(command: 'git', args: args),
      ShellExecOptions(env: env, cwd: cwd),
    );
    final stage = result.valueOrNull!;
    return (
      utf8.decode(stage.stdout, allowMalformed: true),
      utf8.decode(stage.stderr, allowMalformed: true),
      stage.exitCode,
    );
  }

  /// Author env every committing test passes (deterministic identity).
  const authorEnv = {
    'GIT_AUTHOR_NAME': 'Fa',
    'GIT_AUTHOR_EMAIL': 'fa@example.com',
  };

  /// Boots a repository with one commit on `main` (the shared fixture the
  /// per-family goldens build on) and returns the commit's full oid.
  Future<String> seedRepo() async {
    final (_, _, code) = await runGit(['init', '-b', 'main']);
    expect(code, 0);
    io.File(p.join(temp.path, 'hello.txt')).writeAsStringSync('hi\n');
    final (_, _, addCode) = await runGit(['add', 'hello.txt']);
    expect(addCode, 0);
    final (out, _, commitCode) = await runGit([
      'commit',
      '-m',
      'seed commit',
    ], env: authorEnv);
    expect(commitCode, 0, reason: out);
    // `git show` echoes `commit <full-oid>` — that is the canonical handle
    // other families (merge-base, reset, cat-file -t) print back.
    final (show, _, showCode) = await runGit(['show']);
    expect(showCode, 0, reason: show);
    return show.split('\n').first.substring('commit '.length);
  }

  group('prologue and routing', () {
    test('git --version / -v answer identically', () async {
      for (final v in const [
        ['--version'],
        ['-v'],
      ]) {
        final (out, err, code) = await runGit(v);
        expect(code, 0);
        expect(err, isEmpty);
        expect(out, 'git version 2.47.0-Fa\n');
      }
    });

    test('bare git answers the usage line', () async {
      final (out, err, code) = await runGit([]);
      expect(code, 1);
      expect(out, isEmpty);
      expect(
        err,
        'usage: git [--version] [--help] [-C <path>] <command> [<args>]\n',
      );
    });

    test('-C without a value is a fatal error', () async {
      final (out, err, code) = await runGit(['-C']);
      expect(code, 1);
      expect(err, 'fatal: option -C requires a value\n');
    });

    test('-C reroutes the command to another directory', () async {
      final sub = io.Directory(p.join(temp.path, 'sub'))..createSync();
      final (out, _, code) = await runGit(['-C', '/sub', 'init']);
      expect(code, 0, reason: out);
      expect(io.Directory(p.join(sub.path, '.git')).existsSync(), isTrue);
    });

    test('unknown command keeps the old not-a-command error', () async {
      await runGit(['init']);
      final (out, err, code) = await runGit(['frobnicate']);
      expect(code, 1);
      expect(err, "git: 'frobnicate' is not a git command.\n");
    });

    test(
      'repo commands outside a repository answer not-a-repository',
      () async {
        final (out, err, code) = await runGit(['status']);
        expect(code, 1);
        expect(
          err,
          'fatal: not a git repository (or any of the parent directories): '
          '.git\n',
        );
      },
    );
  });

  group('init family', () {
    test('init creates a repository and echoes its path', () async {
      final (out, _, code) = await runGit(['init']);
      expect(code, 0);
      // Bug-for-bug parity: the echo prints the RESOLVED HOST path of the
      // sandbox cwd (trailing slash of `/` -> double slash), exactly what
      // device users see with the app-documents host.
      expect(out, 'Initialized empty Git repository in ${temp.path}//.git/\n');
      expect(io.Directory(p.join(temp.path, '.git')).existsSync(), isTrue);
    });

    test('init with a directory arg initializes there', () async {
      final (out, _, code) = await runGit(['init', 'repo-dir']);
      expect(code, 0);
      expect(out, 'Initialized empty Git repository in repo-dir/.git/\n');
      expect(
        io.Directory(p.join(temp.path, 'repo-dir', '.git')).existsSync(),
        isTrue,
      );
    });

    test('init rejects unsupported flags', () async {
      for (final flag in const ['--bare', '--shared']) {
        final (out, err, code) = await runGit(['init', flag]);
        expect(code, 1);
        expect(err, 'git init: unsupported flag $flag\n');
      }
    });

    test('init accepts -b with a value', () async {
      final (out, _, code) = await runGit(['init', '-b', 'trunk']);
      expect(code, 0, reason: out);
    });

    test('init -b without a value is a fatal error', () async {
      final (out, err, code) = await runGit(['init', '-b']);
      expect(code, 1);
      expect(err, 'fatal: option -b requires a value\n');
    });
  });

  group('add / rm / commit family', () {
    test('add without pathspecs answers the usage line', () async {
      await runGit(['init']);
      final (out, err, code) = await runGit(['add']);
      expect(code, 1);
      expect(err, 'usage: git add <pathspec>...\n');
    });

    test('rm without pathspecs answers the usage line', () async {
      await runGit(['init']);
      final (_, err, code) = await runGit(['rm']);
      expect(code, 1);
      expect(err, 'usage: git rm <pathspec>...\n');
    });

    test('commit without -m refuses an empty commit', () async {
      await seedRepo();
      final (out, err, code) = await runGit(['commit']);
      expect(code, 1);
      expect(err, 'fatal: cannot create an empty commit without a message\n');
    });

    test('commit on a clean tree answers nothing to commit', () async {
      await seedRepo();
      final (_, err, code) = await runGit([
        'commit',
        '-m',
        'nothing',
      ], env: authorEnv);
      expect(code, 1);
      expect(err, startsWith('On branch main\nnothing to commit'));
    });

    test('commit echo carries branch, oid and message', () async {
      await seedRepo();
      io.File(p.join(temp.path, 'second.txt')).writeAsStringSync('2\n');
      await runGit(['add', 'second.txt']);
      final (out, _, code) = await runGit([
        'commit',
        '--message',
        'second one',
      ], env: authorEnv);
      expect(code, 0);
      // toOid() prints the SHORT form here (the same echo real git gives).
      expect(out, matches(RegExp(r'^\[main [0-9a-f]+\] second one\n$')));
    });
  });

  group('log family', () {
    test('log lists commits newest first', () async {
      await seedRepo();
      final (out, _, code) = await runGit(['log']);
      expect(code, 0);
      expect(out, matches(RegExp(r'^[0-9a-f]+ seed commit\n$')));
    });

    test('log -n without a value usage errors', () async {
      await seedRepo();
      final (_, err, code) = await runGit(['log', '-n']);
      expect(code, 1);
      expect(err, 'fatal: option -n requires a value\n');
    });
  });

  group('status family', () {
    test('status reports untracked files', () async {
      await seedRepo();
      io.File(p.join(temp.path, 'new.txt')).writeAsStringSync('n\n');
      final (out, err, code) = await runGit(['status']);
      expect(code, 0, reason: 'out=$out err=$err');
      expect(out, 'Untracked:\n  new.txt\n');
    });
    test('status on a clean tree answers working tree clean', () async {
      await seedRepo();
      final (out, _, code) = await runGit(['status']);
      expect(code, 0);
      expect(out, 'nothing to commit, working tree clean\n');
    });
  });

  group('branch family', () {
    test('branch creates, lists with star, and deletes', () async {
      await seedRepo();
      expect((await runGit(['branch', 'feature'])).$3, 0);
      final (out, _, code) = await runGit(['branch']);
      expect(code, 0);
      // Sorted alphabetically; the star marks the current branch.
      expect(out, '  feature\n* main\n');
      expect((await runGit(['branch', '-d', 'feature'])).$3, 0);
      final (after, _, _) = await runGit(['branch']);
      expect(after, '* main\n');
    });

    test('branch -d without a name answers the usage line', () async {
      await seedRepo();
      final (_, err, code) = await runGit(['branch', '-d']);
      expect(code, 1);
      expect(err, 'usage: git branch -d <branch>\n');
    });

    test('branch rejects unknown options', () async {
      await seedRepo();
      final (_, err, code) = await runGit(['branch', '--frobnicate']);
      expect(code, 1);
      expect(err, 'git branch: unknown option --frobnicate\n');
    });
  });

  group('checkout family', () {
    test(
      'checkout -b creates and switches, then switching back works',
      () async {
        await seedRepo();
        final (out, _, code) = await runGit(['checkout', '-b', 'topic']);
        expect(code, 0);
        expect(out, "Switched to a new branch 'topic'\n");
        final (back, _, _) = await runGit(['checkout', 'main']);
        expect(back, "Switched to branch 'main'\n");
      },
    );

    test('checkout -b from an unresolvable start point fails', () async {
      await seedRepo();
      final (_, err, code) = await runGit(['checkout', '-b', 'x', 'not-a-ref']);
      expect(code, 1);
      expect(
        err,
        "fatal: 'not-a-ref' is not a commit and a branch 'x' cannot be "
        'created from it\n',
      );
    });

    test('checkout without a target answers the usage line', () async {
      await seedRepo();
      final (_, err, code) = await runGit(['checkout']);
      expect(code, 1);
      expect(err, 'usage: git checkout [-b] <branch>|<path>\n');
    });

    test('checkout restores a deleted path (path checkout)', () async {
      await seedRepo();
      io.File(p.join(temp.path, 'hello.txt')).deleteSync();
      final (out, _, code) = await runGit(['checkout', 'hello.txt']);
      expect(code, 0);
      expect(out, 'Updated 1 paths\n');
      expect(io.File(p.join(temp.path, 'hello.txt')).existsSync(), isTrue);
    });
  });

  group('remote family', () {
    test('remote add / list / -v / get-url / remove round trip', () async {
      await seedRepo();
      expect((await runGit(['remote'])).$1, isEmpty);
      expect((await runGit(['remote', 'add', 'origin', 'https://x/y'])).$3, 0);
      final (names, _, _) = await runGit(['remote']);
      expect(names, 'origin\n');
      final (verbose, _, _) = await runGit(['remote', '-v']);
      expect(
        verbose,
        'origin\thttps://x/y (fetch)\norigin\thttps://x/y (push)\n',
      );
      final (url, _, _) = await runGit(['remote', 'get-url', 'origin']);
      expect(url, 'https://x/y\n');
      expect((await runGit(['remote', 'rm', 'origin'])).$3, 0);
      expect((await runGit(['remote'])).$1, isEmpty);
    });

    test('remote add usage and duplicate errors', () async {
      await seedRepo();
      final (_, err, code) = await runGit(['remote', 'add', 'origin']);
      expect(code, 1);
      expect(err, 'usage: git remote add <name> <url>\n');
      await runGit(['remote', 'add', 'origin', 'https://x/y']);
      final (_, dup, _) = await runGit([
        'remote',
        'add',
        'origin',
        'https://z/w',
      ]);
      expect(dup, 'fatal: remote origin already exists.\n');
    });

    test('remote remove / get-url usage errors', () async {
      await seedRepo();
      expect(
        (await runGit(['remote', 'remove'])).$2,
        'usage: git remote remove <name>\n',
      );
      expect(
        (await runGit(['remote', 'get-url'])).$2,
        'usage: git remote get-url <name>\n',
      );
    });

    test('remote get-url of an unknown remote answers fatal', () async {
      await seedRepo();
      final (_, err, _) = await runGit(['remote', 'get-url', 'nope']);
      expect(err, "fatal: No such remote 'nope'\n");
    });

    test('remote unknown subcommand keeps the old error', () async {
      await seedRepo();
      final (_, err, _) = await runGit(['remote', 'prune-all']);
      expect(err, 'git remote: unknown subcommand prune-all\n');
    });
  });

  group('show / cat-file / ls-tree plumbing families', () {
    test('show HEAD prints the commit header and message', () async {
      final oid = await seedRepo();
      final (out, _, code) = await runGit(['show']);
      expect(code, 0);
      expect(out, startsWith('commit $oid\nAuthor: Fa <fa@example.com>\n'));
      expect(out, endsWith('\n\nseed commit\n'));
    });

    test('show HEAD:path prints the blob', () async {
      await seedRepo();
      final (out, _, code) = await runGit(['show', 'HEAD:hello.txt']);
      expect(code, 0);
      expect(out, 'hi\n');
    });

    test('cat-file -t / -p on the commit and its blob', () async {
      await seedRepo();
      // `-t` prints the object's type word (GitObject.formatStr()).
      final (type, _, _) = await runGit(['cat-file', '-t', 'HEAD']);
      expect(type, 'commit\n');
      final (blob, _, _) = await runGit(['cat-file', '-p', 'HEAD:hello.txt']);
      expect(blob, 'hi\n');
    });

    test('cat-file usage line without two args', () async {
      await seedRepo();
      expect(
        (await runGit(['cat-file', '-p'])).$2,
        'usage: git cat-file (-p|-t) <object>\n',
      );
    });

    test('ls-tree lists the committed tree entry', () async {
      await seedRepo();
      final (out, _, code) = await runGit(['ls-tree', 'HEAD']);
      expect(code, 0);
      expect(out, matches(RegExp(r'^100644 blob [0-9a-f]{40}\thello\.txt\n$')));
    });

    test('ls-tree without args answers the usage line', () async {
      await seedRepo();
      expect((await runGit(['ls-tree'])).$2, 'usage: git ls-tree <tree-ish>\n');
    });

    test('hash-object hashes without writing; -w writes the blob', () async {
      await seedRepo();
      final (hash, _, _) = await runGit(['hash-object', 'hello.txt']);
      expect(hash, matches(RegExp(r'^[0-9a-f]{40}\n$')));
      final (written, _, _) = await runGit(['hash-object', '-w', 'hello.txt']);
      expect(written, hash);
      expect(
        (await runGit(['hash-object'])).$2,
        'usage: git hash-object [-w] <file>\n',
      );
    });

    test('write-tree writes the staged tree', () async {
      await seedRepo();
      final (tree, _, code) = await runGit(['write-tree']);
      expect(code, 0);
      expect(tree, matches(RegExp(r'^[0-9a-f]{40}\n$')));
    });
  });

  group('merge-base / reset families', () {
    test('merge-base finds the fork point of two branches', () async {
      final base = await seedRepo();
      await runGit(['checkout', '-b', 'topic']);
      io.File(p.join(temp.path, 'topic.txt')).writeAsStringSync('t\n');
      await runGit(['add', 'topic.txt']);
      await runGit(['commit', '-m', 'topic work'], env: authorEnv);
      await runGit(['checkout', 'main']);
      final (out, _, code) = await runGit(['merge-base', 'main', 'topic']);
      expect(code, 0);
      expect(out, '$base\n');
    });

    test('merge-base usage line with fewer than two commits', () async {
      await seedRepo();
      expect(
        (await runGit(['merge-base', 'main'])).$2,
        'usage: git merge-base <commit> <commit>\n',
      );
    });

    test('reset --hard moves HEAD and restores the worktree', () async {
      final base = await seedRepo();
      io.File(p.join(temp.path, 'unwanted.txt')).writeAsStringSync('u\n');
      await runGit(['add', 'unwanted.txt']);
      await runGit(['commit', '-m', 'bad'], env: authorEnv);
      final (out, _, code) = await runGit(['reset', '--hard', base]);
      expect(code, 0);
      // The echo uses the SHORT oid (toOid) — same as real git.
      expect(out, startsWith('HEAD is now at ${base.substring(0, 7)}\n'));
      expect(io.File(p.join(temp.path, 'unwanted.txt')).existsSync(), isFalse);
    });

    test('reset without --hard is rejected', () async {
      await seedRepo();
      expect(
        (await runGit(['reset', 'HEAD'])).$2,
        'git reset: only --hard is supported\n',
      );
      expect(
        (await runGit(['reset'])).$2,
        'usage: git reset [--hard] <commit>\n',
      );
    });
  });

  group('fetch / push validation (offline)', () {
    test('fetch from a missing remote answers the old fatal', () async {
      await seedRepo();
      final (_, err, _) = await runGit(['fetch']);
      expect(err, "fatal: 'origin' does not appear to be a git repository\n");
    });

    test('fetch from a remote without a URL answers the old fatal', () async {
      await seedRepo();
      await runGit(['remote', 'add', 'origin', '']);
      final (_, err, _) = await runGit(['fetch']);
      expect(err, 'fatal: no URL configured for remote origin\n');
    });

    test('push from a missing remote answers the old fatal', () async {
      await seedRepo();
      final (_, err, _) = await runGit(['push']);
      expect(err, "fatal: 'origin' does not appear to be a git repository\n");
    });
  });

  group('clone family (validation + GitHub tarball, offline)', () {
    test('clone without a URL answers the usage line', () async {
      final (out, err, code) = await runGit(['clone']);
      expect(code, 1);
      expect(err, 'usage: git clone <repository> [<directory>]\n');
    });

    test('clone refuses a non-empty destination directory', () async {
      final dest = io.Directory(p.join(temp.path, 'busy'))..createSync();
      io.File(p.join(dest.path, 'x')).writeAsStringSync('x');
      final (_, err, _) = await runGit(['clone', 'whatever', '/busy']);
      expect(
        err,
        "fatal: destination path '/busy' already exists and is not an "
        'empty directory.\n',
      );
    });

    test(
      'clone of a dead http URL on a non-GitHub repo fails loudly',
      () async {
        final client = CannedTarballClient(const []);
        final faHost = FakeGitShellHost(temp.path)..shellHttpClient = client;
        final result = await GitSandboxCommands(faHost).run(
          Stage(command: 'git', args: ['clone', 'https://gitlab.com/o/r']),
          null,
        );
        final stage = result.valueOrNull!;
        expect(stage.exitCode, 1);
        expect(
          utf8.decode(stage.stderr),
          startsWith('fatal: unable to clone:'),
        );
        expect(
          client.requested.single.host,
          'gitlab.com',
          reason: 'smart HTTP is attempted before the tarball fallback',
        );
      },
    );

    test('clone falls back to the GitHub tarball API and materializes a '
        'repository', () async {
      // Build a one-commit fixture repo and pack it as a tar.gz — the same
      // bytes api.github.com/repos/<o>/<r>/tarball would stream.
      final fixtureDir = await io.Directory.systemTemp.createTemp('fa475_src');
      addTearDown(() => fixtureDir.delete(recursive: true));
      io.File(
        p.join(fixtureDir.path, 'README.md'),
      ).writeAsStringSync('# tarball clone\n');
      // GitHub source tarballs contain NO .git — just the snapshot.
      final tgzPath = p.join(temp.parent.path, 'fa475_fixture.tar.gz');
      // Real GitHub tarballs wrap the repository in one `owner-repo-sha`
      // directory — pack the fixture the same way so clone's move-up step
      // runs its production path.
      final tarProc = await io.Process.run('tar', [
        'czf',
        tgzPath,
        '-C',
        p.dirname(fixtureDir.path),
        p.basename(fixtureDir.path),
      ]);
      expect(tarProc.exitCode, 0, reason: '${tarProc.stderr}');
      final tarball = io.File(tgzPath).readAsBytesSync();
      io.File(tgzPath).deleteSync();

      final client = CannedTarballClient(tarball);
      final faHost = FakeGitShellHost(temp.path)..shellHttpClient = client;
      final result = await GitSandboxCommands(faHost).run(
        Stage(
          command: 'git',
          args: ['clone', 'https://github.com/owner/repo', '/cloned'],
        ),
        null,
      );
      final stage = result.valueOrNull!;
      expect(stage.exitCode, 0, reason: utf8.decode(stage.stderr));
      expect(utf8.decode(stage.stdout), "Cloned into '/cloned'\n");
      expect(
        io.File(p.join(temp.path, 'cloned', 'README.md')).readAsStringSync(),
        '# tarball clone\n',
      );
      expect(
        io.Directory(p.join(temp.path, 'cloned', '.git')).existsSync(),
        isTrue,
        reason: 'clone re-inits git for later commands',
      );
      // Smart HTTP is tried first (info/refs), then the tarball fallback.
      expect(client.requested, hasLength(2));
      expect(client.requested.first.host, 'github.com');
      expect(client.requested.first.path, '/owner/repo/info/refs');
      expect(client.requested.last.host, 'api.github.com');
      expect(client.requested.last.path, '/repos/owner/repo/tarball');
    });
  });

  // Pure push/SSH helper tables + remote-tracking ref bookkeeping
  // (issue #568) — no network: the token and arg shapers are static, and
  // the SSH resolver only reads sandbox-mapped paths.
  group('push helpers (issue #568)', () {
    test('parsePushArgs splits remote/branch and defaults the branch', () {
      expect(GitSandboxCommands.parsePushArgs([], null), (remoteName: 'origin', branch: null));
      expect(
        GitSandboxCommands.parsePushArgs(['main'], null),
        (remoteName: 'main', branch: null),
        reason: 'a lone positional names the remote; the current branch '
            'rides along (null when detached)',
      );
      expect(
        GitSandboxCommands.parsePushArgs(['up', 'topic'], null),
        (remoteName: 'up', branch: 'topic'),
      );
      expect(
        GitSandboxCommands.parsePushArgs(['--force', 'up', 'topic', '-q'], null),
        (remoteName: 'up', branch: 'topic'),
        reason: 'flags are ignored, order is remote then branch',
      );
      expect(
        GitSandboxCommands.parsePushArgs(['--force-with-lease'], null),
        (remoteName: 'origin', branch: null),
      );
    });

    test('parsePushArgs falls back to the current branch name', () {
      expect(
        GitSandboxCommands.parsePushArgs([], 'topic'),
        (remoteName: 'origin', branch: 'topic'),
      );
      expect(
        GitSandboxCommands.parsePushArgs(['up'], 'topic'),
        (remoteName: 'up', branch: 'topic'),
      );
    });

    test('resolvePushToken prefers the shell env, then the platform env',
        () {
      const platform = {'GITHUB_TOKEN': 'platform-gh'};
      expect(
        GitSandboxCommands.resolvePushToken(
          {'GIT_TOKEN': 'shell-git'},
          platform,
        ),
        'shell-git',
        reason: 'shell env wins over the platform env',
      );
      expect(
        GitSandboxCommands.resolvePushToken({'FAH_GIT_TOKEN': 'shell-fah'}, platform),
        'shell-fah',
      );
      expect(
        GitSandboxCommands.resolvePushToken({'GITHUB_TOKEN': 'shell-gh'}, platform),
        'shell-gh',
      );
      expect(GitSandboxCommands.resolvePushToken(null, platform), 'platform-gh');
      expect(GitSandboxCommands.resolvePushToken(const {}, const {}), isNull);
    });

    test('stripTrailingSlash strips the trailing slash unconditionally',
        () {
      expect(
        GitSandboxCommands.stripTrailingSlash('/srv/git/repo/'),
        '/srv/git/repo',
      );
      expect(GitSandboxCommands.stripTrailingSlash('/srv/git/repo'), '/srv/git/repo');
      expect(
        GitSandboxCommands.stripTrailingSlash('/'),
        '',
        reason: 'frozen behavior: unconditional single-slash strip',
      );
      expect(GitSandboxCommands.stripTrailingSlash(''), '');
    });

    test('resolveSshKeyPem reads inline keys, key files, then defaults', () async {
      final keyFile = io.File(
        p.join(temp.path, 'id_ed25519'),
      )..writeAsStringSync('not a pem\n');
      final pemFile = io.File(
        p.join(temp.path, 'id_pem'),
      )..writeAsStringSync('-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n');

      // Inline PEM with the marker wins immediately.
      expect(
        GitSandboxCommands.resolveSshKeyPem(
          hostPathOf: (_) => '',
          platformEnv: const {},
          env: {'GIT_SSH_KEY': '-----BEGIN OPENSSH PRIVATE KEY-----\nz'},
        ),
        '-----BEGIN OPENSSH PRIVATE KEY-----\nz',
      );
      // Inline without the marker falls through to key files.
      expect(
        GitSandboxCommands.resolveSshKeyPem(
          hostPathOf: (p) => p == '~/id_pem' ? pemFile.path : '',
          platformEnv: const {},
          env: {'GIT_SSH_KEY': 'plain token', 'GIT_SSH_KEY_PATH': '~/id_pem'},
        ),
        contains('PRIVATE KEY'),
      );
      // A key file without the PEM marker is skipped too.
      expect(
        GitSandboxCommands.resolveSshKeyPem(
          hostPathOf: (p) => p == '~/id_ed25519' ? keyFile.path : '',
          platformEnv: const {},
          env: {'GIT_SSH_KEY': 'plain', 'GIT_SSH_KEY_PATH': '~/id_ed25519'},
        ),
        isNull,
        reason: 'non-PEM key material is rejected like the old inline check',
      );
      // The sandbox default candidates resolve through hostPathOf.
      expect(
        GitSandboxCommands.resolveSshKeyPem(
          hostPathOf: (p) => p == '/.ssh/id_ed25519' ? pemFile.path : '',
          platformEnv: const {},
          env: null,
        ),
        contains('PRIVATE KEY'),
      );
    });

    test('trackPushedRef mirrors the pushed branch under refs/remotes',
        () async {
      final (stdout, stderr, code) =
          await runGit(['init', '-b', 'main']);
      expect(code, 0, reason: stderr);
      expect(stdout, isNotEmpty);

      final repo = dart_git.GitRepository.load(temp.path);
      addTearDown(repo.close);
      final head = repo.currentBranch();
      expect(head, 'main');

      // Unborn HEAD: no refs/remotes/origin/main exists yet, and the
      // helper must not invent one from nothing.
      GitSandboxCommands.trackPushedRef(repo, 'origin', 'main');

      // Seed the branch ref, push again, and the mirror appears.
      const hash = 'b3c1526fe274e47d3270da3412314fa25b86c779';
      repo.refStorage.saveRef(
        HashReference(
          ReferenceName.branch('main'),
          GitHash(hash),
        ),
      );
      GitSandboxCommands.trackPushedRef(repo, 'origin', 'main');
      final remoteRef = repo.resolveReferenceName(
        ReferenceName.remote('origin', 'main'),
      );
      expect(remoteRef?.hash.toString(), hash);
    });
  });

  group('branch listing helpers (issue #568)', () {
    test('-r lists remote-tracking refs, -a lists both, -l lists local',
        () async {
      await runGit(['init', '-b', 'main']);
      final repo = dart_git.GitRepository.load(temp.path);
      addTearDown(repo.close);
      const hash = 'b3c1526fe274e47d3270da3412314fa25b86c779';
      repo.refStorage.saveRef(
        HashReference(
          ReferenceName.branch('main'),
          GitHash(hash),
        ),
      );
      repo.refStorage.saveRef(
        HashReference(
          ReferenceName.branch('feature'),
          GitHash(hash),
        ),
      );
      repo.refStorage.saveRef(
        HashReference(
          ReferenceName.remote('origin', 'main'),
          GitHash(hash),
        ),
      );

      final (rOut, _, rCode) = await runGit(['branch', '-r']);
      expect(rCode, 0);
      expect(rOut, 'origin/main\n');

      final (aOut, _, aCode) = await runGit(['branch', '-a']);
      expect(aCode, 0);
      expect(
        aOut.split('\n'),
        containsAll(['* main', '  feature', 'origin/main']),
      );

      final (lOut, _, lCode) = await runGit(['branch']);
      expect(lCode, 0);
      expect(lOut, '  feature\n* main\n');
    });

    test('branch listing of an unborn repo answers with an empty line set',
        () async {
      await runGit(['init', '-b', 'main']);
      final (out, _, code) = await runGit(['branch']);
      expect(code, 0);
      expect(out, '\n', reason: 'no branches yet: the line list is empty');
    });
  });
}
