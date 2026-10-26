// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:test/test.dart';

import '../../bin/fah_dap_scoped.dart';

void main() {
  // The macOS Keychain backend must degrade to "no stored passphrase"
  // when the `security` CLI is unavailable (every non-macOS host,
  // including Linux CI) instead of crashing the passphrase resolution.
  test('MacOsDapChannelKeychain.read returns null when the security CLI '
      'is unavailable', () async {
    const keychain = MacOsDapChannelKeychain();
    expect(await keychain.read('fa.dap.channel-key.none.missing'), isNull);
  });
}
