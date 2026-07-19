/// Regenerates the committed Dart prompt constants from the Markdown prompt
/// files under `prompts/` (and the example app's `prompts/`).
///
/// Prompts live outside Dart code (see AGENTS.md). The Markdown files are the
/// source of truth; this script compiles them into pure-Dart constant files
/// that `lib/` (which must stay `dart:io`-free) can embed:
///
/// ```sh
/// dart run scripts/gen_prompts.dart          # rewrite the .g.dart files
/// dart run scripts/gen_prompts.dart --check  # fail if the .g.dart files are stale
/// ```
///
/// The sync test `test/prompts/prompts_sync_test.dart` reruns this generation
/// and fails on any drift.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show parseFrontmatter;

/// Output path (repo-root-relative) for the core package's prompt constants.
const rootOutputPath = 'lib/src/prompts/prompts.g.dart';

/// Output path (repo-root-relative) for the example app's prompt constants.
const exampleOutputPath = 'example/flutter_example/lib/prompts.g.dart';

/// Header emitted at the top of [rootOutputPath].
const rootHeader = '''
/// GENERATED — do not edit. Edit the Markdown sources under `prompts/` and
/// rerun `dart run scripts/gen_prompts.dart`.
///
/// Prompts live outside Dart code (see AGENTS.md); this file is the
/// compiled-in copy used by the pure-Dart `lib/`.
library;
''';

/// Header emitted at the top of [exampleOutputPath].
const exampleHeader = '''
/// GENERATED — do not edit. Edit the Markdown sources under
/// `example/flutter_example/prompts/` and rerun
/// `dart run scripts/gen_prompts.dart` from the repository root.
///
/// Prompts live outside Dart code (see the repository-root AGENTS.md).
library;
''';

/// A mapping from one Markdown prompt file to one generated Dart constant.
final class PromptSpec {
  /// Creates a prompt spec.
  const PromptSpec({
    required this.source,
    required this.constName,
    this.requiredToken,
  });

  /// Markdown source path, relative to the repository root.
  final String source;

  /// Name of the generated Dart constant.
  final String constName;

  /// A token the prompt body must contain (e.g. the `{{cwd}}` placeholder).
  final String? requiredToken;
}

/// The core package prompts, emitted into [rootOutputPath] in this order.
const rootSpecs = <PromptSpec>[
  PromptSpec(
    source: 'prompts/compaction/summary_system.md',
    constName: 'summarizationSystemPrompt',
  ),
  PromptSpec(
    source: 'prompts/compaction/summary.md',
    constName: 'summarizationPrompt',
  ),
  PromptSpec(
    source: 'prompts/compaction/summary_update.md',
    constName: 'updateSummarizationPrompt',
  ),
  PromptSpec(
    source: 'prompts/compaction/turn_prefix.md',
    constName: 'turnPrefixSummarizationPrompt',
  ),
  PromptSpec(
    source: 'prompts/cli/mode_code.md',
    constName: 'cliCodeModePrompt',
    requiredToken: '{{cwd}}',
  ),
  PromptSpec(
    source: 'prompts/cli/mode_architect.md',
    constName: 'cliArchitectModePrompt',
    requiredToken: '{{cwd}}',
  ),
  PromptSpec(
    source: 'prompts/cli/mode_review.md',
    constName: 'cliReviewModePrompt',
    requiredToken: '{{cwd}}',
  ),
  PromptSpec(
    source: 'prompts/tools/inspect_image.md',
    constName: 'inspectImageVisionSystemPrompt',
  ),
  PromptSpec(
    source: 'prompts/tools/tool_calling.md',
    constName: 'toolCallingInstructionsPrompt',
    requiredToken: '{{tools}}',
  ),
];

/// The example app prompts, emitted into [exampleOutputPath] in this order.
const exampleSpecs = <PromptSpec>[
  PromptSpec(
    source: 'example/flutter_example/prompts/sandbox_system.md',
    constName: 'sandboxSystemPrompt',
    requiredToken: '{{commands}}',
  ),
  PromptSpec(
    source: 'example/flutter_example/prompts/webllm_no_tools_note.md',
    constName: 'webLlmNoToolsNote',
  ),
  PromptSpec(
    source: 'example/flutter_example/prompts/transformers_js_no_tools_note.md',
    constName: 'transformersJsNoToolsNote',
  ),
];

/// A Markdown prompt file loaded and validated for generation.
final class LoadedPrompt {
  /// Creates a loaded prompt.
  const LoadedPrompt({
    required this.spec,
    required this.description,
    required this.body,
  });

  /// The spec this prompt was loaded for.
  final PromptSpec spec;

  /// The frontmatter `description` (used as the constant's doc comment).
  final String description;

  /// The prompt body after frontmatter removal — the constant's value.
  final String body;
}

/// Loads and validates the Markdown sources for [specs] under [repoRoot].
Future<List<LoadedPrompt>> loadPrompts(
  String repoRoot,
  List<PromptSpec> specs,
) async {
  final prompts = <LoadedPrompt>[];
  for (final spec in specs) {
    final file = File('$repoRoot/${spec.source}');
    if (!file.existsSync()) {
      throw StateError('prompt source not found: ${spec.source}');
    }
    final (:frontmatter, :body) = parseFrontmatter(await file.readAsString());
    final expectedName = spec.source
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.md$'), '');
    if (frontmatter['name'] != expectedName) {
      throw StateError(
        '${spec.source}: frontmatter name must be "$expectedName", '
        'got "${frontmatter['name']}"',
      );
    }
    final description = frontmatter['description'];
    if (description is! String || description.isEmpty) {
      throw StateError('${spec.source}: missing frontmatter description');
    }
    final requiredToken = spec.requiredToken;
    if (requiredToken != null && !body.contains(requiredToken)) {
      throw StateError(
        '${spec.source}: prompt body must contain "$requiredToken"',
      );
    }
    prompts.add(LoadedPrompt(spec: spec, description: description, body: body));
  }
  return prompts;
}

/// Renders [value] as a single-line Dart single-quoted string literal.
String dartStringLiteral(String value) {
  final buffer = StringBuffer("'");
  for (var i = 0; i < value.length; i++) {
    switch (value[i]) {
      case r'\':
        buffer.write(r'\\');
      case "'":
        buffer.write(r"\'");
      case r'$':
        buffer.write(r'\$');
      case '\n':
        buffer.write(r'\n');
      case '\r':
        buffer.write(r'\r');
      case '\t':
        buffer.write(r'\t');
      default:
        buffer.write(value[i]);
    }
  }
  buffer.write("'");
  return buffer.toString();
}

List<String> _wrapDoc(String text, [int width = 76]) {
  final lines = <String>[];
  var current = '';
  for (final word in text.split(' ')) {
    if (current.isEmpty) {
      current = word;
    } else if (current.length + 1 + word.length <= width) {
      current = '$current $word';
    } else {
      lines.add(current);
      current = word;
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}

String _renderConstant(LoadedPrompt prompt) {
  final buffer = StringBuffer();
  for (final line in _wrapDoc(prompt.description)) {
    buffer.writeln('/// $line');
  }
  buffer
    ..writeln('///')
    ..writeln('/// Source: `${prompt.spec.source}`.');
  final literal = dartStringLiteral(prompt.body);
  final oneLine = 'const ${prompt.spec.constName} = $literal;';
  if (oneLine.length <= 80) {
    buffer.writeln(oneLine);
  } else {
    buffer
      ..writeln('const ${prompt.spec.constName} =')
      ..writeln('    $literal;');
  }
  return buffer.toString();
}

/// Renders a complete `.g.dart` file: [header] followed by one constant per
/// prompt. The output is stable under `dart format`.
String renderPromptsFile(String header, List<LoadedPrompt> prompts) {
  final buffer = StringBuffer(header);
  for (final prompt in prompts) {
    buffer
      ..writeln()
      ..write(_renderConstant(prompt));
  }
  return buffer.toString();
}

/// The generation targets, in order: core package, then the example app.
const targets = <({List<PromptSpec> specs, String output, String header})>[
  (specs: rootSpecs, output: rootOutputPath, header: rootHeader),
  (specs: exampleSpecs, output: exampleOutputPath, header: exampleHeader),
];

/// Renders the file content for one [target] under [repoRoot].
Future<String> renderTarget(
  String repoRoot,
  ({List<PromptSpec> specs, String output, String header}) target,
) async {
  final prompts = await loadPrompts(repoRoot, target.specs);
  return renderPromptsFile(target.header, prompts);
}

Future<void> main(List<String> args) async {
  final checkOnly = args.contains('--check');
  final repoRoot = Directory.current.path;
  if (!File('$repoRoot/pubspec.yaml').existsSync()) {
    stderr.writeln('gen_prompts: run from the repository root');
    exit(64);
  }
  final stale = <String>[];
  for (final target in targets) {
    final content = await renderTarget(repoRoot, target);
    final file = File('$repoRoot/${target.output}');
    final current = file.existsSync() ? await file.readAsString() : null;
    if (current == content) {
      stdout.writeln('up to date: ${target.output}');
    } else if (checkOnly) {
      stale.add(target.output);
    } else {
      await file.create(recursive: true);
      await file.writeAsString(content);
      stdout.writeln('wrote: ${target.output}');
    }
  }
  if (stale.isNotEmpty) {
    stderr.writeln(
      'stale generated prompt files '
      '(run `dart run scripts/gen_prompts.dart`):',
    );
    for (final path in stale) {
      stderr.writeln('  $path');
    }
    exit(1);
  }
}
