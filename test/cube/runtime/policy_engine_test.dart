import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/cube/runtime/policy_engine.dart';
import 'package:test/test.dart';

CubeSpec spec({
  Set<String> allow = const {'git', 'echo'},
  Set<String> deny = const {},
  List<CubeNetworkRule> networkAllow = const [],
}) => CubeSpec(
  name: 'test-cube',
  tools: CubeToolPolicy(allow: allow, deny: deny),
  network: CubeNetworkPolicy(allow: networkAllow),
);

void main() {
  group('CubePolicyEngine', () {
    test('allows a command in the allowlist', () {
      final decision = CubePolicyEngine(spec()).checkCommand('git status');
      expect(decision.allowed, isTrue);
      expect(decision.reason, isNull);
    });

    test('denies an unlisted command with the allowlist wording', () {
      final decision = CubePolicyEngine(spec()).checkCommand('rm -rf /');
      expect(decision.allowed, isFalse);
      expect(decision.reason, "command 'rm' not in cube 'test-cube' allowlist");
    });

    test('empty allow denies everything', () {
      final decision = CubePolicyEngine(spec(allow: {})).checkCommand('git');
      expect(decision.allowed, isFalse);
    });

    test('an empty command line is allowed', () {
      expect(CubePolicyEngine(spec()).checkCommand('').allowed, isTrue);
      expect(CubePolicyEngine(spec()).checkCommand('   ').allowed, isTrue);
    });

    test('deny wins over allow with the deny wording', () {
      final decision = CubePolicyEngine(
        spec(deny: {'git push'}),
      ).checkCommand('git push origin main');
      expect(decision.allowed, isFalse);
      expect(decision.reason, "command 'git' denied by cube 'test-cube'");
    });

    test('a deny entry on a subcommand does not block other commands', () {
      final decision = CubePolicyEngine(
        spec(deny: {'git push'}),
      ).checkCommand('git status');
      expect(decision.allowed, isTrue);
    });

    test('splits pipes and checks both sides', () {
      final engine = CubePolicyEngine(spec(allow: {'git', 'cat'}));
      expect(engine.checkCommand('cat f | grep x').allowed, isFalse);
      expect(engine.checkCommand('cat f | grep x').reason, contains("'grep'"));
      expect(
        CubePolicyEngine(
          spec(allow: {'git', 'cat', 'grep'}),
        ).checkCommand('cat f | grep x').allowed,
        isTrue,
      );
    });

    test('splits &&, ;, & and newlines', () {
      final engine = CubePolicyEngine(spec());
      expect(engine.checkCommand('git status && ssh evil').allowed, isFalse);
      expect(engine.checkCommand('git status; ssh evil').allowed, isFalse);
      expect(engine.checkCommand('git status & ssh evil').allowed, isFalse);
      expect(engine.checkCommand('git status\nssh evil').allowed, isFalse);
      expect(engine.checkCommand('git status && git log').allowed, isTrue);
    });

    test(r'catches a $(subshell) command', () {
      final decision = CubePolicyEngine(
        spec(),
      ).checkCommand(r'echo $(ssh evil)');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains("'ssh'"));
    });

    test('catches a backticked subshell command', () {
      final decision = CubePolicyEngine(spec()).checkCommand('echo `ssh evil`');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains("'ssh'"));
    });

    test('a quoted pipe is not a separator', () {
      expect(
        CubePolicyEngine(
          spec(),
        ).checkCommand(r'''git commit -m "a | b"''').allowed,
        isTrue,
      );
      expect(
        CubePolicyEngine(
          spec(),
        ).checkCommand(r"""git commit -m 'a | b'""").allowed,
        isTrue,
      );
    });

    test('strips leading VAR=value assignments', () {
      final decision = CubePolicyEngine(
        spec(
          allow: {'git', 'curl'},
          networkAllow: [CubeNetworkRule(host: '*')],
        ),
      ).checkCommand('FOO=1 BAR=2 git status');
      expect(decision.allowed, isTrue);
      expect(
        CubePolicyEngine(spec()).checkCommand('FOO=1 rm -rf /').allowed,
        isFalse,
      );
    });

    test('a redirect 2>&1 does not become a command or a file target', () {
      final decision = CubePolicyEngine(spec()).checkCommand('git status 2>&1');
      expect(decision.allowed, isTrue);
    });

    test('curl to an allowed host is permitted', () {
      final decision = CubePolicyEngine(
        spec(
          allow: {'git', 'curl'},
          networkAllow: [CubeNetworkRule(host: 'api.github.com')],
        ),
      ).checkCommand('curl https://api.github.com/repos');
      expect(decision.allowed, isTrue);
    });

    test('curl to a disallowed host is denied and names the host', () {
      final decision = CubePolicyEngine(
        spec(allow: {'git', 'curl'}),
      ).checkCommand('curl https://evil.com/x');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains("network access to 'evil.com:443'"));
    });

    test('a port outside the allowlist is denied', () {
      final decision = CubePolicyEngine(
        spec(
          allow: {'git', 'curl'},
          networkAllow: [
            CubeNetworkRule(host: 'api.github.com', ports: {443}),
          ],
        ),
      ).checkCommand('curl http://api.github.com:9999/x');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('api.github.com:9999'));
    });

    test('wget is network-checked like curl', () {
      final decision = CubePolicyEngine(
        spec(allow: {'git', 'wget'}),
      ).checkCommand('wget https://evil.com/x');
      expect(decision.allowed, isFalse);
    });

    test('non-fetching commands skip the network check', () {
      expect(CubePolicyEngine(spec()).checkCommand('git push').allowed, isTrue);
    });
  });
  group('redirect targets', () {
    CubeSpec fsSpec({List<CubeMount> mounts = const []}) => CubeSpec(
      name: 'l1-core',
      tools: const CubeToolPolicy(allow: {'echo', 'cat'}),
      filesystem: CubeFsPolicy(workspace: '/work', mounts: mounts),
    );

    CubePolicyEngine redirectEngine(CubeSpec spec) =>
        CubePolicyEngine(spec, homeDir: '/Users/agent', workspaceRoot: '/work');

    test('a redirect outside the workspace is denied', () {
      final decision = redirectEngine(
        fsSpec(),
      ).checkCommand('echo x > ../escape');
      expect(decision.allowed, isFalse);
      expect(decision.reason, "write to '../escape' denied by cube 'l1-core'");
    });

    test(r'2>&1 is an fd duplicate, not a file target, and passes', () {
      expect(
        redirectEngine(fsSpec()).checkCommand('echo x 2>&1').allowed,
        isTrue,
      );
    });

    test('every write-redirect form is path-checked', () {
      for (final redirect in ['>>', '<>', '&>', '2>', '2>>']) {
        final decision = redirectEngine(
          fsSpec(),
        ).checkCommand('echo x $redirect ../escape');
        expect(decision.allowed, isFalse, reason: '$redirect ../escape');
      }
    });

    test('an attached target is path-checked', () {
      expect(
        redirectEngine(fsSpec()).checkCommand('echo x >../escape').allowed,
        isFalse,
      );
    });

    test('a redirect inside the workspace is allowed', () {
      final engine = redirectEngine(fsSpec());
      expect(engine.checkCommand('echo x > out.txt').allowed, isTrue);
      expect(engine.checkCommand('echo x > sub/out.txt').allowed, isTrue);
    });

    test('/dev/null stays writable', () {
      expect(
        redirectEngine(fsSpec()).checkCommand('echo x 2> /dev/null').allowed,
        isTrue,
      );
    });

    test('an input redirect of a denied path is denied', () {
      final decision = redirectEngine(
        fsSpec(),
      ).checkCommand('cat < /etc/hosts');
      expect(decision.allowed, isFalse);
      expect(decision.reason, "read of '/etc/hosts' denied by cube 'l1-core'");
    });

    test('an input redirect inside the workspace is allowed', () {
      expect(
        redirectEngine(fsSpec()).checkCommand('cat < in.txt').allowed,
        isTrue,
      );
    });

    test('an rw mount allows redirect writes into it, others stay denied', () {
      final engine = redirectEngine(
        fsSpec(
          mounts: const [
            CubeMount(path: '/data', access: CubePathAccess.readWrite),
          ],
        ),
      );
      expect(engine.checkCommand('echo x > /data/out.txt').allowed, isTrue);
      expect(engine.checkCommand('echo x > /etc/out.txt').allowed, isFalse);
    });

    test('a rw root (L3 shape) allows redirects anywhere', () {
      final engine = redirectEngine(
        fsSpec(
          mounts: const [
            CubeMount(path: '/', access: CubePathAccess.readWrite),
          ],
        ),
      );
      expect(engine.checkCommand('echo x > /etc/out.txt').allowed, isTrue);
    });

    test('~ targets resolve through homeDir', () {
      final engine = redirectEngine(
        fsSpec(
          mounts: const [
            CubeMount(path: '/Users/agent', access: CubePathAccess.readWrite),
          ],
        ),
      );
      expect(engine.checkCommand('echo x > ~/notes.md').allowed, isTrue);
    });

    test('redirects in later segments are checked too', () {
      expect(
        redirectEngine(
          fsSpec(),
        ).checkCommand('git status && echo x > ../esc').allowed,
        isFalse,
      );
    });
  });
}
