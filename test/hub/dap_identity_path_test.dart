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

  test('an explicit keyPath is respected verbatim', () {
    expect(
      scopedIdentityKeyPath(
        defaultKeyPath: '/tmp/custom.key',
        explicitKeyPath: true,
        projectCwd: '/work/ai_conf',
      ),
      '/tmp/custom.key',
    );
  });
}
