/// Identity file permissions: the 0600 chmod is best-effort (dart:io has
/// no portable chmod), so a platform where the mode cannot be set must
/// surface a visible warning instead of silently persisting the Ed25519/
/// X25519 private seeds with default ACLs.
library;

import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

void main() {
  test('permission warning is emitted when mode 0600 cannot be set', () async {
    final dir = await Directory.systemTemp.createTemp('fah-id-warn-');
    addTearDown(() => dir.delete(recursive: true));
    final keyPath = '${dir.path}/warned.key';
    final warnings = <String>[];

    final identity = await HubIdentity.load(
      keyPath,
      setPrivateMode: (_) async => false, // Windows-stub: no portable chmod.
      warn: warnings.add,
    );

    expect(warnings, hasLength(1));
    expect(warnings.single, contains('0600'));
    expect(warnings.single, contains(keyPath));
    // The identity itself is still usable.
    expect(await HubIdentity.load(keyPath, warn: warnings.add), isNotNull);
    expect(identity.agentId, hasLength(16));
  });

  test('no warning when mode 0600 is set successfully', () async {
    final dir = await Directory.systemTemp.createTemp('fah-id-ok-');
    addTearDown(() => dir.delete(recursive: true));
    final warnings = <String>[];

    await HubIdentity.load(
      '${dir.path}/quiet.key',
      setPrivateMode: (_) async => true,
      warn: warnings.add,
    );

    expect(warnings, isEmpty);
  });

  test('default runner really locks the file to 0600 on POSIX', () async {
    if (Platform.isWindows) return; // best-effort warning path there.
    final dir = await Directory.systemTemp.createTemp('fah-id-real-');
    addTearDown(() => dir.delete(recursive: true));
    final keyPath = '${dir.path}/real.key';
    final warnings = <String>[];

    await HubIdentity.load(keyPath, warn: warnings.add);

    expect(warnings, isEmpty);
    expect((await File(keyPath).stat()).modeString(), 'rw-------');
  });
}
