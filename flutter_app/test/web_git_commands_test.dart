// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Pure unit tests for the web git porcelain (`WebGitCommands`, issue
/// #568): the branch and remote families run against an in-memory
/// filesystem — no browser, no dart:io, no network. Every assertion pins
/// the exact stdout/stderr/exit-code triple the pre-split switch produced,
/// so the dispatch refactor stays invisible to shell users.
library;

import 'package:fa/sandbox/web_git.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _gitEnv = {
  'GIT_AUTHOR_NAME': 'T',
  'GIT_AUTHOR_EMAIL': 't@t',
  'GIT_COMMITTER_NAME': 'T',
  'GIT_COMMITTER_EMAIL': 't@t',
};

void main() {
  late WebGitCommands git;
  late MemoryFileSystem fs;

  setUp(() {
    fs = MemoryFileSystem();
    git = WebGitCommands(fs);
  });

  Future<({String stdout, String stderr, int exitCode})> runGit(
    List<String> args, {
    String cwd = '/r',
    Map<String, String>? env,
  }) => git.run(args, cwd: cwd, env: env);

  /// Seeds a repo with one commit on the default branch - branch creation
  /// needs a real HEAD commit (frozen behavior: unborn HEAD answers
  /// `fatal: GitRefNotFound`).
  Future<void> seedCommit() async {
    await runGit(['init', 'r'], cwd: '/');
    await fs.writeFile('/r/f.txt', 'seed');
    await runGit(['add', 'f.txt']);
    final commit = await runGit(['commit', '-m', 'seed'], env: _gitEnv);
    assert(commit.exitCode == 0, commit.stderr);
  }

  group('branch family (issue #568)', () {
    test('branch creates, lists with star, and deletes', () async {
      await seedCommit();
      expect((await runGit(['branch'])).stdout, '* main\n');

      expect((await runGit(['branch', 'feature'])).exitCode, 0);
      expect((await runGit(['branch'])).stdout, '  feature\n* main\n');

      expect((await runGit(['branch', '-d', 'feature'])).exitCode, 0);
      expect((await runGit(['branch'])).stdout, '* main\n');
    });

    test('branch -d without a name answers the usage line', () async {
      await runGit(['init', 'r'], cwd: '/');
      final res = await runGit(['branch', '-d']);
      expect(res.exitCode, 1);
      expect(res.stderr, 'usage: git branch -d <branch>\n');
    });

    test('unknown branch options are rejected with the old message',
        () async {
      await runGit(['init', 'r'], cwd: '/');
      final res = await runGit(['branch', '--squash']);
      expect(res.exitCode, 1);
      expect(res.stderr, 'git branch: unknown option --squash\n');
    });

    test('list flags (-r -a) are tolerated and list local branches',
        () async {
      await seedCommit();
      await runGit(['branch', 'feature']);
      final listing = await runGit(['branch']);
      for (final flag in ['-r', '-a']) {
        final res = await runGit(['branch', flag]);
        expect(res.exitCode, 0);
        expect(res.stdout, listing.stdout,
            reason: 'no remote-tracking refs exist on web without fetch; '
                '$flag lists like a plain branch listing');
      }
    });
  });

  group('remote family (issue #568)', () {
    test('add/list/-v/get-url/remove round trip', () async {
      await runGit(['init', 'r'], cwd: '/');

      final empty = await runGit(['remote']);
      expect(empty.exitCode, 0);
      expect(empty.stdout, '');

      expect(
        (await runGit(['remote', 'add', 'origin', 'https://x/repo.git']))
            .exitCode,
        0,
      );
      expect((await runGit(['remote'])).stdout, 'origin\n');

      final verbose = await runGit(['remote', '-v']);
      expect(
        verbose.stdout,
        'origin\thttps://x/repo.git (fetch)\n'
        'origin\thttps://x/repo.git (push)\n',
      );
      expect(
        (await runGit(['remote', '--verbose'])).stdout,
        verbose.stdout,
        reason: '--verbose is the same surface as -v',
      );

      expect(
        (await runGit(['remote', 'get-url', 'origin'])).stdout,
        'https://x/repo.git\n',
      );

      final duplicate = await runGit(
        ['remote', 'add', 'origin', 'https://y/repo.git'],
      );
      expect(duplicate.exitCode, 1);
      expect(duplicate.stderr, 'fatal: remote origin already exists.\n');

      expect((await runGit(['remote', 'rm', 'origin'])).exitCode, 0);
      expect((await runGit(['remote'])).stdout, '');
    });

    test('usage and unknown-subcommand errors keep the old strings',
        () async {
      await runGit(['init', 'r'], cwd: '/');
      expect(
        (await runGit(['remote', 'add'])).stderr,
        'usage: git remote add <name> <url>\n',
      );
      expect(
        (await runGit(['remote', 'remove'])).stderr,
        'usage: git remote remove <name>\n',
      );
      expect(
        (await runGit(['remote', 'get-url'])).stderr,
        'usage: git remote get-url <name>\n',
      );
      expect(
        (await runGit(['remote', 'get-url', 'nope'])).stderr,
        "fatal: No such remote 'nope'\n",
      );
      expect(
        (await runGit(['remote', 'bogus'])).stderr,
        'git remote: unknown subcommand bogus\n',
      );
    });
  });
}
