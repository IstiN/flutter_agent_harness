// VM tests for the run_script tool (browser_ext/dart/src/run_script_tool.dart):
// argument validation, result mapping (script-level errors are RESULTS,
// transport failures throw) and the offscreen-document lifecycle over
// FakeChrome (create-on-first-use with WORKERS, adopt an existing doc,
// tolerate document_exists races, malformed replies surface).
import 'dart:convert';

import '../src/chrome_api.dart';
import '../src/fake_chrome.dart';
import '../src/run_script_tool.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

void main() {
  group('runScriptTool', () {
    test('runs a script and returns stdout', () async {
      final tool = runScriptTool(
        execute: (language, code) async => {
          'ok': true,
          'stdout': 'hello $language',
          'stderr': '',
          'error': null,
        },
      );
      final result = await tool.execute(
        {'language': 'python', 'code': 'print(1)'},
        null,
        null,
      );
      final text = (result.content.single as TextContent).text;
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      expect(decoded['language'], 'python');
      expect(decoded['stdout'], 'hello python');
      expect(decoded.containsKey('stderr'), isFalse); // empty stderr omitted
    });

    test('script-level errors are results, not tool failures', () async {
      final tool = runScriptTool(
        execute: (language, code) async => {
          'ok': true,
          'stdout': '',
          'stderr': '',
          'error': 'Traceback (most recent call last): ... NameError: x',
        },
      );
      final result = await tool.execute(
        {'language': 'python', 'code': 'x'},
        null,
        null,
      );
      final decoded =
          jsonDecode((result.content.single as TextContent).text)
              as Map<String, dynamic>;
      expect(decoded['ok'], isFalse);
      expect(decoded['error'], contains('NameError'));
    });

    test('stderr rides along when non-empty', () async {
      final tool = runScriptTool(
        execute: (language, code) async => {
          'ok': true,
          'stdout': 'out',
          'stderr': 'warn!',
          'error': null,
        },
      );
      final result = await tool.execute(
        {'language': 'javascript', 'code': 'console.warn(1)'},
        null,
        null,
      );
      final decoded =
          jsonDecode((result.content.single as TextContent).text)
              as Map<String, dynamic>;
      expect(decoded['stderr'], 'warn!');
    });

test('description documents the CORS-free network bridge', () {
      final tool = runScriptTool(execute: (_, _) async => {'ok': true});
      expect(tool.description, contains('fetch'));
      expect(tool.description, contains('CORS-free'));
    });

    test('rejects an unknown language', () async {
      final tool = runScriptTool(
        execute: (language, code) async => throw StateError('must not run'),
      );
      expect(
        () => tool.execute({'language': 'ruby', 'code': 'puts 1'}, null, null),
        throwsArgumentError,
      );
    });

    test('rejects empty code', () async {
      final tool = runScriptTool(
        execute: (language, code) async => throw StateError('must not run'),
      );
      expect(
        () => tool.execute({'language': 'python', 'code': '   '}, null, null),
        throwsArgumentError,
      );
      expect(
        () => tool.execute({'language': 'python', 'code': 42}, null, null),
        throwsArgumentError,
      );
    });

    test('transport failures propagate as tool errors', () async {
      final tool = runScriptTool(
        execute: (language, code) async =>
            throw StateError('offscreen unavailable'),
      );
      expect(
        () => tool.execute({'language': 'python', 'code': '1'}, null, null),
        throwsStateError,
      );
    });

    test('declares the exec approval tier', () {
      final tool = runScriptTool(
        execute: (language, code) async => {'ok': true},
      );
      expect(tool.tier.name, 'exec');
      expect(tool.name, 'run_script');
    });
  });

  group('offscreenRunScript', () {
    test('creates the offscreen document on first use (WORKERS)', () async {
      final chrome = FakeChrome();
      expect(await chrome.offscreen.hasDocument(), isFalse);
      Map<String, Object?>? sent;
      final reply = await offscreenRunScript(
        offscreen: chrome.offscreen,
        sendMessage: (message) async {
          sent = message;
          return {'ok': true, 'stdout': 'hi', 'stderr': '', 'error': null};
        },
        language: 'python',
        code: 'print("hi")',
      );
      expect(reply['stdout'], 'hi');
      expect(await chrome.offscreen.hasDocument(), isTrue);
      expect(sent, {
        runScriptMessageMarker: true,
        'language': 'python',
        'code': 'print("hi")',
      });
    });

    test('adopts an already-open document (no recreate)', () async {
      final chrome = FakeChrome();
      await chrome.offscreen.createDocument(
        url: runScriptOffscreenUrl,
        reasons: const {'DOM_SCRAPING'},
        justification: 'DOM extraction opened it first',
      );
      var calls = 0;
      await offscreenRunScript(
        offscreen: chrome.offscreen,
        sendMessage: (message) async {
          calls++;
          return {'ok': true, 'stdout': '', 'stderr': '', 'error': null};
        },
        language: 'javascript',
        code: '1',
      );
      expect(calls, 1);
    });

    test('a document_exists race is tolerated', () async {
      final offscreen = _RacingOffscreen();
      final reply = await offscreenRunScript(
        offscreen: offscreen,
        sendMessage: (message) async =>
            {'ok': true, 'stdout': 'x', 'stderr': '', 'error': null},
        language: 'python',
        code: '1',
      );
      expect(reply['stdout'], 'x');
    });

    test('an ok:false reply surfaces as a StateError', () async {
      final chrome = FakeChrome();
      expect(
        () => offscreenRunScript(
          offscreen: chrome.offscreen,
          sendMessage: (message) async =>
              {'ok': false, 'error': 'failed to load pyodide.js'},
          language: 'python',
          code: '1',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('failed to load pyodide.js'),
          ),
        ),
      );
    });

    test('rejects an unknown language before touching chrome', () async {
      final chrome = FakeChrome();
      expect(
        () => offscreenRunScript(
          offscreen: chrome.offscreen,
          sendMessage: (message) async => {'ok': true},
          language: 'ruby',
          code: '1',
        ),
        throwsArgumentError,
      );
      expect(await chrome.offscreen.hasDocument(), isFalse);
    });
  });
}

/// Simulates the createDocument race: hasDocument says no, createDocument
/// then reports document_exists (another surface opened it in between) —
/// and afterwards the document IS there.
final class _RacingOffscreen implements OffscreenApi {
  bool _open = false;

  @override
  Future<bool> hasDocument() async => _open;

  @override
  Future<void> createDocument({
    required String url,
    required Set<String> reasons,
    required String justification,
  }) async {
    if (_open) {
      throw ChromeApiException('document_exists', 'already open: $url');
    }
    _open = true;
    // Lose the race: the caller's create attempt sees document_exists.
    throw ChromeApiException('document_exists', 'lost the race for $url');
  }

  @override
  Future<void> closeDocument() async {
    _open = false;
  }
}
