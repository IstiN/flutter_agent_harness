import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('web/session_store.js').readAsStringSync();

  test('cloud-session IndexedDB helper has valid syntax', () {
    final result = Process.runSync('node', ['--check', 'web/session_store.js']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('session outbox has an isolated namespaced DB and CAS transaction', () {
    expect(source, contains("window.__fahFsDatabaseName() + ':sessions'"));
    expect(source, contains("db.transaction('snapshots', 'readwrite')"));
    expect(source, contains('current !== expectedRevision'));
    expect(source, contains('CloudSessionStoreConcurrency'));
    expect(source, isNot(contains('accessToken')));
    expect(source, isNot(contains('refreshToken')));
  });

  test('session helper loads after the shared namespace helper', () {
    final html = File('web/index.html').readAsStringSync();
    expect(
      html.indexOf('src="fs_store.js"'),
      lessThan(html.indexOf('src="session_store.js"')),
    );
    expect(
      File(
        'lib/services/cloud/idb_cloud_session_sync_store.dart',
      ).readAsStringSync(),
      contains('expectedStorageRevision'),
    );
  });
}
