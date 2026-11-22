import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final fsStore = File('web/fs_store.js').readAsStringSync();
  final stockProduct = File('web/product_config.js').readAsStringSync();

  test('stock, missing-global and branded database names stay isolated', () {
    final script =
        '''
global.window = {};
$fsStore
console.log(window.__fahFsDatabaseName());
window.__faProductStorageNamespace = null;
console.log(window.__fahFsDatabaseName());
window.__faProductStorageNamespace = 'fa-product:host:schema:1';
console.log(window.__fahFsDatabaseName());
''';
    final result = Process.runSync('node', ['-e', script]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect((result.stdout as String).trim().split('\n'), [
      'fah_web_fs',
      'fah_web_fs',
      'fah_web_fs:fa-product:host:schema:1',
    ]);
  });

  test('stock product profile explicitly preserves legacy namespace', () {
    expect(stockProduct, contains('window.__faProductProfile = null;'));
    expect(
      stockProduct,
      contains('window.__faProductStorageNamespace = null;'),
    );
    expect(stockProduct, isNot(contains('fa-product:')));
  });

  test('product configuration loads before the persistence helper', () {
    final html = File('web/index.html').readAsStringSync();
    final product = html.indexOf('<script src="product_config.js"></script>');
    final store = html.indexOf('<script src="fs_store.js"></script>');
    expect(product, greaterThanOrEqualTo(0));
    expect(store, greaterThan(product));
  });

  test(
    'namespace switch closes the old handle and drops the cached promise',
    () {
      expect(fsStore, contains('window.__fahFsUseStorageNamespace'));
      expect(fsStore, contains('db.close();'));
      expect(fsStore, contains('window.__fahFsDbPromise = null;'));
    },
  );
}
