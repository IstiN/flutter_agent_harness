@TestOn('vm')
library;

import 'dart:io';

import 'package:fa/services/session_listing.dart';
import 'package:fa/services/subagent_parent_resolver.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

/// P3 offline replica: runs the app's persisted-session listing pipeline
/// (per-root `JsonlSessionRepo.list` filename/header parsing →
/// `mergeSessionsAcrossRoots` → `SubagentParentResolver`) against COPIES
/// of a bounded sample of this machine's real session stores
/// (`~/Library/Group Containers/group.dev.fa1.shared/fa/sessions`,
/// `~/.fah/sessions`).
///
/// The real roots are only ever READ (never written); every pipeline run
/// happens on temp-dir copies. Skips silently when the machine has no
/// store (CI) — the assertion suite only runs against real samples.
void main() {
  test(
    'real-store sample replica lists sessions through the full pipeline',
    () async {
      final home = Platform.environment['HOME'] ?? '';
      final realRoots = <String>[
        '$home/Library/Group Containers/group.dev.fa1.shared/fa/sessions',
        '$home/.fah/sessions',
      ].where((root) => Directory(root).existsSync()).toList();
      if (realRoots.isEmpty) {
        return; // No store on this machine — nothing to replicate.
      }

      final tmp = await Directory.systemTemp.createTemp('fah_listing_replica');
      addTearDown(() => tmp.delete(recursive: true));

      // Copy a bounded sample per real root: the newest cwd folders, the
      // newest session files in each (the header-only read surface of a
      // listing), preserving the `<root>/<encoded-cwd>/<file>.jsonl`
      // layout the filename parsing consumes.
      const maxDirsPerRoot = 3;
      const maxFilesPerDir = 3;
      const maxCopyBytes = 2 << 20;
      final copiedRoots = <String>[];
      var copiedFiles = 0;
      for (var i = 0; i < realRoots.length; i++) {
        final realRoot = Directory(realRoots[i]);
        final copyRoot = '${tmp.path}/root$i';
        Directory(copyRoot).createSync(recursive: true);
        final cwdDirs =
            realRoot
                .listSync()
                .whereType<Directory>()
                .toList()
              ..sort(
                (a, b) => b.statSync().modified.compareTo(
                  a.statSync().modified,
                ),
              );
        var copiedInRoot = 0;
        for (final dir in cwdDirs.take(maxDirsPerRoot)) {
          final jsonls =
              dir
                  .listSync()
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.jsonl'))
                  .toList()
                ..sort(
                  (a, b) => b.statSync().modified.compareTo(
                    a.statSync().modified,
                  ),
                );
          for (final file in jsonls) {
            if (file.lengthSync() > maxCopyBytes) continue;
            final dest = '$copyRoot/${dir.uri.pathSegments.reversed.skip(1).first}'
                '/${file.uri.pathSegments.last}';
            Directory(dest).parent.createSync(recursive: true);
            file.copySync(dest);
            copiedFiles++;
            copiedInRoot++;
            if (copiedInRoot >= maxFilesPerDir * maxDirsPerRoot) break;
          }
          if (copiedInRoot >= maxFilesPerDir * maxDirsPerRoot) break;
        }
        if (copiedInRoot > 0) copiedRoots.add(copyRoot);
      }
      if (copiedRoots.isEmpty || copiedFiles == 0) {
        return; // Sampled nothing copyable — nothing to assert.
      }

      final env = LocalExecutionEnv(cwd: tmp.path);
      final perRoot = <String, List<SessionMetadata>>{};
      for (final root in copiedRoots) {
        // The exact failure P3 guards against: list() throwing on a
        // sample of real store files. A throw fails this test.
        final listed = await JsonlSessionRepo(
          fs: env,
          sessionsRoot: root,
        ).list();
        perRoot[root] = listed;
      }
      // Every depth-1 sample is a session file from the real store — the
      // parsed listing must be non-empty.
      expect(
        perRoot.values.fold<int>(0, (sum, list) => sum + list.length),
        copiedFiles,
      );

      final merged = await mergeSessionsAcrossRoots(
        roots: copiedRoots,
        listRoot: (root) async => perRoot[root]!,
      );
      expect(merged, isNotEmpty);

      // The parent resolver must complete on real-world subagent files
      // (legacy `parent: ""` headers included) without throwing.
      final relinked = await SubagentParentResolver(
        maxTailBytes: 1 << 20,
      ).resolve(merged);
      expect(relinked, isA<Map<String, String>>());
    },
  );
}
