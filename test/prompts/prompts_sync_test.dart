/// Guards the prompts-outside-Dart-code convention (see AGENTS.md): the
/// committed `.g.dart` prompt constants must always match a fresh generation
/// from the Markdown sources under `prompts/` (and the example app's
/// `prompts/`). Run `dart run scripts/gen_prompts.dart` to fix any drift.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show parseFrontmatter;
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart' as generated;
import 'package:test/test.dart';

import '../../scripts/gen_prompts.dart' as gen;

String _mdBody(String path) =>
    parseFrontmatter(File(path).readAsStringSync()).body;

void main() {
  group('generated files are in sync with the Markdown sources', () {
    for (final target in gen.targets) {
      test(target.output, () async {
        final rendered = await gen.renderTarget('.', target);
        final committed = File(target.output).readAsStringSync();
        expect(
          committed,
          rendered,
          reason:
              '${target.output} is stale — edit the Markdown sources and run '
              '`dart run scripts/gen_prompts.dart`, then commit the result.',
        );
      });
    }
  });

  group('constants equal the Markdown bodies', () {
    final cases = <String, String>{
      'prompts/compaction/summary_system.md':
          generated.summarizationSystemPrompt,
      'prompts/compaction/summary.md': generated.summarizationPrompt,
      'prompts/compaction/summary_update.md':
          generated.updateSummarizationPrompt,
      'prompts/compaction/turn_prefix.md':
          generated.turnPrefixSummarizationPrompt,
      'prompts/cli/mode_code.md': generated.cliCodeModePrompt,
      'prompts/cli/mode_architect.md': generated.cliArchitectModePrompt,
      'prompts/cli/mode_review.md': generated.cliReviewModePrompt,
      'prompts/tools/inspect_image.md':
          generated.inspectImageVisionSystemPrompt,
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(_mdBody(entry.key), entry.value);
      });
    }

    test('CLI mode templates keep the {{cwd}} placeholder', () {
      expect(generated.cliCodeModePrompt, contains('{{cwd}}'));
      expect(generated.cliArchitectModePrompt, contains('{{cwd}}'));
      expect(generated.cliReviewModePrompt, contains('{{cwd}}'));
    });

    test('example sandbox prompt body is embedded verbatim', () {
      // The example app is a separate package, so its constant cannot be
      // imported here; check the committed file embeds the Markdown body.
      final committed = File(gen.exampleOutputPath).readAsStringSync();
      final body = _mdBody('flutter_app/prompts/sandbox_system.md');
      expect(committed, contains(gen.dartStringLiteral(body)));
    });
  });
}
