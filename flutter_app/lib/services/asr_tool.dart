// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/asr_service.dart';

/// Name of the agent tool that records a take from the microphone.
const micRecordToolName = 'mic_record';

/// Name of the agent tool that transcribes an audio file — kept identical
/// to the harness's `transcribe_audio` tool, which [transcriptionTool]
/// replaces in the app (the model-facing surface does not change).
const transcribeAudioToolName = 'transcribe_audio';

/// Resolves the transcriber for one `transcribe_audio` call; `null` means
/// no ASR-capable endpoint is configured (see [asrNoEndpointMessage]).
typedef AsrTranscriberResolver = Future<AsrTranscriber?> Function();

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

/// Creates the `transcribe_audio` tool bound to [env], resolving the
/// transcription endpoint per call through [resolveTranscriber] (the
/// `media_models.json` `transcription` slot when configured, otherwise the
/// active provider — see [whisperTranscriberForGateway]).
///
/// Mirrors the harness's `transcribeAudioTool` (same name, parameters, and
/// file rules) but resolves the endpoint per call, so slot edits and
/// provider switches take effect without a reconnect; when no ASR-capable
/// endpoint resolves the tool answers with [asrNoEndpointMessage] instead
/// of being absent. Tier read, like the harness tool.
AgentTool transcriptionTool(
  ExecutionEnv env,
  AsrTranscriberResolver resolveTranscriber,
) {
  return AgentTool(
    name: transcribeAudioToolName,
    label: transcribeAudioToolName,
    tier: ApprovalTier.read,
    description:
        'Transcribe a local audio file to text using a Whisper-compatible '
        'transcription endpoint (the configured transcription slot, or the '
        'connected provider when it is OpenAI-compatible). Returns the '
        'transcript; the audio itself does not enter the chat context. '
        'Supported formats: WAV, MP3, M4A, OGG, WebM, FLAC. Maximum file '
        'size: 25MB.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the audio file (relative or absolute)',
        },
        'language': {
          'type': 'string',
          'description':
              'Optional ISO-639-1 language hint (e.g. "en", "de"); overrides '
              'the configured default',
        },
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = (arguments['path'] ?? '').toString();
      final language = arguments['language']?.toString();

      final filename = path.split(RegExp(r'[/\\]')).last;
      final dot = filename.lastIndexOf('.');
      final extension = dot >= 0
          ? filename.substring(dot + 1).toLowerCase()
          : '';
      if (!supportedAudioExtensions.contains(extension)) {
        throw StateError(
          'Unsupported audio format: $filename (supported: '
          '${(supportedAudioExtensions.toList()..sort()).join(', ')})',
        );
      }

      final read = await env.readBinaryFile(path);
      if (read.isErr) {
        throw StateError('${read.errorOrNull}');
      }
      final bytes = read.valueOrNull!;
      cancelToken?.throwIfCancelled();

      if (bytes.length > maxTranscribeAudioBytes) {
        throw StateError(
          'Audio file too large: ${bytes.length} bytes exceeds the 25MB '
          'transcription limit',
        );
      }

      final transcriber = await resolveTranscriber();
      if (transcriber == null) {
        return ToolExecutionResult.text(asrNoEndpointMessage);
      }
      final transcript = await transcriber.transcribe(
        bytes: bytes,
        filename: filename,
        language: language,
      );
      return ToolExecutionResult.text(transcript);
    },
  );
}
