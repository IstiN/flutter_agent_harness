/// The `read` tool ([readFileTool]) and its text pipeline: trailing-selector mapping, offset/limit windows, head truncation with continuation notices, hashline numbering/snapshot recording, and multi-range rendering. Split out of `builtin_tools.dart` to keep that file under the repo line gate; same library (a `part of`), so the privates stay visible.
part of 'builtin_tools.dart';

// ---------------------------------------------------------------------------
// read (ported from pi's tools/read.ts, with image support; extended with
// oh-my-pi's trailing-selector grammar, archive inner paths, and SQLite
// targets — one path grammar keeps the tool count flat)
// ---------------------------------------------------------------------------

/// Default entry cap for archive directory listings (omp's
/// `#readArchiveDirectory` DEFAULT_LIMIT).
const defaultArchiveListLimit = 500;

/// Assembles the `read` tool description: the base prompt with its size
/// tokens substituted, plus the SQLite section ([readSqliteSectionPrompt])
/// only when the host provides a [sqlite] engine. The substituted value
/// carries the section's surrounding blank lines (`parseFrontmatter` trims
/// them from the section file), so gating it out leaves exactly one blank
/// line between the Archives and Hashline mode sections.
String _readDescription({SqliteEngine? sqlite}) {
  return readToolDescriptionPrompt
      .replaceAll('{{maxLines}}', '$defaultToolMaxLines')
      .replaceAll('{{maxBytesKb}}', '${defaultToolMaxBytes ~/ 1024}')
      .replaceAll(
        '{{sqlite}}',
        sqlite == null ? '' : '\n\n$readSqliteSectionPrompt',
      );
}

/// Creates the `read` tool: reads a text file or image with optional `offset`
/// (1-indexed) and `limit`, truncating text output to [defaultToolMaxLines]
/// lines or [defaultToolMaxBytes] bytes with an actionable continuation notice.
/// Images are decoded, optionally resized to the inline dimension/byte limits,
/// and returned as base64 content.
///
/// The path may carry a trailing selector (oh-my-pi's grammar, ported in
/// `read_selector.dart`): `:N` / `:A-B` / `:A+C` line ranges, comma-merged
/// multi-ranges (`:5-16,960-973`), and `:raw` verbatim output — alone or
/// combined with a range in either order (`:raw:50-100`). A single range maps
/// onto the offset/limit pipeline; multi-ranges render one block per range
/// joined by an elision separator, with out-of-bounds ranges reported as
/// skipped notices. `:raw` suppresses line numbers, the hashline header, and
/// all continuation notices. The `offset`/`limit` arguments keep working and
/// must not be combined with a selector.
///
/// Two extended targets consume their own colon syntax behind the same tool:
///
/// - Archive inner paths (`archive.zip:inner/entry`, also `.tar` and
///   `.tar.gz`/`.tgz`, via `archive_reader.dart`): the member's text runs
///   through the same pipeline (selectors apply after extraction); a bare
///   archive path or inner directory lists its contents, and binary entries
///   yield a note instead of bytes.
/// - SQLite databases (`data.db`, `data.db:table`, `data.db:table:key`,
///   `data.db:table?limit=…&offset=…&order=…&where=…`, `data.db?q=SELECT …`,
///   via `sqlite/sqlite_reader.dart`): rendered as width-capped ASCII
///   tables. Only available when the host provides a [SqliteEngine] (FFI,
///   exported from `lib/io.dart`); without one the read returns a clean
///   "not supported" note — what web hosts get. The tool description
///   mirrors that gating: without an engine the SQLite section is omitted.
///
/// With `hashline: true` (omp's hashline display mode), text output lines are
/// prefixed with their 1-indexed line number (`N:text`) and the output is
/// preceded by a `[path#TAG]` header carrying the whole-file content-hash
/// tag; the full file text plus the displayed line range are recorded in
/// [snapshots] so `edit` patches can anchor against them. Ranged reads keep
/// real file line numbers. Default is `false` (omp defaults it on; we keep
/// the legacy plain output as the default so existing read consumers are
/// unaffected — the `edit` tool description tells the model to opt in when
/// it intends to edit by anchors).
///
/// When [model] is provided, image results carry an extra note when the
/// current model has no `image` input (pi's `getNonVisionImageNote`); the
/// image itself stays in the result — providers substitute an explicit
/// placeholder at request time (see `downgradeUnsupportedImages`).
///
/// Built-in skill reads (issue #1151, extended by gh-1444): a `builtin://`
/// path resolves from the embedded copy before any filesystem access, and a
/// failed read of a path whose sibling `<path>.pointer` exists follows the
/// pointer — but only to a `builtin://skills/<name>/SKILL.md` target
/// matching the pointer's own directory ([followSkillPointer]); any other
/// pointer target is refused loudly. A builtin resource that resolves EMPTY
/// is retried once and then fails with an explicit error naming the
/// resource (gh-1444 AC2/E5) — never a silent empty success. [builtinText]
/// overrides the embedded-text lookup (the AC2 fault-injection seam for
/// tests); production callers omit it.
/// gh-1444 AC2: a builtin resource that resolves EMPTY is retried once,
/// then fails loudly naming the resource — an empty payload on a
/// non-empty resource is never a silent success. [builtinText] overrides
/// the embedded-text lookup (the AC2 fault-injection seam for tests);
/// production callers omit it.
String? _resolveBuiltinText(
  String path,
  String? Function(String path)? builtinText,
) {
  var embedded = (builtinText ?? builtinSkillTextAt)(path);
  if (embedded != null && embedded.isEmpty) {
    embedded = (builtinText ?? builtinSkillTextAt)(path);
    if (embedded == null || embedded.isEmpty) {
      throw StateError(
        'read $path: builtin resource resolved empty after retry — '
        'the compiled-in skill content is missing; report this as a '
        'harness defect',
      );
    }
  }
  return embedded;
}

AgentTool readFileTool(
  ExecutionEnv env, {
  HashlineSnapshotStore? snapshots,
  Model? Function()? model,
  SqliteEngine? sqlite,
  String? Function(String path)? builtinText,
  Future<InspectImageConfig?> Function()? vision,
  bool Function()? autoInspect,
  void Function(Usage usage)? onImageUsage,
  bool mediaFileReadNotes = false,
  bool Function()? transcribeAvailable,
}) {
  final store = snapshots ?? HashlineSnapshotStore();
  return AgentTool(
    name: 'read',
    label: 'read',
    tier: ApprovalTier.read,
    description: _readDescription(sqlite: sqlite),
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'Path to the file to read (relative or absolute). May end '
              'with a trailing selector such as :50-100 or :raw, address an '
              'archive member (archive.zip:inner/file), or address a SQLite '
              'database (data.db:table?limit=20)',
        },
        'offset': {
          'type': 'integer',
          'description': 'Line number to start reading from (1-indexed)',
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum number of lines to read',
        },
        'hashline': {
          'type': 'boolean',
          'description':
              'Prefix each line with its line number and prepend a '
              '[path#TAG] content-hash header for anchoring hashline edit '
              'patches (default: false)',
        },
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final rawPath = arguments['path'] as String;
      final offset = (arguments['offset'] as num?)?.toInt();
      final limit = (arguments['limit'] as num?)?.toInt();
      final hashlineMode = (arguments['hashline'] as bool?) ?? false;

      // Peel a trailing selector off the path (omp's grammar). A literal file
      // whose name ends in a selector-shaped tail (`test:1-2`) wins over the
      // selector interpretation.
      final split = await splitPathAndSelPreferringLiteral(rawPath, env);
      final parsed = parseSel(split.sel);
      // Issue #862: a selector already pins the window, so offset/limit are
      // ignored with a notice instead of hard-rejecting the call.
      final windowNotice = readWindowCoercionNotice(
        hasSelector: parsed is! ReadSelectorNone,
        offset: offset,
        limit: limit,
      );

      final extended = await _readExtendedTarget(
        env,
        rawPath,
        split,
        sqlite,
        cancelToken,
      );
      if (extended != null) return _withNotice(extended, windowNotice);

      final path = split.path;
      // Built-in skills (issue #1151): builtin:// paths resolve from the
      // embedded copy before any filesystem access.
      final embedded = _resolveBuiltinText(path, builtinText);
      if (embedded == null) {
        final binaryRead = await env.readBinaryFile(path);
        if (binaryRead.isErr) {
          // gh-1444 AC1: a skill pointer sibling (<path>.pointer) resolves
          // the read onto the compiled-in builtin body — the seeded
          // `.fah/skills/<name>/SKILL.md.pointer` files become transparent.
          // A present-but-invalid pointer is refused loudly (E1); no
          // pointer keeps the original error.
          final followed = await followSkillPointer(
            path,
            (pointerPath) async =>
                (await env.readTextFile(pointerPath)).valueOrNull,
          );
          switch (followed) {
            case SkillPointerResolved(:final text):
              return _withNotice(
                await _readTextContent(
                  env,
                  store,
                  path,
                  parsed,
                  offset,
                  limit,
                  text,
                  hashlineMode,
                  cancelToken,
                ),
                windowNotice,
              );
            case SkillPointerRefused(:final reason):
              throw StateError('read $path: skill pointer refused: $reason');
            case SkillPointerAbsent():
              throw StateError('${binaryRead.errorOrNull}');
          }
        } else {
          final bytes = binaryRead.valueOrNull!;
          cancelToken?.throwIfCancelled();

          final imageResult = await _readImageResult(
            path,
            bytes,
            parsed,
            model,
            vision: vision,
            autoInspect: autoInspect,
            onImageUsage: onImageUsage,
            cancelToken: cancelToken,
          );
          if (imageResult != null) {
            return _withNotice(imageResult, windowNotice);
          }
          // gh-1985 C1: a video extension routes the bytes natively — to a
          // video-capable chat model (VideoContent rides), else to the
          // configured media/vision slot with attribution; without either,
          // today's behavior (the AC10 note when the host opted in, else
          // the plain fall-through) keeps byte-identical.
          final videoResult = await _readVideoResult(
            path,
            bytes,
            parsed,
            model,
            vision: vision,
            autoInspect: autoInspect,
            onImageUsage: onImageUsage,
            cancelToken: cancelToken,
          );
          if (videoResult != null) {
            return _withNotice(videoResult, windowNotice);
          }
          // Audio/video files (gh-1984 AC10): an honest note naming the
          // tool/slot/host instead of a bare fall-through. The gate keeps
          // hosts without media wiring byte-identical to today.
          final mediaNote = mediaFileReadNotes
              ? _mediaFileNote(path, transcribeAvailable: transcribeAvailable)
              : null;
          if (mediaNote != null) {
            return _withNotice(
              ToolExecutionResult(content: [TextContent(text: mediaNote)]),
              windowNotice,
            );
          }
        }
      }

      return _withNotice(
        await _readTextContent(
          env,
          store,
          path,
          parsed,
          offset,
          limit,
          embedded,
          hashlineMode,
          cancelToken,
        ),
        windowNotice,
      );
    },
  );
}

/// Probes [rawPath] for the extended read targets (archive inner paths and
/// SQLite databases), which consume their own colon syntax. Returns null when
/// neither resolves — the caller falls through to a plain file read.
Future<ToolExecutionResult?> _readExtendedTarget(
  ExecutionEnv env,
  String rawPath,
  SplitReadPath split,
  SqliteEngine? sqlite,
  CancelToken? cancelToken,
) async {
  // Archive and SQLite targets consume their own colon syntax, so probe
  // them on the RAW path — unless it was kept literal because a real
  // file with a selector-shaped name exists (omp's rawPathIsLiteral).
  final rawPathIsLiteral =
      split.sel == null && splitPathAndSel(rawPath).sel != null;
  if (rawPathIsLiteral) return null;
  final archiveResult = await _tryReadArchive(env, rawPath, cancelToken);
  if (archiveResult != null) return archiveResult;
  final sqliteResult = await _tryReadSqlite(env, rawPath, sqlite);
  if (sqliteResult != null) cancelToken?.throwIfCancelled();
  return sqliteResult;
}

/// Renders an image read: decodes/resizes to the inline limits and builds
/// the note header. Returns null when [bytes] are not a supported image, so
/// the caller falls through to a text read.
///
/// gh-1984: with a non-vision chat model and a configured vision model
/// ([vision]) plus the auto-route enabled ([autoInspect], the
/// `images.autoInspect` knob), the read returns the vision model's
/// description inline with an attribution marker instead of the bare
/// omission note. Provider failures degrade to the omission note + reason —
/// never a failed read (AC6).
Future<ToolExecutionResult?> _readImageResult(
  String path,
  Uint8List bytes,
  ReadSelector parsed,
  Model? Function()? model, {
  Future<InspectImageConfig?> Function()? vision,
  bool Function()? autoInspect,
  void Function(Usage usage)? onImageUsage,
  CancelToken? cancelToken,
}) async {
  final format = _detectImageFormat(bytes);
  if (format == null || !_supportedImageFormats.contains(format)) return null;
  if (parsed is! ReadSelectorNone) {
    throw StateError(
      'Line selectors (:N, :A-B, :raw) apply to text files; '
      "'$path' is an image.",
    );
  }
  final processed = _processImage(bytes, format);
  final currentModel = model?.call();
  final chatModelSeesImages =
      currentModel == null || currentModel.input.contains('image');
  if (chatModelSeesImages) {
    return ToolExecutionResult(
      content: [
        TextContent(text: _imageNoteHeader(path, processed, model)),
        ImageContent(data: processed.base64, mimeType: processed.mimeType),
      ],
    );
  }

  // Non-vision chat model: resolve the vision capability and route
  // (auto-route, AC3 note, or AC4 note — see the helper).
  return _routeNonVisionImage(
    path,
    processed,
    vision: vision,
    autoInspect: autoInspect,
    onImageUsage: onImageUsage,
    cancelToken: cancelToken,
  );
}

/// The non-vision branch of [_readImageResult] (gh-1984): resolves the
/// live vision capability, then either auto-routes the description
/// (AC2), or builds the guidance note (AC3 autoInspect off / AC4 no
/// vision model). Split from the dispatcher so the gate's complexity
/// census stays per-stage (the CI CRAP ratchet measures per function).
/// [autoInspect] is a test seam (see [readFileTool]); production reads
/// the boot-published `imageRegistryConfig.autoInspect` global.
Future<ToolExecutionResult> _routeNonVisionImage(
  String path,
  _InlineImageResult processed, {
  Future<InspectImageConfig?> Function()? vision,
  bool Function()? autoInspect,
  void Function(Usage usage)? onImageUsage,
  CancelToken? cancelToken,
}) async {
  final visionConfig = await vision?.call();
  if (visionConfig == null ||
      !(autoInspect?.call() ?? imageRegistryConfig.autoInspect)) {
    return _omittedImageResult(
      path,
      processed,
      extra: _nonVisionGuidance(visionConfig),
    );
  }
  return _autoRouteVisionDescription(
    path,
    processed,
    visionConfig,
    onImageUsage: onImageUsage,
    cancelToken: cancelToken,
  );
}

/// The AC3/AC4 note: how the agent gets the image seen when the
/// auto-route is not taking it — name the tool + the configured model
/// (AC3), or the configure hint (AC4).
String _nonVisionGuidance(InspectImageConfig? visionConfig) {
  if (visionConfig != null) {
    return '\n[A vision model is configured (${visionConfig.modelId}): call '
        'inspect_image to describe this image.]';
  }
  return '\n[No vision model is configured — set one with /settings → Media '
      'models → vision (models.slots.vision) or --vision-model <id> to '
      'let the agent see images.]';
}

/// One vision-model call for the read (gh-1984 AC2): the budget gate, the
/// inline description with the attribution marker, and the AC6 degrades.
Future<ToolExecutionResult> _autoRouteVisionDescription(
  String path,
  _InlineImageResult processed,
  InspectImageConfig visionConfig, {
  void Function(Usage usage)? onImageUsage,
  CancelToken? cancelToken,
}) async {
  // The images.maxBytesPerRequest budget (issue #1916) applies to the
  // auto-route call too: base64 chars are wire bytes 1:1.
  final budget = imageRegistryConfig.maxBytesPerRequest;
  if (processed.base64.length > budget) {
    return _omittedImageResult(
      path,
      processed,
      extra:
          '\n[Vision inspection skipped: the image exceeds '
          'images.maxBytesPerRequest ($budget bytes).]',
    );
  }
  try {
    // The PROCESSED payload rides (gh-1984 review thread 1): the gate
    // measured `processed.base64`, the mime names the converted/kept
    // payload, and the request must carry exactly those bytes — a
    // resized/converted original (the common photo/screenshot case)
    // uploaded raw would bypass `images.maxBytesPerRequest` and ship
    // bytes disagreeing with the declared mime.
    final description = await describeImageWithVisionModel(
      visionConfig,
      base64Decode(processed.base64),
      processed.mimeType,
      '',
      cancelToken: cancelToken,
      onUsage: onImageUsage,
    );
    cancelToken?.throwIfCancelled();
    // The auto-route REPLACES the bare omission note (gh-1984 AC2): the
    // image bytes are not attached, the vision model's description rides
    // inline with the attribution marker.
    return ToolExecutionResult(
      content: [
        TextContent(
          text:
              '${_imageNoteHeader(path, processed, null)}\n'
              '[The image is not attached — the current model has no image '
              'input.]\n'
              '[via vision model ${visionConfig.modelId}]\n'
              '$description',
        ),
      ],
    );
  } on CancelledException {
    rethrow;
  } on Object catch (error) {
    // A cancel surfacing as a provider stream error must stay a cancel
    // (AC6), not a degrade note.
    cancelToken?.throwIfCancelled();
    // Degrade, never fail the read (AC6): the omission note names why.
    return _omittedImageResult(
      path,
      processed,
      extra:
          '\n[Vision inspection via vision model '
          '${visionConfig.modelId} failed: $error. The read continues '
          'without the image.]',
    );
  }
}

/// The non-vision degrade shape (gh-1984): note header + the pi omission
/// note + [extra] guidance, with the image bytes still attached (providers
/// substitute an explicit placeholder at request time — unchanged).
ToolExecutionResult _omittedImageResult(
  String path,
  _InlineImageResult processed, {
  required String extra,
}) {
  return ToolExecutionResult(
    content: [
      TextContent(
        text:
            '${_imageNoteHeader(path, processed, null)}'
            '${_nonVisionNoteSuffix()}$extra',
      ),
      ImageContent(data: processed.base64, mimeType: processed.mimeType),
    ],
  );
}

/// pi's `getNonVisionImageNote`, exactly as today.
String _nonVisionNoteSuffix() =>
    '\n[Current model does not support images. The image will be '
    'omitted from this request.]';

/// The audio/video read notes (gh-1984 AC10): a matching extension returns
/// an honest hint naming the tool, the slot to configure, or the host that
/// reads the media — instead of a bare fall-through. Null keeps today's
/// text-path behavior.
String? _mediaFileNote(
  String path, {
  required bool Function()? transcribeAvailable,
}) {
  final lower = path.toLowerCase();
  if (_audioExtensions.any(lower.endsWith)) {
    final dot = lower.lastIndexOf('.');
    final ext = dot < 0 ? '' : lower.substring(dot + 1);
    return transcribeAvailable?.call() ?? false
        ? '[Audio file: $path (.$ext) — text content is not shown. Call '
              'transcribe_audio to transcribe it.]'
        : '[Audio file: $path (.$ext) — text content is not shown. No '
              'transcription endpoint is configured: set '
              'models.slots.transcription (/settings → Media models → '
              'transcription) or pass --transcribe-model <id> to enable the '
              'transcribe_audio tool.]';
  }
  if (_videoExtensions.any(lower.endsWith)) {
    return '[Video file: $path — the current model has no video input and '
        'no video model is configured. Configure a video-capable model as '
        'the vision slot (models.slots.vision via /settings → Media models '
        '→ vision, or --vision-model <id>, e.g. a gemini or glm-5.3-flash '
        'model) and the read describes the video; a video-capable chat '
        'model receives the bytes directly.]';
  }
  return null;
}

/// Audio file extensions the AC10 note names.
const _audioExtensions = [
  '.mp3',
  '.wav',
  '.m4a',
  '.aac',
  '.flac',
  '.ogg',
  '.opus',
  '.wma',
  '.aiff',
  '.amr',
];

/// The video read route (gh-1985 C1/AC2): a matching video extension routes
/// the bytes to a video-capable target —
///
/// - a chat model whose `input` modalities contain `video` gets the bytes
///   attached ([VideoContent]); the ride is size-capped by
///   `images.maxBytesPerRequest` (AC7) — an oversized video is NOT attached
///   and the note names the size + the trim/convert hint, with no endless
///   retry;
/// - else the configured media/vision slot describes the video (AC2,
///   `[via video model <id>]` attribution), honoring the same
///   `autoInspect` knob and CancelToken as the image auto-route; provider
///   failures degrade to an honest note — the read never fails (AC6
///   semantics);
/// - with neither target present, returns null so the caller keeps today's
///   behavior (the AC10 note when the host opted in, else the plain
///   fall-through) — byte-identical (REG).
Future<ToolExecutionResult?> _readVideoResult(
  String path,
  Uint8List bytes,
  ReadSelector parsed,
  Model? Function()? model, {
  Future<InspectImageConfig?> Function()? vision,
  bool Function()? autoInspect,
  void Function(Usage usage)? onImageUsage,
  CancelToken? cancelToken,
}) async {
  if (!(_videoExtensions.any(path.toLowerCase().endsWith))) {
    return null;
  }
  if (parsed is! ReadSelectorNone) {
    // Line selectors apply to text files only — same refusal as images.
    throw StateError(
      'Line selectors (:N, :A-B, :raw) apply to text files; '
      "'$path' is a video.",
    );
  }
  final budget = imageRegistryConfig.maxBytesPerRequest;
  final payloadBase64 = base64Encode(bytes);
  final sizeLabel = formatToolSize(bytes.length);
  final currentModel = model?.call();
  if (currentModel != null && currentModel.input.contains('video')) {
    return _videoAttachResult(
      path,
      payloadBase64,
      sizeLabel,
      budget: budget,
    );
  }

  // Non-video-capable chat model: the configured media/vision slot
  // describes the video (AC2 attribution), same knobs as the image
  // auto-route.
  final visionConfig = await vision?.call();
  return _videoSlotResult(
    path,
    bytes,
    sizeLabel,
    visionConfig: visionConfig,
    autoInspect: autoInspect,
    budget: budget,
    cancelToken: cancelToken,
    onUsage: onImageUsage,
  );
}

/// The video-capable chat-model route: the bytes ride as [VideoContent],
/// size-capped by [budget] (AC7 — an oversized video is NOT attached and
/// the note names the size + the trim/convert hint).
ToolExecutionResult _videoAttachResult(
  String path,
  String payloadBase64,
  String sizeLabel, {
  required int budget,
}) {
  if (payloadBase64.length > budget) {
    return ToolExecutionResult.text(
      '[Video: $path, $sizeLabel — exceeds the video byte budget '
      '(images.maxBytesPerRequest = $budget bytes). The video is NOT '
      'attached. Trim/convert the clip (e.g. ffmpeg -i $path -ss 0 -t 30 '
      'small.mp4) and read the smaller file.]',
    );
  }
  return ToolExecutionResult(
    content: [
      TextContent(
        text:
            '[Video: $path, $sizeLabel — the video is attached for the '
            'current video-capable model.]',
      ),
      VideoContent(data: payloadBase64, mimeType: _videoMimeType(path)),
    ],
  );
}

/// The configured media/vision-slot route for a non-video-capable chat
/// model (AC2 attribution, same knobs as the image auto-route):
/// - no slot configured → null (the caller keeps today's behavior);
/// - a slot configured but the auto-route knob off → the honest note
///   naming the model (the gh-1984 AC3 note shape);
/// - otherwise ONE video inspection call, failures degrading to an honest
///   note — the read never fails (AC6 semantics); a cancel stays a cancel.
Future<ToolExecutionResult?> _videoSlotResult(
  String path,
  Uint8List bytes,
  String sizeLabel, {
  required InspectImageConfig? visionConfig,
  required bool Function()? autoInspect,
  required int budget,
  required CancelToken? cancelToken,
  required void Function(Usage usage)? onUsage,
}) async {
  if (visionConfig == null ||
      !(autoInspect?.call() ?? imageRegistryConfig.autoInspect)) {
    if (visionConfig == null) return null;
    // A video model IS configured but the auto-route knob is off (the
    // gh-1984 AC3 note shape): name the model instead of staying silent.
    return ToolExecutionResult.text(
      '[Video file: $path — a video model is configured '
      '(${visionConfig.modelId}) but the read auto-route is off '
      '(images.autoInspect: false). The video is not attached; switch to a '
      'video-capable chat model or enable the auto-route to have the read '
      'describe it.]',
    );
  }
  if (base64Length(bytes) > budget) {
    return ToolExecutionResult.text(
      '[Video: $path, $sizeLabel — exceeds the video byte budget '
      '(images.maxBytesPerRequest = $budget bytes); video inspection '
      'skipped. Trim/convert the clip and read the smaller file.]',
    );
  }
  try {
    final description = await describeVideoWithVisionModel(
      visionConfig,
      bytes,
      _videoMimeType(path),
      '',
      cancelToken: cancelToken,
      onUsage: onUsage,
    );
    cancelToken?.throwIfCancelled();
    return ToolExecutionResult(
      content: [
        TextContent(
          text:
              '[Video: $path, $sizeLabel]\n'
              '[The video is not attached — the current model has no video '
              'input.]\n'
              '[via video model ${visionConfig.modelId}]\n'
              '$description',
        ),
      ],
    );
  } on CancelledException {
    rethrow;
  } on Object catch (error) {
    // A cancel surfacing as a provider stream error must stay a cancel,
    // not a degrade note (gh-1984 AC6 semantics).
    cancelToken?.throwIfCancelled();
    return ToolExecutionResult.text(
      '[Video: $path, $sizeLabel]\n'
      '[Video inspection via video model ${visionConfig.modelId} failed: '
      '$error. The read continues without the video.]',
    );
  }
}

/// The video MIME type for a path. Every routed extension maps to the
/// MIME its container actually has — no catch-all mislabel (gh-2007
/// review thread 2): the google-shaped target documents the supported
/// video MIME types as video/mp4, video/mpeg, video/mpg, video/webm,
/// video/quicktime, video/wmv, video/x-flv, video/3gpp
/// (ai.google.dev/gemini-api/docs/video-understanding, mirrored by
/// firebase.google.com/docs/ai-logic/live-api/limits-and-specs);
/// x-matroska/x-msvideo ride the openai-completions `video_url`
/// passthrough verbatim. `.m4v` is mp4-family and rides the mp4 spelling.
String _videoMimeType(String path) {
  final lower = path.toLowerCase();
  return switch (lower.substring(lower.lastIndexOf('.') + 1)) {
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'avi' => 'video/x-msvideo',
    'mpeg' || 'mpg' => 'video/mpeg',
    'wmv' => 'video/wmv',
    'flv' => 'video/x-flv',
    '3gp' => 'video/3gpp',
    _ => 'video/mp4',
  };
}

/// Video file extensions the AC10 note names.
const _videoExtensions = [
  '.mp4',
  '.mov',
  '.mkv',
  '.webm',
  '.avi',
  '.m4v',
  '.mpg',
  '.mpeg',
  '.wmv',
  '.flv',
  '.3gp',
];

/// Builds the note header of an image read: the `[Image: …]` line plus the
/// conversion, resize-mapping, and non-vision hints (pi's `conversionHint`,
/// `formatDimensionNote`, and `getNonVisionImageNote`).
String _imageNoteHeader(
  String path,
  _InlineImageResult processed,
  Model? Function()? model,
) {
  final note = StringBuffer()
    ..write('[Image: $path, ${processed.width}x${processed.height}');
  if (processed.resized) {
    note.write(
      ', resized to ${processed.outputWidth}x${processed.outputHeight}',
    );
  }
  note.write(']');
  // pi's `conversionHint`.
  final convertedFrom = processed.convertedFrom;
  if (convertedFrom != null && convertedFrom != processed.mimeType) {
    note.write(
      '\n[Image converted from $convertedFrom to ${processed.mimeType}.]',
    );
  }
  // pi's `formatDimensionNote`: coordinate-mapping hint after resize.
  if (processed.resized) {
    final scale = processed.width / processed.outputWidth;
    note.write(
      '\n[Image: original ${processed.width}x${processed.height}, '
      'displayed at ${processed.outputWidth}x${processed.outputHeight}. '
      'Multiply coordinates by ${scale.toStringAsFixed(2)} to map to '
      'original image.]',
    );
  }
  // pi's `getNonVisionImageNote` — the final omission note rides the
  // resolver-driven suffixes below (gh-1984); the ride-in-place path keeps
  // today's shape byte-identically.
  final currentModel = model?.call();
  if (currentModel != null && !currentModel.input.contains('image')) {
    note.write(_nonVisionNoteSuffix());
  }
  return note.toString();
}

/// The text branch of the `read` tool: selector mapping, head truncation
/// with continuation notices, and hashline-mode numbering/recording.
Future<ToolExecutionResult> _readTextContent(
  ExecutionEnv env,
  HashlineSnapshotStore store,
  String path,
  ReadSelector parsed,
  int? offset,
  int? limit,
  String? embedded,
  bool hashlineMode,
  CancelToken? cancelToken,
) async {
  final read = embedded != null
      ? Ok<String, FileError>(embedded)
      : await env.readTextFile(path);
  if (read.isErr) throw StateError('${read.errorOrNull}');
  cancelToken?.throwIfCancelled();

  final rawContent = read.valueOrNull!;
  final allLines = rawContent.split('\n');
  final raw = isRawSelector(parsed);

  // Multi-range selector: one block per in-bounds range joined by an
  // elision separator; ranges past EOF surface as skipped notices (omp's
  // #buildInMemoryMultiRangeResult).
  if (parsed is ReadSelectorLines && parsed.ranges.length > 1) {
    return _readMultiRangeText(
      env,
      store,
      path,
      rawContent,
      allLines,
      parsed,
      raw,
      hashlineMode,
    );
  }

  // Whole-file/raw or a single range: map onto the offset/limit pipeline.
  // A selector range past EOF gets omp's graceful note instead of the
  // offset-argument error.
  final window = _singleRangeWindow(parsed, allLines.length, offset, limit);
  final beyondEofNote = window.beyondEofNote;
  if (beyondEofNote != null) {
    return ToolExecutionResult.text(beyondEofNote);
  }

  final formatted = _selectAndTruncate(
    allLines: allLines,
    entityLabel: 'file',
    offset: window.offset,
    limit: window.limit,
    raw: raw,
    numbered: hashlineMode && !raw,
    path: path,
  );
  final outputText = await _withHashlineHeader(
    env,
    store,
    path,
    rawContent,
    formatted,
    raw,
    hashlineMode,
  );
  return ToolExecutionResult.text(outputText);
}

/// The multi-range branch of [_readTextContent] (omp's
/// `#buildInMemoryMultiRangeResult`): one block per in-bounds range joined
/// by an elision separator, with the hashline header prepended in hashline
/// mode.
Future<ToolExecutionResult> _readMultiRangeText(
  ExecutionEnv env,
  HashlineSnapshotStore store,
  String path,
  String rawContent,
  List<String> allLines,
  ReadSelectorLines parsed,
  bool raw,
  bool hashlineMode,
) async {
  final multi = _formatMultiRange(
    allLines: allLines,
    ranges: parsed.ranges,
    raw: raw,
    hashlineMode: hashlineMode,
    entityLabel: 'file',
  );
  var multiOutput = multi.text;
  if (hashlineMode && !raw) {
    final tag = await _recordHashlineSnapshot(
      env,
      store,
      path,
      rawContent,
      multi.seenLines,
    );
    multiOutput = '${formatHashlineHeader(path, tag)}\n$multiOutput';
  }
  return ToolExecutionResult.text(multiOutput);
}

/// Maps a single-range selector onto the offset/limit pair for the shared
/// pipeline; a range past EOF yields omp's graceful note instead. A
/// non-range selector (whole-file or raw) keeps the caller's [offset] and
/// [limit] arguments.
({int? offset, int? limit, String? beyondEofNote}) _singleRangeWindow(
  ReadSelector parsed,
  int totalFileLines,
  int? offset,
  int? limit,
) {
  if (parsed is! ReadSelectorLines) {
    return (offset: offset, limit: limit, beyondEofNote: null);
  }
  final range = parsed.ranges.first;
  if (range.startLine > totalFileLines) {
    return (
      offset: null,
      limit: null,
      beyondEofNote:
          'Line ${range.startLine} is beyond end of file '
          '($totalFileLines lines total). Use :1 to read from the start, '
          'or :$totalFileLines to read the last line.',
    );
  }
  return (
    offset: range.startLine,
    limit: range.endLine == null ? null : range.endLine! - range.startLine + 1,
    beyondEofNote: null,
  );
}

/// Prepends the `[path#TAG]` hashline header to the formatted output in
/// hashline mode, recording the full normalized file text plus the displayed
/// line window in [store]; otherwise returns the text unchanged.
Future<String> _withHashlineHeader(
  ExecutionEnv env,
  HashlineSnapshotStore store,
  String path,
  String rawContent,
  _SelectedText formatted,
  bool raw,
  bool hashlineMode,
) async {
  if (!hashlineMode || raw) return formatted.text;
  // Record the FULL normalized file text (the tag is a whole-file
  // content hash) plus the 1-indexed lines actually displayed, so a
  // later edit patch validates the tag and the seen-line guard knows
  // which lines the model was shown.
  final lastDisplayed =
      formatted.startLineDisplay + formatted.displayedLines - 1;
  final seenLines = [
    for (var line = formatted.startLineDisplay; line <= lastDisplayed; line++)
      line,
  ];
  final tag = await _recordHashlineSnapshot(
    env,
    store,
    path,
    rawContent,
    seenLines,
  );
  return '${formatHashlineHeader(path, tag)}\n${formatted.text}';
}

/// Records [rawContent] (normalized to LF, BOM stripped) under the canonical
/// absolute [path] in [store] and returns the minted whole-file tag.
Future<String> _recordHashlineSnapshot(
  ExecutionEnv env,
  HashlineSnapshotStore store,
  String path,
  String rawContent,
  List<int> seenLines,
) async {
  final normalized = normalizeToLF(stripBom(rawContent).text);
  final canonical = (await env.absolutePath(path)).valueOrNull ?? path;
  return store.record(canonical, normalized, seenLines);
}

/// The result of [_selectAndTruncate]: the rendered text plus the window of
/// lines actually displayed (for hashline seen-line recording).
final class _SelectedText {
  const _SelectedText({
    required this.text,
    required this.startLineDisplay,
    required this.displayedLines,
  });

  /// The rendered output (including any continuation notices).
  final String text;

  /// 1-indexed number of the first displayed line.
  final int startLineDisplay;

  /// Number of whole lines that survived truncation.
  final int displayedLines;
}

/// Selects [offset]/[limit] lines out of [allLines] and renders them with
/// the shared head truncation and continuation notices (pi's
/// `truncateHead`). This is the single-range/whole-file pipeline shared by
/// local reads and archive member reads:
///
/// - [raw] (omp's `:raw`) suppresses line numbers and every notice, and
///   answers a first-line-over-byte-limit with a byte snippet instead of the
///   `sed` hint (omp's in-memory `truncateHeadBytes` path).
/// - [numbered] prefixes each line with its real 1-indexed number (hashline
///   display mode).
/// - [path] enables the `sed` continuation hint for local files; pass null
///   for archive members (a snippet is shown instead, like omp).
_SelectedText _selectAndTruncate({
  required List<String> allLines,
  required String entityLabel,
  int? offset,
  int? limit,
  bool raw = false,
  bool numbered = false,
  String? path,
}) {
  final startLine = offset != null && offset > 1 ? offset - 1 : 0;
  final startLineDisplay = startLine + 1;
  final (:selectedContent, :userLimitedLines) = _selectLineWindow(
    allLines,
    entityLabel,
    offset,
    startLine,
    limit,
  );

  final displayContent = numbered
      ? formatNumberedLines(selectedContent, startLineDisplay)
      : selectedContent;
  final truncation = _truncateHead(displayContent);
  final outputText = _selectedOutputText(
    allLines: allLines,
    entityLabel: entityLabel,
    startLine: startLine,
    startLineDisplay: startLineDisplay,
    userLimitedLines: userLimitedLines,
    raw: raw,
    path: path,
    truncation: truncation,
  );
  return _SelectedText(
    text: outputText,
    startLineDisplay: startLineDisplay,
    displayedLines: truncation.outputLines,
  );
}

/// Selects the [offset]/[limit] line window out of [allLines] (pi's
/// offset/limit mapping): throws when [offset] is past EOF, and reports how
/// many lines the caller's limit actually selected (for the "N more lines"
/// notice).
({String selectedContent, int? userLimitedLines}) _selectLineWindow(
  List<String> allLines,
  String entityLabel,
  int? offset,
  int startLine,
  int? limit,
) {
  if (startLine >= allLines.length) {
    throw StateError(
      'Offset $offset is beyond end of $entityLabel '
      '(${allLines.length} lines total)',
    );
  }
  if (limit != null) {
    final endLine = (startLine + limit) < allLines.length
        ? startLine + limit
        : allLines.length;
    return (
      selectedContent: allLines.sublist(startLine, endLine).join('\n'),
      userLimitedLines: endLine - startLine,
    );
  }
  return (
    selectedContent: allLines.sublist(startLine).join('\n'),
    userLimitedLines: null,
  );
}

/// Renders the truncated selection with the continuation notices (pi's
/// `truncateHead` notices): the first-line-over-bytes answer, the
/// "showing lines A-B of N" notice, or the "N more lines" notice when a
/// caller limit left lines behind.
String _selectedOutputText({
  required List<String> allLines,
  required String entityLabel,
  required int startLine,
  required int startLineDisplay,
  required int? userLimitedLines,
  required bool raw,
  required String? path,
  required _Truncation truncation,
}) {
  if (truncation.firstLineExceedsLimit) {
    return _firstLineExceedsOutput(
      allLines[startLine],
      startLineDisplay,
      raw,
      path,
    );
  }
  if (truncation.truncated) {
    return _truncatedNoticeOutput(
      startLineDisplay,
      allLines.length,
      truncation,
      raw,
    );
  }
  if (!raw &&
      userLimitedLines != null &&
      startLine + userLimitedLines < allLines.length) {
    final remaining = allLines.length - (startLine + userLimitedLines);
    final nextOffset = startLine + userLimitedLines + 1;
    return '${truncation.content}\n\n[$remaining more lines in $entityLabel. '
        'Use offset=$nextOffset to continue.]';
  }
  return truncation.content;
}

/// The truncated branch of [_selectedOutputText]: the surviving head plus
/// the "showing lines A-B of N" continuation notice (suppressed in raw
/// mode), which names the byte limit when that was what stopped the head.
String _truncatedNoticeOutput(
  int startLineDisplay,
  int totalFileLines,
  _Truncation truncation,
  bool raw,
) {
  final endLineDisplay = startLineDisplay + truncation.outputLines - 1;
  final nextOffset = endLineDisplay + 1;
  var outputText = truncation.content;
  if (!raw) {
    if (truncation.truncatedBy == _TruncatedBy.lines) {
      outputText +=
          '\n\n[Showing lines $startLineDisplay-$endLineDisplay of '
          '$totalFileLines. Use offset=$nextOffset to continue.]';
    } else {
      outputText +=
          '\n\n[Showing lines $startLineDisplay-$endLineDisplay of '
          '$totalFileLines (${formatToolSize(defaultToolMaxBytes)} limit). '
          'Use offset=$nextOffset to continue.]';
    }
  }
  return outputText;
}

/// Renders the answer for a first line that alone exceeds the byte limit:
/// a raw read or an archive member (no local path) shows a byte prefix
/// snippet (omp's in-memory `truncateHeadBytes` path), a numbered local read
/// points at `sed` for the oversized line.
String _firstLineExceedsOutput(
  String line,
  int startLineDisplay,
  bool raw,
  String? path,
) {
  if (raw || path == null) {
    return _bytePrefixSnippet(line, defaultToolMaxBytes);
  }
  return '[Line $startLineDisplay is '
      '${formatToolSize(_byteLength(line))}, exceeds '
      '${formatToolSize(defaultToolMaxBytes)} limit. Use bash: '
      "sed -n '${startLineDisplay}p' $path | "
      'head -c $defaultToolMaxBytes]';
}

/// Returns the longest leading substring of [line] whose UTF-8 encoding fits
/// within [maxBytes] (omp's `truncateHeadBytes`), shown when a raw or
/// archive read hits a first line that alone exceeds the byte limit.
String _bytePrefixSnippet(String line, int maxBytes) {
  final bytes = utf8.encode(line);
  if (bytes.length <= maxBytes) return line;
  // Walk back to a UTF-8 boundary (continuation bytes match 10xxxxxx).
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}

/// Renders a multi-range selector against in-memory text (omp's
/// `#buildInMemoryMultiRangeResult`): each in-bounds range emits one block
/// (numbered in hashline mode), blocks join with an elision separator, and
/// ranges past EOF surface as `[… skipped]` notices so the model can correct
/// the next call. No leading/trailing context is added — multi-range callers
/// always specify exact bounds.
({String text, List<int> seenLines}) _formatMultiRange({
  required List<String> allLines,
  required List<LineRange> ranges,
  required bool raw,
  required bool hashlineMode,
  required String entityLabel,
}) {
  final (
    :notices,
    :blocks,
    :blockStarts,
    :blockLengths,
  ) = _collectMultiRangeBlocks(
    allLines: allLines,
    ranges: ranges,
    raw: raw,
    hashlineMode: hashlineMode,
    entityLabel: entityLabel,
  );

  var output = blocks.join('\n\n…\n\n');
  final truncation = _truncateHead(output);
  output = truncation.content;

  final seenLines = hashlineMode && !raw
      ? _multiRangeSeenLines(
          blocks: blocks,
          blockStarts: blockStarts,
          blockLengths: blockLengths,
          outputLines: truncation.outputLines,
        )
      : const <int>[];

  if (truncation.truncated) {
    final note =
        '[Output truncated: showing ${truncation.outputLines} of '
        '${truncation.totalLines} selected lines. Use narrower ranges to '
        'continue.]';
    output = output.isEmpty ? note : '$output\n\n$note';
  }
  if (notices.isNotEmpty) {
    output = output.isEmpty
        ? notices.join('\n')
        : '$output\n${notices.join('\n')}';
  }
  return (text: output, seenLines: seenLines);
}

/// Per-range blocks for [_formatMultiRange]: each in-bounds range emits one
/// block (numbered in hashline mode), and ranges past EOF surface as
/// `[… skipped]` notices. No leading/trailing context is added —
/// multi-range callers always specify exact bounds.
({
  List<String> notices,
  List<String> blocks,
  List<int> blockStarts,
  List<int> blockLengths,
})
_collectMultiRangeBlocks({
  required List<String> allLines,
  required List<LineRange> ranges,
  required bool raw,
  required bool hashlineMode,
  required String entityLabel,
}) {
  final totalLines = allLines.length;
  final notices = <String>[];
  final blocks = <String>[];
  final blockStarts = <int>[];
  final blockLengths = <int>[];
  for (final range in ranges) {
    if (range.startLine > totalLines) {
      final bound = range.endLine != null
          ? '${range.startLine}-${range.endLine}'
          : '${range.startLine}';
      notices.add(
        '[Range $bound is beyond end of $entityLabel '
        '($totalLines lines total); skipped]',
      );
      continue;
    }
    final end = range.endLine == null
        ? totalLines
        : (range.endLine! < totalLines ? range.endLine! : totalLines);
    final blockText = allLines.sublist(range.startLine - 1, end).join('\n');
    blocks.add(
      hashlineMode && !raw
          ? formatNumberedLines(blockText, range.startLine)
          : blockText,
    );
    blockStarts.add(range.startLine);
    blockLengths.add(end - range.startLine + 1);
  }
  return (
    notices: notices,
    blocks: blocks,
    blockStarts: blockStarts,
    blockLengths: blockLengths,
  );
}

/// Seen lines for the hashline store: walks the blocks against the surviving
/// whole-line budget (the blank/…/blank separator lines consume budget but
/// map to no file lines).
List<int> _multiRangeSeenLines({
  required List<String> blocks,
  required List<int> blockStarts,
  required List<int> blockLengths,
  required int outputLines,
}) {
  final seenLines = <int>[];
  var budget = outputLines;
  for (var i = 0; i < blocks.length && budget > 0; i++) {
    final kept = blockLengths[i] < budget ? blockLengths[i] : budget;
    for (var line = blockStarts[i]; line < blockStarts[i] + kept; line++) {
      seenLines.add(line);
    }
    budget -= kept;
    if (budget > 0 && i + 1 < blocks.length) budget -= 3;
  }
  return seenLines;
}

/// Converts a single-range selector to the offset/limit pair used by archive
/// directory listings (omp's `selToOffsetLimit`): returns the FIRST range
/// only — multi-range callers must branch before calling this.
({int? offset, int? limit}) _selToOffsetLimit(ReadSelector sel) {
  if (sel is ReadSelectorLines) {
    final first = sel.ranges.first;
    return (
      offset: first.startLine,
      limit: first.endLine == null
          ? null
          : first.endLine! - first.startLine + 1,
    );
  }
  return (offset: null, limit: null);
}
