import 'package:fa/apps/fa_media_host.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// A [JsMediaHost] whose controllers render marker text — proves the
/// renderer's video/audio nodes go through the host (the contract the
/// video-player widget relies on) without touching native plugins.
final class _FakeMediaHost extends JsMediaHost {
  const _FakeMediaHost();

  @override
  JsVideoController createVideoController(String src) =>
      _FakeVideoController(src);

  @override
  JsAudioController createAudioController(String src) =>
      _FakeAudioController(src);
}

final class _FakeVideoController extends JsVideoController {
  _FakeVideoController(this.src);
  final String src;

  @override
  double? get aspectRatio => 16 / 9;
  @override
  Stream<double?> get aspectRatioStream => Stream.value(16 / 9);
  @override
  Widget buildVideo(
    BuildContext context, {
    BoxFit fit = BoxFit.contain,
    double? width,
    double? height,
  }) => Text('VIDEO:$src');

  @override
  Future<void> dispose() async {}
  @override
  Stream<Duration> get positionStream => Stream.value(Duration.zero);
  @override
  Stream<Duration> get durationStream =>
      Stream.value(const Duration(seconds: 10));
  @override
  Stream<bool> get playingStream => Stream.value(false);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
}

final class _FakeAudioController extends JsAudioController {
  _FakeAudioController(this.src);
  final String src;

  @override
  Future<void> dispose() async {}
  @override
  Stream<Duration> get positionStream => Stream.value(Duration.zero);
  @override
  Stream<Duration> get durationStream =>
      Stream.value(const Duration(seconds: 10));
  @override
  Stream<bool> get playingStream => Stream.value(false);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
}

void main() {
  test('FaMediaHost implements the runtime media host contract', () {
    expect(const FaMediaHost(), isA<JsMediaHost>());
  });

  test('JsAppView accepts a mediaHost override (defaults to FaMediaHost)', () {
    final env = MemoryExecutionEnv();
    final view = JsAppView(
      app: JsAppInfo.fromManifest(
        const {'id': 'x', 'name': 'x'},
        bundled: false,
        fallbackId: 'x',
      ),
      env: env,
      permissionsStore: AppPermissionsStore(env, const {}),
      mediaHost: const _FakeMediaHost(),
    );
    expect(view.mediaHost, isA<JsMediaHost>());
  });

  testWidgets('a video node renders through the injected media host', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final renderer = JsonWidgetRenderer(
                theme: JsonWidgetTheme.fromAccent(
                  Theme.of(context).colorScheme.primary,
                ),
                mediaHost: const _FakeMediaHost(),
                onEvent: (_, _) {},
              );
              return renderer.build(const {
                'type': 'video',
                'src': 'https://example.com/clip.mp4',
              }, context);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('VIDEO:https://example.com/clip.mp4'), findsOneWidget);
  });

  testWidgets('a video node without a host falls back to the placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final renderer = JsonWidgetRenderer(
                theme: JsonWidgetTheme.fromAccent(
                  Theme.of(context).colorScheme.primary,
                ),
                onEvent: (_, _) {},
              );
              return renderer.build(const {
                'type': 'video',
                'src': 'https://example.com/clip.mp4',
              }, context);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('VIDEO:https://example.com/clip.mp4'), findsNothing);
    expect(find.byIcon(Icons.videocam), findsOneWidget);
  });
}
