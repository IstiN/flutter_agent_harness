import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../bin/fah_dap_scoped.dart';

void main() {
  test('scoped identities are per project and stable across restarts', () {
    String pathFor(String cwd) => scopedIdentityKeyPath(
      defaultKeyPath: '/home/u/.dap/keys/fah/public-agent.key',
      explicitKeyPath: false,
      projectCwd: cwd,
    );
    final a = pathFor('/work/ai_conf');
    expect(a, pathFor('/work/ai_conf')); // restart keeps the agentId
    expect(a, isNot(pathFor('/work/fa_network'))); // no eviction wars
    expect(a, startsWith('/home/u/.dap/keys/fah/public-agent-'));
    expect(a, endsWith('.key'));
  });

  test('null and empty instances preserve the exact legacy project path', () {
    String legacyPathFor(String cwd) => scopedIdentityKeyPath(
      defaultKeyPath: '/home/u/.dap/keys/fah/public-agent.key',
      explicitKeyPath: false,
      projectCwd: cwd,
    );
    const cwd = '/work/ai_conf';
    final legacy = legacyPathFor(cwd);

    expect(
      scopedIdentityKeyPath(
        defaultKeyPath: '/home/u/.dap/keys/fah/public-agent.key',
        explicitKeyPath: false,
        projectCwd: cwd,
        instanceId: null,
      ),
      legacy,
    );
    expect(
      scopedIdentityKeyPath(
        defaultKeyPath: '/home/u/.dap/keys/fah/public-agent.key',
        explicitKeyPath: false,
        projectCwd: cwd,
        instanceId: '',
      ),
      legacy,
    );
  });

  test(
    'a nonempty instance is stable across projects and distinct by value',
    () {
      String pathFor(String cwd, String instanceId) => scopedIdentityKeyPath(
        defaultKeyPath: '/home/u/.dap/keys/fah/public-agent.key',
        explicitKeyPath: false,
        projectCwd: cwd,
        instanceId: instanceId,
      );
      const instance = '0123456789abcdef';
      final digest = sha256
          .convert(utf8.encode(instance))
          .toString()
          .substring(0, 10);

      final first = pathFor('/work/ai_conf', instance);
      expect(first, pathFor('/work/fa_network', instance));
      expect(first, '/home/u/.dap/keys/fah/public-agent-$digest.key');
      expect(first, isNot(pathFor('/work/ai_conf', 'fedcba9876543210')));
      expect(first, isNot(pathFor('/work/ai_conf', '')));
    },
  );

  test('an explicit keyPath is respected verbatim, even with an instance', () {
    expect(
      scopedIdentityKeyPath(
        defaultKeyPath: '/tmp/custom.key',
        explicitKeyPath: true,
        projectCwd: '/work/ai_conf',
        instanceId: '0123456789abcdef',
      ),
      '/tmp/custom.key',
    );
  });
}
