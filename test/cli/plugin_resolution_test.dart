// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:test/test.dart';

import '../../bin/fah.dart';

void main() {
  group('resolveEnabledPlugins', () {
    test('defaults to hub with no args and no config', () {
      expect(resolveEnabledPlugins(const [], const {}), {'hub'});
    });

    test('argument plugins join the default-on hub', () {
      expect(resolveEnabledPlugins(const ['inspect_image'], const {}), {
        'hub',
        'inspect_image',
      });
    });

    test('a packages.yaml falsy value opts the plugin OUT', () {
      expect(resolveEnabledPlugins(const [], {'hub': false}), isEmpty);
    });

    test('a packages.yaml null value (empty `hub:`) opts the plugin OUT', () {
      expect(resolveEnabledPlugins(const [], {'hub': null}), isEmpty);
    });

    test('a packages.yaml truthy value keeps the plugin on', () {
      expect(
        resolveEnabledPlugins(const [], {
          'hub': {'url': 'ws://example:8080'},
        }),
        {'hub'},
      );
    });

    test('config can enable a plugin that ships default-off', () {
      expect(resolveEnabledPlugins(const [], {'inspect_image': true}), {
        'hub',
        'inspect_image',
      });
    });
  });
}
