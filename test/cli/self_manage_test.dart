// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:test/test.dart';

import '../../bin/self_manage.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fa_self_manage_test');
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File fakeExe(List<int> magic) {
    final dir = Directory('${temp.path}/.pub-cache/bin')
      ..createSync(recursive: true);
    return File('${dir.path}/fa')..writeAsBytesSync(magic);
  }

  group('classifyInstall', () {
    test('a .dart script is a dev run', () {
      final install = classifyInstall(
        scriptPath: '/repo/bin/fah.dart',
        executablePath: '/usr/bin/dart',
      );
      expect(install.kind, InstallKind.devRun);
    });

    test('a pub-cache snapshot is a pub-global install', () {
      // Kernel snapshots are not native executables (no Mach-O/ELF/PE magic).
      final exe = fakeExe(const [0x90, 0xAB, 0xCD, 0xEF]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      expect(install.kind, InstallKind.pubGlobal);
      expect(install.executable, exe.path);
    });

    test('a native Mach-O binary under pub-cache is a BINARY install', () {
      final exe = fakeExe(const [0xCF, 0xFA, 0xED, 0xFE]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      // The pub activate path cannot rebuild over a native binary — the
      // release-download swap must be used instead.
      expect(install.kind, InstallKind.binary);
      expect(install.executable, exe.path);
    });

    test('a native ELF binary under pub-cache is a BINARY install', () {
      final exe = fakeExe(const [0x7F, 0x45, 0x4C, 0x46]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      expect(install.kind, InstallKind.binary);
    });

    test('a native PE binary under pub-cache is a BINARY install', () {
      final exe = fakeExe(const [0x4D, 0x5A, 0x90, 0x00]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      expect(install.kind, InstallKind.binary);
    });
  });
}
