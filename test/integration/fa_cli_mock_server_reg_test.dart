// REG guard for the gh-1310 red validation leg (run 37454243139,
// PTY/CLI integration linux shard 0/3): the approval-selector PTY test
// failed WITHOUT any of its own assertions failing. The in-process
// `MockOpenAiServer` threw `HttpException: Connection closed while
// receiving data, uri = /v1/chat/completions` — dart:io's SERVER-side
// error when the HTTP client disappears mid-request-body — and the
// unhandled zone error was attributed to whatever test was running.
// The CLI under test vanishes mid-request as a matter of course: the
// provider layer cancels an in-flight request when a transient stream
// error triggers a retry, a watchdog aborts a stalled read, and the
// PTY harness kills the CLI in teardown while a request is open.
//
// Contract: a client aborting mid-request (or mid-response) must never
// leak an unhandled error out of the mock, and the mock must keep
// serving the requests that follow; scripting bugs still propagate.
// Hermetic (raw loopback socket only, no PTY, no spawn) and deliberately
// UNTAGGED so the default suite — pre-commit gate and quality core —
// enforces it, per the pty_screen_wait_reg_test.dart doctrine: the flake
// it prevents reproduces only under real aborts on loaded runners.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'fa_cli_fixtures.dart';

void main() {
  test(
    'MockOpenAiServer: a client abort mid-request leaks no unhandled error',
    () async {
      final errors = <Object>[];
      void recordError(Object error, StackTrace stackTrace) {
        errors.add(error);
      }

      MockOpenAiServer? mock;
      await runZonedGuarded(() async {
        mock = MockOpenAiServer();
        await mock!.start();
        // The provider layer's cancel-and-retry: declare a request body
        // longer than what is actually sent, then destroy the socket
        // before the server finishes reading it.
        final socket = await Socket.connect('127.0.0.1', mock!.port);
        const partial = '{"model": "test-model"';
        socket.write(
          'POST /v1/chat/completions HTTP/1.1\r\n'
          'Host: 127.0.0.1\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${partial.length + 512}\r\n'
          '\r\n'
          '$partial',
        );
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        socket.destroy();

        // Let the server observe the mid-body EOF and run its handler.
        await Future<void>.delayed(const Duration(milliseconds: 250));

        // The mock must keep serving after an abort: a complete request
        // on a fresh connection is still scripted normally.
        final client = HttpClient();
        final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:${mock!.port}/v1/chat/completions'),
        );
        req.add(utf8.encode('{"complete": true}'));
        final res = await req.close();
        await res.drain<void>();
        client.close(force: true);
        await mock!.close();
      }, recordError);

      expect(
        errors,
        isEmpty,
        reason:
            'an aborted request surfaced an unhandled error from the mock '
            'server — dart test attributes unhandled zone errors to the '
            'currently-running test, so any PTY suite riding the mock can be '
            'failed by an abort that belongs to no assertion (gh-1310 red '
            'validation leg, run 37454243139). Errors observed: $errors',
      );
      expect(
        mock?.bodies,
        equals(['{"complete": true}']),
        reason:
            'the mock must keep serving complete requests after an '
            'aborted one — the aborted body is never recorded',
      );
    },
  );
}
