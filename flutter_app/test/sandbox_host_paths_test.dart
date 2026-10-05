// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

// gh-1274 review: the "is this path inside the sandbox host directory"
// test used to be re-implemented (with subtle differences) in
// WasiSandboxShell._effectiveCwd, WasiSandboxShell._hostPath, and
// SandboxedExecutionEnv._map. It now lives in one shared helper so the
// three call sites cannot drift apart. These tests pin the helper's
// semantics, including the hardening against the path variants that would
// otherwise silently re-leak the host cwd into guest path resolution.

import 'dart:io' as io;

import 'package:fa/sandbox/sandbox_host_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SandboxHostRoot.stripToSandboxPath', () {
    test('root itself strips to /', () {
      final root = SandboxHostRoot('/x/fah_sandbox', caseInsensitive: false);
      expect(root.stripToSandboxPath('/x/fah_sandbox'), '/');
    });

    test('subdir strips to its sandbox-absolute form', () {
      final root = SandboxHostRoot('/x/fah_sandbox', caseInsensitive: false);
      expect(root.stripToSandboxPath('/x/fah_sandbox/work'), '/work');
      expect(
        root.stripToSandboxPath('/x/fah_sandbox/work/notes.txt'),
        '/work/notes.txt',
      );
    });

    test('trailing separators on either side are ignored', () {
      final root = SandboxHostRoot('/x/fah_sandbox/', caseInsensitive: false);
      expect(root.stripToSandboxPath('/x/fah_sandbox'), '/');
      expect(root.stripToSandboxPath('/x/fah_sandbox/'), '/');
      expect(root.stripToSandboxPath('/x/fah_sandbox/work/'), '/work');
    });

    test('a lone / root is preserved', () {
      final root = SandboxHostRoot('/', caseInsensitive: false);
      expect(root.stripToSandboxPath('/'), '/');
      expect(root.stripToSandboxPath('/work'), '/work');
      expect(root.stripToSandboxPath('/work/'), '/work');
    });

    test('a path spelled through a symlink resolves against the real root', () {
      final tmp = io.Directory.systemTemp.createTempSync('fah_hostroot');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final real = io.Directory('${tmp.path}/real')..createSync();
      io.Directory('${real.path}/work').createSync();
      final link = io.Link('${tmp.path}/link')..createSync(real.path);

      final root = SandboxHostRoot(real.path, caseInsensitive: false);
      // Same directory, different string: iOS simulator /var → /private/var
      // shape. Must still strip back into the sandbox.
      expect(root.stripToSandboxPath('${link.path}/work'), '/work');
      expect(root.stripToSandboxPath(link.path), '/');
    });

    test('case variants fold only when case-insensitive matching is on', () {
      final folded = SandboxHostRoot('/x/FAH_sandbox', caseInsensitive: true);
      expect(folded.stripToSandboxPath('/x/fah_sandbox/work'), '/work');

      final strict = SandboxHostRoot('/x/FAH_sandbox', caseInsensitive: false);
      expect(strict.stripToSandboxPath('/x/fah_sandbox/work'), isNull);
    });

    test('relative remainder is normalized lexically', () {
      final root = SandboxHostRoot('/x/fah_sandbox', caseInsensitive: false);
      expect(root.stripToSandboxPath('/x/fah_sandbox/a/../b'), '/b');
    });

    test('paths outside the root return null', () {
      final root = SandboxHostRoot('/x/fah_sandbox', caseInsensitive: false);
      expect(root.stripToSandboxPath('/x/other'), isNull);
      expect(root.stripToSandboxPath('/x/fah_sandbox'), isNotNull);
      // A sibling whose name merely shares the root's textual prefix must
      // not count as inside the root.
      expect(root.stripToSandboxPath('/x/fah_sandbox2/work'), isNull);
      expect(root.stripToSandboxPath(''), isNull);
      expect(root.stripToSandboxPath('work/t.txt'), isNull);
    });

    test('contains mirrors stripToSandboxPath', () {
      final root = SandboxHostRoot('/x/fah_sandbox', caseInsensitive: false);
      expect(root.contains('/x/fah_sandbox'), isTrue);
      expect(root.contains('/x/fah_sandbox/work'), isTrue);
      expect(root.contains('/x/other'), isFalse);
    });
  });
}
