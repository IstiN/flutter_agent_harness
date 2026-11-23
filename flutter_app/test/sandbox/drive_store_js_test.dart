import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('web/drive_store.js').readAsStringSync();

  test('drive IndexedDB helper has valid JavaScript syntax', () {
    final result = Process.runSync('node', ['--check', 'web/drive_store.js']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('drive records use a separate product/account-namespaced database', () {
    expect(source, contains("window.__fahFsDatabaseName() + ':drive'"));
    expect(source, isNot(contains('__fahFsSet(')));
    expect(
      File('lib/services/cloud/idb_drive_sync_store.dart').readAsStringSync(),
      isNot(contains('MemoryDriveSyncStore')),
    );
  });

  test('CAS read+compare+put lives in one readwrite transaction', () {
    expect(source, contains("db.transaction('snapshots', 'readwrite')"));
    expect(source, contains('current !== expectedRevision'));
    expect(source, contains("name: 'DriveStoreConcurrency'"));
    expect(
      source.indexOf('store.get(scopeKey)'),
      lessThan(source.indexOf('store.put(record, scopeKey)')),
    );
  });

  test('bootstrap loads product namespace and helpers in dependency order', () {
    final html = File('web/index.html').readAsStringSync();
    final product = html.indexOf('src="product_config.js"');
    final fs = html.indexOf('src="fs_store.js"');
    final drive = html.indexOf('src="drive_store.js"');
    expect(product, greaterThanOrEqualTo(0));
    expect(fs, greaterThan(product));
    expect(drive, greaterThan(fs));
  });
}
