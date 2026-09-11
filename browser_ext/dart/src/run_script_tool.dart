// run_script — executes user scripts in browser-hosted interpreters
// (python via pyodide, javascript via quickjs-emscripten) inside the
// extension's MV3 offscreen document, giving the SW agent the same
// script-execution capability the web app sandbox has (the SW itself
// cannot spawn processes and extension CSP forbids remote scripts, so
// the interpreter runtimes are vendored into the extension and loaded
// by the offscreen page; see browser_ext/offscreen/interpreters.js).
//
// The file is pure Dart: the chrome.runtime.sendMessage hop is injected
// as [RunScriptSendMessage] (the js_interop wiring lives in
// chrome_api_js.dart), and the offscreen document lifecycle rides the
// typed [OffscreenApi] facade — so the whole flow is VM-testable with
// FakeChrome.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/types.dart';

import 'chrome_api.dart';

/// Message marker the offscreen interpreter page answers (other
/// runtime.onMessage listeners must ignore it).
const runScriptMessageMarker = '__fahRunScript';

/// The offscreen document that hosts the interpreters (shared with the
/// DOM-extraction surface — one MV3 document at a time).
const runScriptOffscreenUrl = 'offscreen.html';

/// Languages the offscreen page knows how to run.
const runScriptLanguages = {'python', 'javascript'};

/// Delivers one JSON-able message to the offscreen document and awaits
/// its reply (chrome.runtime.sendMessage in the real wiring).
typedef RunScriptSendMessage =
    Future<Map<String, Object?>> Function(Map<String, Object?> message);

/// Executes one script run in [language] and returns the interpreter
/// reply map ({ok, stdout, stderr, error}).
typedef RunScriptExecutor =
    Future<Map<String, Object?>> Function(String language, String code);

/// Runs [code] in [language] inside the offscreen document, creating the
/// document on first use. Returns the page's reply map
/// ({stdout, stderr, error}); throws [StateError] when the document is
/// unavailable or the reply is malformed.
Future<Map<String, Object?>> offscreenRunScript({
  required OffscreenApi offscreen,
  required RunScriptSendMessage sendMessage,
  required String language,
  required String code,
}) async {
  if (!runScriptLanguages.contains(language)) {
    throw ArgumentError.value(
      language,
      'language',
      'must be one of ${runScriptLanguages.join(', ')}',
    );
  }
  if (!await offscreen.hasDocument()) {
    try {
      await offscreen.createDocument(
        url: runScriptOffscreenUrl,
        reasons: {'WORKERS'},
        justification:
            'Run user scripts in the bundled Python/JavaScript '
            'interpreters (run_script tool).',
      );
    } on ChromeApiException catch (e) {
      // A document leaked by a previous SW life (or raced by the DOM
      // extraction surface) is FINE — the shared page hosts both.
      if (e.code != 'document_exists') rethrow;
    }
  }
  final reply = await sendMessage({
    runScriptMessageMarker: true,
    'language': language,
    'code': code,
  });
  if (reply['ok'] != true) {
    throw StateError(
      'run_script failed in the offscreen document: '
      '${reply['error'] ?? 'no interpreter answered'}',
    );
  }
  return reply;
}

/// The `run_script` agent tool. [execute] performs one script run and
/// returns the interpreter reply map ({stdout, stderr, error}); the
/// production executor is [offscreenRunScript] over the real chrome
/// facades, tests inject a fake.
AgentTool runScriptTool({required RunScriptExecutor execute}) {
  return AgentTool(
    name: 'run_script',
    description:
        'Run a script in a sandboxed interpreter and return its '
        'stdout/stderr. language "python" is CPython (pyodide, WASM — no '
        'host filesystem) with the standard library; "javascript" is '
        'QuickJS (no DOM). Use this for data processing, calculations, '
        'file-format work — anything that needs a real interpreter '
        'instead of reasoning. Print results to stdout; the tool returns '
        'stdout, stderr and any script error. The first python call '
        'takes a few seconds while the interpreter boots.\n'
        'NETWORK IS AVAILABLE and CORS-free (the extension host has '
        '<all_urls> permissions — unlike a web page, scripts can reach '
        'any URL): in javascript use the global '
        '`fetch(url, {method, headers, body})` (await it; resolves to '
        '`{status, headers, body}` with body as text, 30s timeout); in '
        'python use `await fetch(url, method="GET", headers=None, '
        'body=None)` (same result dict; top-level await is supported) '
        'or pyodide\'s own pyfetch. Prefer fetch over guessing URLs.',
    parameters: const {
      'type': 'object',
      'properties': {
        'language': {
          'type': 'string',
          'enum': ['python', 'javascript'],
          'description': 'Which interpreter runs the script.',
        },
        'code': {
          'type': 'string',
          'description': 'The script source to execute.',
        },
      },
      'required': ['language', 'code'],
    },
    tier: ApprovalTier.exec,
    execute: (arguments, cancelToken, onUpdate) async {
      final language = arguments['language'];
      final code = arguments['code'];
      if (language is! String || !runScriptLanguages.contains(language)) {
        throw ArgumentError.value(
          language,
          'language',
          'must be one of ${runScriptLanguages.join(', ')}',
        );
      }
      if (code is! String || code.trim().isEmpty) {
        throw ArgumentError.value(code, 'code', 'must be a non-empty script');
      }
      final reply = await execute(language, code);
      final stdout = reply['stdout'] as String? ?? '';
      final stderr = reply['stderr'] as String? ?? '';
      final scriptError = reply['error'];
      // A script-level failure (python traceback, JS exception) is a
      // RESULT the model reads and fixes — only transport failures throw.
      return ToolExecutionResult(
        content: [
          TextContent(
            text: jsonEncode({
              'ok': scriptError == null,
              'language': language,
              'stdout': stdout,
              if (stderr.isNotEmpty) 'stderr': stderr,
              'error': ?scriptError,
            }),
          ),
        ],
      );
    },
  );
}
