// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The brand-mark guard (issue #2391 addendum): the stock `FaMark` logo is
/// only legal inside `product_brand.dart` (the stock branch of
/// [ProductBrandMark]). Every other surface renders `ProductBrandMark` —
/// the host asset, the monogram fallback, and for stock Fa exactly
/// `FaMark` — so a branded build can never show the stock logo, and a
/// stray direct `FaMark(` fails CI instead of shipping it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The only files allowed to carry `FaMark(`: `product_brand.dart` (the
/// stock branch of [ProductBrandMark]) and `fa_mark.dart` (the widget's
/// own declaration).
const _allowlist = <String>{
  'lib/ui/widgets/product_brand.dart',
  'lib/ui/widgets/fa_mark.dart',
};

void main() {
  test('no direct FaMark( outside product_brand.dart (gh-2391 addendum)', () {
    final libRoot = Directory('lib');
    expect(libRoot.existsSync(), isTrue, reason: 'run from flutter_app/');
    final offenders = <String>[];
    final entities = libRoot.listSync(recursive: true).whereType<File>();
    for (final file in entities) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      if (_allowlist.contains(path)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('FaMark(')) {
          offenders.add('$path:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Direct FaMark( usages found outside product_brand.dart — '
          'branded surfaces must render ProductBrandMark (the host asset, '
          'monogram fallback, or the stock FaMark branch). Wrap the site '
          'with ProductConfigScope.of(context) and ProductBrandMark, or '
          'extend the guard deliberately with an explicit stock check:\n'
          '${offenders.join('\n')}',
    );
  });
}
