/// Golden proof for the mobile Files defect: a chat whose recorded folder
/// is the sandbox folder under a PREVIOUS app-container prefix (an iOS
/// reinstall or backup restore re-seats the container UUID) used to gate
/// the whole Files panel — "This chat's folder is not accessible" — even
/// though the folder IS the sandbox filesystem the shell runs against.
/// And with the gate down, an unmounted mount-env host listed the virtual
/// `/project` segment and reported "Could not open folder" instead of the
/// sandbox root.
///
/// The harness composes the mobile stack of `createMobileSandboxEnv`
/// (env_factory_io.dart) without dart:io: a container-rooted delegate,
/// the project-mount host beside it (mobile keeps the mount out of the
/// fs snapshot), the `/project`-when-mounted cwd contract of
/// `_MobileExecutionEnv`, and the service's secrets wrapper. The session
/// folder rides the stale container path; iPhone-shaped metrics
/// (390x844, notch 59, home indicator 34) seed the view padding so the
/// snapshots prove the panel also clears the iOS safe areas.
library;

import 'dart:io';

import 'package:fa/services/project_mount_env.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/file_preview.dart';
import 'package:fa_ui/fa_ui.dart' show debugFaGlassAlwaysFake;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// The sandbox host directory the shell runs against THIS install.
const _liveSandbox =
    '/var/mobile/Containers/Data/Application/9F2E-live/Documents/fah_sandbox';

/// The same folder as recorded by a session restored from a backup taken
/// under the previous container — only the UUID prefix is stale.
const _staleSessionFolder =
    '/var/mobile/Containers/Data/Application/4A7D-old/Documents/fah_sandbox';

/// Loads the MaterialIcons font from the local Flutter SDK so icon glyphs
/// (folder/file/refresh/chevron icons) render instead of tofu boxes.
/// Same approach as `files_golden_test.dart`.
Future<void> _ensureMaterialIcons() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!file.existsSync()) return;
  final bytes = file.readAsBytesSync();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// The mobile composition of `createMobileSandboxEnv` without dart:io:
/// the persistent container delegate, the mount host beside it, and the
/// cwd contract of the private `_MobileExecutionEnv` (delegate container
/// root until a mount is granted, the virtual `/project` after).
final class _MobileSandboxEnv extends ForwardingFs implements ProjectMountHost {
  _MobileSandboxEnv(this.mountEnv, super.delegate);

  final ProjectMountEnv mountEnv;

  @override
  ProjectMountEnv get projectMount => mountEnv;

  @override
  bool get supportsNativeProjectMount => true;

  @override
  String get cwd => mountEnv.mountedRoot == null ? delegate.cwd : '/project';
}

/// The service-visible env stack: `AgentService.create` always wraps the
/// platform env in a secrets decorator; `FileBrowser` must see through it
/// exactly like production does.
ExecutionEnv _serviceEnv(MemoryExecutionEnv delegate) => SecretsExecutionEnv(
  _MobileSandboxEnv(ProjectMountEnv(delegate), delegate),
  const {},
);

/// A small sandbox tree: one plain text file to preview plus folders/files
/// the listing renders around it.
Future<MemoryExecutionEnv> _seededSandbox() async {
  final delegate = MemoryExecutionEnv(cwd: _liveSandbox);
  await delegate.writeFile('readme.txt', 'hello from the sandbox\n');
  await delegate.writeFile(
    'notes.md',
    '# Sandbox notes\n\n- tapped file must preview\n',
  );
  await delegate.createDir('generated');
  await delegate.writeFile('generated/out.txt', 'agent output\n');
  return delegate;
}

/// iPhone-safe host: the pushed Files surface renders edge to edge and
/// clears the seeded notch/home-indicator padding through SafeArea.
Widget _phoneHost(Widget child) => Scaffold(body: SafeArea(child: child));

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await _ensureMaterialIcons();
  });
  // The glass direction's LiquidGlass chips render through the
  // deterministic fake — same contract as the files/wide-shell goldens.
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  /// Pumps the Files panel over the mobile sandbox stack with the session
  /// folder recorded under the stale container prefix.
  Future<void> pumpSandboxFiles(WidgetTester tester) async {
    // iPhone-like metrics: notch top 59, home-indicator bottom 34.
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    final env = _serviceEnv(await _seededSandbox());
    await pumpGolden(
      tester,
      FileBrowser(
        env: env,
        sessionFolder: _staleSessionFolder,
        inlinePreview: true,
      ),
      size: goldenSizePhone,
      wrap: _phoneHost,
    );
  }

  testWidgets(
    'sandbox session folder lists (no access gate) and clears the iPhone '
    'safe areas',
    (tester) async {
      await pumpSandboxFiles(tester);
      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsNothing,
        reason:
            'the session folder IS the sandbox folder (stale container '
            'prefix only) — Files must list it, not gate it',
      );
      expect(find.text('readme.txt'), findsOneWidget);
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('Could not open folder'), findsNothing);
      await expectGolden(tester, 'files_sandbox_listing');
    },
  );

  testWidgets('tapping a sandbox file opens its text preview', (tester) async {
    await pumpSandboxFiles(tester);
    await tester.tap(find.text('readme.txt'));
    await tester.pumpAndSettle();
    expect(find.byType(FilePreviewView), findsOneWidget);
    expect(find.textContaining('hello from the sandbox'), findsOneWidget);
    expect(find.text('Could not open folder'), findsNothing);
    await expectGolden(tester, 'files_sandbox_preview');
  });
}
