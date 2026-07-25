// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/asr_service.dart';

/// Name of the agent tool that records a take from the microphone.
const micRecordToolName = 'mic_record';

/// Directory (relative to the env's working directory) recordings are
/// staged into so the agent can read/transcribe them with its file tools.
const micRecordingsDir = 'recordings';

/// The shared availability gate: `null` when the microphone may be used,
/// otherwise the user-facing explanation (unsupported platform, or access
/// denied with where to enable it). Requests OS access on the first call.
Future<String?> _unavailable(AsrApi asr) async {
  if (!await asr.isAvailable) {
    return 'Microphone recording is not supported on this platform.';
  }
  // The OS shows its access prompt at most once; later calls return the
  // stored decision without prompting again.
  if (!await asr.requestAccess()) {
    return 'Microphone access was denied. The user can enable it in System '
        'Settings → Privacy & Security → Microphone (macOS) or Settings → '
        'Privacy & Security → Microphone (iOS), then ask again.';
  }
  return null;
}

/// Creates the `mic_record` tool bound to [asr] and [env].
///
/// Starts a recording, waits `seconds` (1–[asrMaxRecordSeconds], default
/// 10), stops it, and stages the take into the sandbox [micRecordingsDir]
/// so the model can transcribe it with `transcribe_audio` (or read it with
/// its file tools). Tier write: recording from the user's microphone is a
/// privacy-sensitive action, so the approval gate applies. [wait] is
/// injectable for tests (the real default sleeps wall-clock seconds). The
/// description/result texts are LLM-facing and stay literal English.
AgentTool micRecordTool(
  AsrApi asr,
  ExecutionEnv env, {
  Future<void> Function(int seconds)? wait,
}) {
  final sleep =
      wait ?? (seconds) => Future<void>.delayed(Duration(seconds: seconds));
  return AgentTool(
    name: micRecordToolName,
    label: micRecordToolName,
    tier: ApprovalTier.write,
    description:
        "Record audio from the user's microphone. Starts recording, waits "
        '`seconds` (default 10, max $asrMaxRecordSeconds), stops, and saves '
        'the take as an .m4a file inside the sandbox. Returns the sandbox '
        'path and duration — transcribe it with transcribe_audio. Confirm '
        'with the user before recording.',
    parameters: const {
      'type': 'object',
      'properties': {
        'seconds': {
          'type': 'integer',
          'description':
              'How long to record, 1-$asrMaxRecordSeconds seconds '
              '(default: 10)',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(asr);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final seconds = asrRecordSeconds(arguments['seconds'] as num?);
      await asr.startRecording();
      await sleep(seconds);
      cancelToken?.throwIfCancelled();
      final recording = await asr.stopRecording();
      final bytes = await asr.readRecording(recording.path);

      // Stage the take into the sandbox so the agent's file tools (and
      // transcribe_audio) can reach it.
      final dirResult = await env.createDir(micRecordingsDir);
      if (dirResult.isErr) {
        throw StateError(
          'Could not create $micRecordingsDir: '
          '${dirResult.errorOrNull!.message}',
        );
      }
      final path =
          '$micRecordingsDir/mic-${DateTime.now().millisecondsSinceEpoch}.m4a';
      final writeResult = await env.writeBinaryFile(path, bytes);
      if (writeResult.isErr) {
        throw StateError(
          'Could not store the recording: '
          '${writeResult.errorOrNull!.message}',
        );
      }
      return ToolExecutionResult.text(
        'Recorded $seconds s of audio to $path '
        '(${bytes.length} bytes, ${recording.sampleRate} Hz). '
        'Transcribe it with transcribe_audio.',
      );
    },
  );
}
