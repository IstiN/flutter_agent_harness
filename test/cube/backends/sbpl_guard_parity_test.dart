/// Issue #709 IT1: the macOS SBPL profile and the Dart fs guard must agree
/// for every mount access level — the guard (subject: file tools) and the
/// kernel profile (subject: wrapped shells) are two enforcers of one policy,
/// and a divergence is exactly the #709 bug class: rw was Dart-readable but
/// kernel-unreadable under a read-denied prefix.
///
/// The parity check replays the profile text with the observed SBPL
/// semantics (P1: the LAST matching rule per operation class wins, with
/// `(allow default)` as the floor) and compares that verdict against
/// `CubeFsPolicy.accessFor` for the same probe path.
library;

import 'package:flutter_agent_harness/src/cube/backends/macos_sandbox.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:test/test.dart';

/// The kernel's verdict for one operation class at [probe]: `true` when the
/// last matching `file-read*`/`file-write*` rule (or `(allow default)`)
/// allows the operation. Bare `(allow|deny file-*)` rules match every path.
bool _profileAllows(
  String profile, {
  required bool write,
  required String probe,
}) {
  // Two flat patterns, one per emitted shape — bare and subpath — from
  // buildSandboxProfile; the class capture picks the operation family.
  final bare = RegExp(r'^\((allow|deny) file-(read|write)\*\)$');
  final subbed = RegExp(
    r'^\((allow|deny) file-(read|write)\* \(subpath "(.+)"\)\)$',
  );
  var allows = true; // (allow default) is the profile floor.
  for (final raw in profile.split('\n')) {
    final line = raw.trim();
    final match = bare.firstMatch(line) ?? subbed.firstMatch(line);
    if (match == null) continue;
    if ((match.group(2) == 'write') != write) continue;
    final subpath = match.groupCount >= 3 ? match.group(3) : null;
    if (subpath != null &&
        subpath != '/' &&
        probe != subpath &&
        !probe.startsWith('$subpath/')) {
      continue;
    }
    allows = match.group(1) == 'allow';
  }
  return allows;
}

/// The Dart guard's verdict at [probe]: which of read/write the policy
/// grants (`ro` = read only, `rw` = both, `deny` = neither).
({bool read, bool write}) _guardAllows(CubeFsPolicy policy, String probe) {
  switch (policy.accessFor(probe)) {
    case CubePathAccess.readOnly:
      return (read: true, write: false);
    case CubePathAccess.readWrite:
      return (read: true, write: true);
    case CubePathAccess.deny:
      return (read: false, write: false);
  }
}

void main() {
  // The l1 shape: workspace under the read-denied /Users prefix, one mount
  // per access level beside it (also under /Users, so every mount tests the
  // re-allow-over-deny ordering, not just the rw one).
  const workspace = '/Users/agents/proj';
  final spec = CubeSpec(
    name: 'l1-dev',
    filesystem: const CubeFsPolicy(
      workspace: workspace,
      mounts: [
        CubeMount(
          path: '/Users/agents/ro-cache',
          access: CubePathAccess.readOnly,
        ),
        CubeMount(
          path: '/Users/agents/rw-cache',
          access: CubePathAccess.readWrite,
        ),
        CubeMount(path: '/Users/agents/vault', access: CubePathAccess.deny),
      ],
    ),
  );
  final profile = const MacOsSandboxBackend().buildSandboxProfile(
    spec,
    workspaceRoot: workspace,
  );

  final cases = <(String, String)>[
    ('ro mount', '/Users/agents/ro-cache/package/file.dart'),
    ('rw mount', '/Users/agents/rw-cache/hosted/pub.dev'),
    ('deny mount', '/Users/agents/vault/id_rsa'),
    ('workspace', '/Users/agents/proj/lib/main.dart'),
    ('unmapped path', '/Users/agents/elsewhere/notes.txt'),
    // E3 (P2): the literal /etc spelling of a read-denied firmware root
    // stays denied at paths the mount does not cover — only the
    // /private spelling bypasses the symlink node.
    ('unmapped firmware-literal path', '/etc/hosts'),
    ('firmware mount via /private spelling', '/private/etc/ssl/cert.pem'),
  ];

  for (final (label, probe) in cases) {
    test('guard and profile agree at a $label ($probe)', () {
      final guard = _guardAllows(spec.filesystem, probe);
      expect(
        _profileAllows(profile, write: false, probe: probe),
        guard.read,
        reason: 'read parity broke at $probe',
      );
      expect(
        _profileAllows(profile, write: true, probe: probe),
        guard.write,
        reason: 'write parity broke at $probe',
      );
    });
  }
}
