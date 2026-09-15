/// Unit tests for the password-ask detector (issue #367): a foreground
/// command's output stream is watched for password-ask prompts (`[sudo]
/// password for user:`, `Password:`, `passphrase`, `Verification code`).
///
/// Contract (GOAL #367 fix contract item 1 + edge cases):
/// - the match is anchored to the prompt at line END (a trailing `:` with
///   nothing but whitespace after it) — ordinary prose mentioning
///   "Password:" mid-line never fires;
/// - the callback fires only after a short quiet window, so streamed
///   documents whose chunk just happens to end at a colon do not flip the
///   sheet (E4); new output before the window elapses re-arms;
/// - while an answer is pending the detector stays muted (one sheet at a
///   time) and re-arms after the answer — a wrong-password retry (E1)
///   re-arms per detected prompt;
/// - the reported title is the actual prompt line (trimmed).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late List<String> prompts;
  late PasswordPromptDetector detector;

  /// A detector with a zero quiet window (synchronous-ish for tests) unless
  /// the test overrides it to exercise the debounce.
  PasswordPromptDetector build({Duration? quiet}) {
    return PasswordPromptDetector(
      onPrompt: prompts.add,
      quiet: quiet ?? Duration.zero,
    );
  }

  setUp(() {
    prompts = [];
    detector = build();
  });

  tearDown(() => detector.dispose());

  /// One event-loop turn: lets a zero quiet window fire.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('detects the sudo/password asks', () {
    test('AC1: [sudo] password for user: with the full line as title',
        () async {
      detector.feed('[sudo] password for user:');
      await settle();
      expect(prompts, equals(['[sudo] password for user:']));
    });

    test('bare Password: prompt (sudo retry, ssh)', () async {
      detector.feed('Sorry, try again.\nPassword:');
      await settle();
      expect(prompts, equals(['Password:']));
    });

    test("ssh's user@host password prompt", () async {
      detector.feed("git@github.com's password:");
      await settle();
      expect(prompts, equals(["git@github.com's password:"]));
    });

    test('passphrase prompt (ssh key, disk encryption)', () async {
      detector.feed("Enter passphrase for key '/home/u/.ssh/id_ed25519':");
      await settle();
      expect(
        prompts,
        equals(["Enter passphrase for key '/home/u/.ssh/id_ed25519':"]),
      );
    });

    test('TOTP verification code prompt', () async {
      detector.feed('Verification code:');
      await settle();
      expect(prompts, equals(['Verification code:']));
    });

    test('prompt split across chunks (rolling window)', () async {
      detector.feed('[sudo] password for ');
      detector.feed('user:');
      await settle();
      expect(prompts, equals(['[sudo] password for user:']));
    });

    test('prompt after complete lines: only the partial line is the title',
        () async {
      detector.feed('some earlier output\r\n[sudo] password for user:  ');
      await settle();
      expect(prompts, equals(['[sudo] password for user:']));
    });

    test('stderr chunks feed the same detector (sudo prompts on stderr)',
        () async {
      detector.feed('regular output\n');
      detector.feed('[sudo] password for user:');
      await settle();
      expect(prompts, equals(['[sudo] password for user:']));
    });

    test('a newline-terminated Password: line is ordinary output', () {
      detector.feed('Password:\n');
      expect(prompts, isEmpty);
    });

    test('prose mentioning Password: mid-line', () {
      detector.feed('See the Password: section of the manual for details');
      expect(prompts, isEmpty);
    });

    test('password-shaped word without the colon', () {
      detector.feed('please enter your password');
      expect(prompts, isEmpty);
    });

    test('PASSWD: and Token prompts are out of scope', () {
      detector.feed('Token:');
      expect(prompts, isEmpty);
    });
  });

  group('quiet-window debounce', () {
    test('new output inside the quiet window cancels the pending match',
        () async {
      final d = build(quiet: const Duration(milliseconds: 40));
      d.feed('Password:');
      // More output arrives before the window elapses — the "prompt" was
      // just a chunk boundary in a streamed document.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      d.feed(' more prose following the colon\n');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(prompts, isEmpty);
      d.dispose();
    });

    test('the match fires after the quiet window holds', () async {
      final d = build(quiet: const Duration(milliseconds: 40));
      d.feed('[sudo] password for user:');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(prompts, equals(['[sudo] password for user:']));
      d.dispose();
    });

    test('output resuming after the fire does not re-fire by itself',
        () async {
      final d = build(quiet: const Duration(milliseconds: 20));
      d.feed('Password:');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(prompts, hasLength(1));
      // Output resumes (the answered process continues) — no pending match,
      // no double sheet.
      d.feed('ok\n');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(prompts, hasLength(1));
      d.dispose();
    });
  });

  group('re-arm lifecycle (E1)', () {
    test('muted while the answer is pending; re-arms after the answer',
        () async {
      var answerGate = Completer<void>();
      final d = PasswordPromptDetector(
        onPrompt: (line) async {
          prompts.add(line);
          await answerGate.future;
        },
        quiet: Duration.zero,
      );
      d.feed('[sudo] password for user:');
      await Future<void>.delayed(Duration.zero);
      // A second prompt-shaped burst while the first sheet is open is
      // ignored — one sheet at a time.
      d.feed('\nPassword:');
      expect(prompts, hasLength(1));
      answerGate.complete();
      await Future<void>.delayed(Duration.zero);
      // Wrong password: sudo prints the retry and asks again — the sheet
      // re-arms.
      d.feed('Sorry, try again.\nPassword:');
      expect(prompts, equals(['[sudo] password for user:', 'Password:']));
      d.dispose();
    });

    test('dispose cancels the pending quiet timer', () async {
      final d = build(quiet: const Duration(milliseconds: 30));
      d.feed('Password:');
      d.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(prompts, isEmpty);
    });
  });
}
