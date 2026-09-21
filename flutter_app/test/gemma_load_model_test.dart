// Copyright (c) 2026, The Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/flutter_gemma.dart' show InferenceModel;

import 'package:fa/gemma/gemma_service_plugin.dart';
import 'package:fa/gemma/gemma_types.dart';

/// A [GemmaModelPreset] stand-in — the flow only reads [GemmaModelPreset.id].
const _preset = GemmaModelPreset(
  id: 'gemma-4-e2b',
  displayName: 'Gemma 4 E2B',
  url: 'https://huggingface.co/google/gemma-4-e2b/resolve/main/model.litertlm',
  filename: 'model.litertlm',
  sizeLabel: '~2.4 GB',
);

const _otherPreset = GemmaModelPreset(
  id: 'gemma-4-e4b',
  displayName: 'Gemma 4 E4B',
  url: 'https://huggingface.co/google/gemma-4-e4b/resolve/main/model.litertlm',
  filename: 'model-e4b.litertlm',
  sizeLabel: '~5 GB',
);

/// Minimal [InferenceModel] fake: the flow only closes the previous model
/// and hands the activated one back.
final class _FakeModel implements InferenceModel {
  _FakeModel(this.name);

  final String name;
  var closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records every step [GemmaService.runModelLoad] takes, in order.
final class _LoadFlowLog {
  final events = <String>[];

  Future<void> Function(GemmaModelPreset preset)? reinstallResult;
  InferenceModel? activateResult;
  Object? activateError;

  Future<InferenceModel?> run({
    required bool isWeb,
    required String? loadedPresetId,
    required InferenceModel? loadedModel,
  }) {
    return GemmaService.runModelLoad(
      preset: _preset,
      isWeb: isWeb,
      loadedPresetId: loadedPresetId,
      loadedModel: loadedModel,
      webReinstall: (preset) async {
        events.add('reinstall:${preset.id}');
        final result = reinstallResult;
        if (result != null) return result(preset);
      },
      clearLoadedState: () => events.add('clear'),
      closeLoadedModel: () async => events.add('close'),
      activate: (preset) async {
        events.add('activate:${preset.id}');
        final error = activateError;
        if (error != null) throw error;
        return activateResult ?? _FakeModel('activated');
      },
      emit: (event) => events.add('emit:${event.text}'),
    );
  }
}

void main() {
  group('GemmaService.runModelLoad (issue #702)', () {
    test(
      'the same live preset is a no-op: null, no reinstall, no close',
      () async {
        final log = _LoadFlowLog();
        final live = _FakeModel('live');

        final result = await log.run(
          isWeb: false,
          loadedPresetId: _preset.id,
          loadedModel: live,
        );

        expect(result, isNull);
        expect(log.events, isEmpty);
        expect(live.closeCalls, 0);
      },
    );

    test(
      'a matching id with a dead model reloads (id alone is not enough)',
      () async {
        final log = _LoadFlowLog();

        final result = await log.run(
          isWeb: false,
          loadedPresetId: _preset.id,
          loadedModel: null,
        );

        expect(result, isA<InferenceModel>());
        // No web reinstall off-web and no close without a previous model,
        // but the state clear, progress pulse and activation still happen.
        expect(log.events, [
          'clear',
          'emit:Loading model into memory…',
          'activate:${_preset.id}',
        ]);
      },
    );

    test(
      'web re-registers the install before touching the live engine',
      () async {
        final log = _LoadFlowLog();
        final previous = _FakeModel('previous');

        final result = await log.run(
          isWeb: true,
          loadedPresetId: _otherPreset.id,
          loadedModel: previous,
        );

        expect(result, isNot(same(previous)));
        expect(log.events, [
          // The idempotent install re-marks the model active first — the OPFS
          // registration must exist before getActiveModel runs.
          'reinstall:${_preset.id}',
          'clear',
          'close',
          'emit:Loading model into memory…',
          'activate:${_preset.id}',
        ]);
      },
    );

    test('off-web never reinstalls (the registry survives natively)', () async {
      final log = _LoadFlowLog();
      final previous = _FakeModel('previous');

      await log.run(
        isWeb: false,
        loadedPresetId: _otherPreset.id,
        loadedModel: previous,
      );

      expect(log.events.first, 'clear');
      expect(log.events, isNot(contains(startsWith('reinstall:'))));
    });

    test(
      'a switching load clears state before closing the old engine',
      () async {
        final log = _LoadFlowLog();

        await log.run(
          isWeb: false,
          loadedPresetId: _otherPreset.id,
          loadedModel: _FakeModel('previous'),
        );

        expect(
          log.events.indexOf('clear'),
          lessThan(log.events.indexOf('close')),
        );
      },
    );

    test('the activated model is returned for the caller to commit', () async {
      final log = _LoadFlowLog();
      final activated = _FakeModel('activated');
      log.activateResult = activated;

      final result = await log.run(
        isWeb: false,
        loadedPresetId: null,
        loadedModel: null,
      );

      expect(result, same(activated));
    });

    test(
      'an activation failure leaves the service with no stale model',
      () async {
        final cleared = <String>[];

        await expectLater(
          GemmaService.runModelLoad(
            preset: _preset,
            isWeb: false,
            loadedPresetId: _otherPreset.id,
            loadedModel: _FakeModel('previous'),
            webReinstall: (_) async {},
            clearLoadedState: () => cleared.add('clear'),
            closeLoadedModel: () async {},
            activate: (_) async => throw StateError('boom'),
            emit: (_) {},
          ),
          throwsStateError,
        );
        // The clear ran before the activation threw, so a failed load can
        // not leave a closed model installed as the live one.
        expect(cleared, ['clear']);
      },
    );
  });
}
