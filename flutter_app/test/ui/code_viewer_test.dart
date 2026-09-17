// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:fa/ui/widgets/code_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// An env whose text writes are scripted: [fail] sends the next save onto
/// the failure path (disk-full style), and [holdWrites] parks writes until
/// released so the in-flight save window is observable. The core envs are
/// `final`, so this forwards to an inner [MemoryExecutionEnv].
final class _ScriptedEnv implements ExecutionEnv {
  _ScriptedEnv({this.fail = false});

  bool fail;
  Completer<void>? holdWrites;

  final MemoryExecutionEnv _inner = MemoryExecutionEnv();

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) {
    if (fail) {
      return Future.value(Err(FileError(FileErrorCode.unknown, 'disk full')));
    }
    final held = holdWrites;
    if (held != null) {
      return held.future.then((_) => _inner.writeFile(path, content));
    }
    return _inner.writeFile(path, content);
  }

  @override
  String get cwd => _inner.cwd;
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _inner.exec(command, options: options);
  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _inner.readTextFile(path);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _inner.readBinaryFile(path);
  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _inner.fileInfo(path);
  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);
  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _inner.appendFile(path, content);
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _inner.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _inner.writeBinaryFile(path, content);
}

Future<void> _pump(WidgetTester tester, CodeEditor editor) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SizedBox(height: 200, child: editor))),
  );
}

void main() {
  testWidgets('a successful save writes the buffer and reports Saved', (
    tester,
  ) async {
    final env = _ScriptedEnv();
    var saved = 0;
    await _pump(
      tester,
      CodeEditor(
        content: 'hello',
        path: 'docs/note.md',
        env: env,
        onSaved: () => saved++,
      ),
    );

    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();

    expect(saved, 1);
    expect(find.text('Saved'), findsOneWidget);
    expect(
      (await env.readTextFile('docs/note.md')).valueOrNull,
      'hello world',
    );
  });

  testWidgets('a failed save surfaces the error and keeps the editor', (
    tester,
  ) async {
    final env = _ScriptedEnv(fail: true);
    var saved = 0;
    await _pump(
      tester,
      CodeEditor(
        content: 'hello',
        path: 'docs/note.md',
        env: env,
        onSaved: () => saved++,
      ),
    );

    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();

    expect(saved, 0);
    expect(find.text('Save failed: disk full'), findsOneWidget);
    // The snackbar carries the message; the error text stays for the next
    // build's error styling.
    expect(find.byIcon(Icons.save), findsOneWidget);
  });

  testWidgets('the save button is disabled while a save is in flight', (
    tester,
  ) async {
    final env = _ScriptedEnv();
    await _pump(
      tester,
      CodeEditor(content: 'hello', path: 'docs/note.md', env: env),
    );

    // Park the write: one pump later the save is still in flight, so the
    // button must be disabled.
    env.holdWrites = Completer<void>();
    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    final saveButton = find.ancestor(
      of: find.byIcon(Icons.save),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(saveButton).onPressed, isNull);

    // Release the write: the save completes and the button re-enables.
    env.holdWrites!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(saveButton).onPressed, isNotNull);
  });
}
