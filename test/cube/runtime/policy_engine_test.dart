import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
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

    test('a redirect 2>&1 does not become a command', () {
      final decision = CubePolicyEngine(
        spec(),
      ).checkCommand('git status > /tmp/out.txt 2>&1');
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

    test('a bare-host operand is checked like a URL', () {
      final decision = CubePolicyEngine(
        spec(allow: {'git', 'curl'}),
      ).checkCommand('curl example.com/x');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains("network access to 'example.com:80'"));
    });

    test('a bare-host operand to an allowed host is permitted', () {
      final decision = CubePolicyEngine(
        spec(
          allow: {'git', 'curl', 'wget'},
          networkAllow: [CubeNetworkRule(host: 'api.github.com')],
        ),
      ).checkCommand('curl api.github.com/repos');
      expect(decision.allowed, isTrue);
    });

    test('a bare-host operand with a port is checked with that port', () {
      final decision = CubePolicyEngine(
        spec(allow: {'git', 'wget'}),
      ).checkCommand('wget example.com:8080/x');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains("network access to 'example.com:8080'"));
    });

    test('userinfo is stripped; the host behind the last @ is checked', () {
      final decision = CubePolicyEngine(
        spec(allow: {'git', 'curl'}),
      ).checkCommand('curl https://user:pass@evil.com/x');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains("network access to 'evil.com:443'"));
    });

    test('userinfo cannot smuggle an allowed host name', () {
      final decision = CubePolicyEngine(
        spec(
          allow: {'git', 'curl'},
          networkAllow: [CubeNetworkRule(host: 'api.github.com')],
        ),
      ).checkCommand('curl https://api.github.com@evil.com/');
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains("network access to 'evil.com:443'"));
    });

    test('userinfo with an explicit port keeps the port', () {
      final decision = CubePolicyEngine(
        spec(
          allow: {'git', 'curl'},
          networkAllow: [
            CubeNetworkRule(host: 'api.github.com', ports: {443}),
          ],
        ),
      ).checkCommand('curl https://user:pass@api.github.com:8443/x');
      expect(decision.allowed, isFalse);
      expect(
        decision.reason,
        contains("network access to 'api.github.com:8443'"),
      );
    });

    test('a flag value is not treated as a bare host', () {
      final decision = CubePolicyEngine(
        spec(
          allow: {'git', 'curl'},
          networkAllow: [CubeNetworkRule(host: 'api.github.com')],
        ),
      ).checkCommand('curl -H Host:x https://api.github.com/');
      expect(decision.allowed, isTrue);
    });

    test('local paths are not treated as bare hosts', () {
      // Deny-all network: any operand treated as a host would deny.
      final decision = CubePolicyEngine(
        spec(allow: {'git', 'curl'}),
      ).checkCommand('curl ./x /etc/hosts');
      expect(decision.allowed, isTrue);
    });
  });
}
