import 'package:audioplayers/audioplayers.dart' show AudioPlayer;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// audioplayers' method channels (audioplayers_platform_interface 7.x):
/// one global, one shared per-player channel carrying the playerId, and
/// one event channel per player (`…/events/$playerId`).
const _playerChannel = MethodChannel('xyz.luan/audioplayers');
const _globalChannel = MethodChannel('xyz.luan/audioplayers.global');

const _kore = FaVoicePreset(
  id: 'Kore',
  trait: 'Firm',
  sampleUrl: 'https://example.invalid/samples/Kore.wav',
);

Widget _host({
  String? value = 'Kore',
  bool enabled = true,
  ValueChanged<String>? onChanged,
  List<FaVoicePreset> presets = const [_kore],
}) => MaterialApp(
  home: Scaffold(
    body: FaVoicePresetPicker(
      presets: presets,
      value: value,
      onChanged: onChanged ?? (_) {},
      enabled: enabled,
    ),
  ),
);

/// Installs mock handlers answering every audioplayers platform call; the
/// created player's id is captured so tests can emit platform events.
///
/// The handlers stay installed through teardown: the widget tree is
/// disposed after `addTearDown` callbacks run, and the picker's
/// `AudioPlayer.dispose()` would throw against a missing plugin there.
void _stubAudioplayers(WidgetTester tester, void Function(String) onCreated) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _globalChannel,
    (_) async => null,
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _playerChannel,
    (call) async {
      if (call.method == 'create') {
        onCreated((call.arguments as Map)['playerId'] as String);
      }
      return null;
    },
  );
}

/// Delivers a native audio event to the player's event channel.
void _emitAudioEvent(
  WidgetTester tester,
  String playerId,
  Map<String, Object?> event,
) {
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'xyz.luan/audioplayers/events/$playerId',
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) {},
  );
}

void main() {
  group('FaVoicePresetPicker', () {
    testWidgets('shows the preview button only when the preset has a sample', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.pumpWidget(
        _host(
          value: 'af_heart',
          presets: const [FaVoicePreset(id: 'af_heart')],
        ),
      );
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets(
      'preview play/stop cycles through loading, playing, and reset',
      (tester) async {
        // One test drives the whole preview cycle: audioplayers' global
        // scope caches its init completer per process, so a second
        // testWidgets creating an AudioPlayer would await a completer
        // completed in the previous test's (dead) fake-async zone.
        //
        // The backend never prepares on the first play: the preparation
        // timeout (30s real, 1ms here so fake time fires it) fails over
        // silently; later plays get an explicit `prepared` event, then a
        // `complete` event resets the button.
        AudioPlayer.preparationTimeout = const Duration(milliseconds: 1);
        addTearDown(
          () => AudioPlayer.preparationTimeout = const Duration(seconds: 30),
        );
        var playerId = '';
        _stubAudioplayers(tester, (id) => playerId = id);
        await tester.pumpWidget(_host());
        await tester.pump();

        // Play without a prepared event — fails over to idle.
        await tester.tap(find.byIcon(Icons.play_arrow));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.byIcon(Icons.play_arrow), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);

        // Play again — this time the platform prepares the clip.
        await tester.tap(find.byIcon(Icons.play_arrow));
        await tester.pump();
        _emitAudioEvent(tester, playerId, {
          'event': 'audio.onPrepared',
          'value': true,
        });
        await tester.pump();
        expect(find.byIcon(Icons.stop), findsOneWidget);
        expect(find.byIcon(Icons.play_arrow), findsNothing);

        await tester.tap(find.byIcon(Icons.stop));
        await tester.pump();
        expect(find.byIcon(Icons.play_arrow), findsOneWidget);
        expect(find.byIcon(Icons.stop), findsNothing);

        // A third play, reset by native playback completion.
        await tester.tap(find.byIcon(Icons.play_arrow));
        await tester.pump();
        _emitAudioEvent(tester, playerId, {
          'event': 'audio.onPrepared',
          'value': true,
        });
        await tester.pump();
        expect(find.byIcon(Icons.stop), findsOneWidget);

        _emitAudioEvent(tester, playerId, {'event': 'audio.onComplete'});
        await tester.pump();
        expect(find.byIcon(Icons.play_arrow), findsOneWidget);
        expect(find.byIcon(Icons.stop), findsNothing);
      },
    );

    testWidgets('a saved voice unknown to the presets stays selectable', (
      tester,
    ) async {
      await tester.pumpWidget(_host(value: 'my-custom-voice'));
      expect(find.text('my-custom-voice'), findsOneWidget);
      // Unknown voices publish no sample — no preview button.
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('a disabled picker renders the dropdown without a handler', (
      tester,
    ) async {
      await tester.pumpWidget(_host(enabled: false));
      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(dropdown.onChanged, isNull);
    });
  });

  group('faVoicePresetsFor', () {
    test('matches Gemini TTS by model id (gemini + tts)', () {
      final presets = faVoicePresetsFor(
        modelId: 'gemini-2.5-flash-preview-tts',
      );
      expect(presets, hasLength(30));
      expect(presets.first.id, 'Zephyr');
      expect(presets.first.trait, 'Bright');
      expect(
        presets.first.sampleUrl,
        'https://www.gstatic.com/aistudio/voices/samples/Zephyr.wav',
      );
      expect(presets.last.id, 'Sulafat');
      expect(presets.last.trait, 'Warm');
    });

    test('matches Gemini by base URL regardless of the model id', () {
      final presets = faVoicePresetsFor(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        modelId: 'some-model',
      );
      expect(presets, hasLength(30));
    });

    test('matches Kokoro by model id (no sample urls)', () {
      final presets = faVoicePresetsFor(modelId: 'kokoro-82m');
      expect(presets.map((preset) => preset.id), [
        'af_heart',
        'af_bella',
        'af_nicole',
        'af_sarah',
        'af_sky',
        'am_adam',
        'am_michael',
        'am_onyx',
        'bf_emma',
        'bf_isabella',
        'bm_george',
        'bm_lewis',
      ]);
      expect(presets.every((preset) => preset.sampleUrl == null), isTrue);
    });

    test('matches OpenAI-compatible TTS by the tts marker', () {
      final presets = faVoicePresetsFor(modelId: 'tts-1');
      expect(presets.map((preset) => preset.id), [
        'alloy',
        'ash',
        'coral',
        'echo',
        'fable',
        'nova',
        'onyx',
        'sage',
        'shimmer',
      ]);
      expect(presets.every((preset) => preset.sampleUrl == null), isTrue);
    });

    test('matching is case-insensitive', () {
      expect(faVoicePresetsFor(modelId: 'GPT-4o-mini-TTS'), isNotEmpty);
      expect(faVoicePresetsFor(modelId: 'KOKORO'), hasLength(12));
    });

    test('no match returns an empty list', () {
      expect(faVoicePresetsFor(modelId: 'gpt-4o'), isEmpty);
      expect(
        faVoicePresetsFor(
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'gpt-image-1',
        ),
        isEmpty,
      );
    });
  });
}
