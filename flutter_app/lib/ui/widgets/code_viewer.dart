import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

import 'package:fa/ui/widgets/syntax_theme.dart';

/// Singleton highlighter registered with all built-in languages.
final Highlight _highlight = Highlight()
  ..registerLanguages(builtinAllLanguages);

/// Maps a filename's extension to a re_highlight language id.
String detectLanguage(String filename) {
  final ext = filename.contains('.')
      ? '.${filename.split('.').last.toLowerCase()}'
      : '';
  return switch (ext) {
    '.dart' => 'dart',
    '.py' => 'python',
    '.js' => 'javascript',
    '.ts' => 'typescript',
    '.jsx' => 'javascript',
    '.tsx' => 'typescript',
    '.json' => 'json',
    '.yaml' || '.yml' => 'yaml',
    '.xml' => 'xml',
    '.html' || '.htm' => 'xml',
    '.css' => 'css',
    '.md' || '.markdown' => 'markdown',
    '.sh' || '.bash' => 'bash',
    '.go' => 'go',
    '.rs' => 'rust',
    '.java' => 'java',
    '.kt' => 'kotlin',
    '.swift' => 'swift',
    '.c' || '.h' => 'c',
    '.cpp' || '.hpp' => 'cpp',
    '.sql' => 'sql',
    '.toml' => 'ini',
    '.ini' || '.cfg' => 'ini',
    '.php' => 'php',
    '.rb' => 'ruby',
    '.scala' => 'scala',
    '.lua' => 'lua',
    '.gradle' => 'groovy',
    '.dockerfile' => 'dockerfile',
    _ => 'plaintext',
  };
}

/// Read-only syntax-highlighted code view with line numbers.
class CodeViewer extends StatelessWidget {
  const CodeViewer({
    super.key,
    required this.content,
    required this.language,
    this.baseStyle,
  });

  /// The code text to display.
  final String content;

  /// re_highlight language id (see [detectLanguage]).
  final String language;

  /// Base text style; defaults to JetBrainsMono 12px / height 1.5.
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style =
        baseStyle ??
        const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.5);

    // Build highlighted spans — fall back to plaintext on any error.
    TextSpan highlightedSpan;
    try {
      final result = _highlight.highlight(code: content, language: language);
      final renderer = TextSpanRenderer(style, syntaxTheme());
      result.render(renderer);
      highlightedSpan = renderer.span ?? TextSpan(text: content, style: style);
    } catch (_) {
      highlightedSpan = TextSpan(text: content, style: style);
    }

    final lines = content.split('\n');
    final lineCount = lines.length;
    final lineNumberStyle = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: style.fontSize ?? 12,
      height: style.height ?? 1.5,
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Scrollbar(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Line-number gutter.
              SizedBox(
                width: 44,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 1; i <= lineCount; i++)
                        Text('$i', style: lineNumberStyle), // l10n:ignore
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Code.
              Expanded(child: SelectableText.rich(highlightedSpan)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Editable code view with a Save button that writes through [env].
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.content,
    required this.path,
    required this.env,
    this.onSaved,
  });

  /// Initial file content.
  final String content;

  /// Path of the file in [env]'s namespace.
  final String path;

  /// Environment used to write the file.
  final ExecutionEnv env;

  /// Called after a successful save.
  final VoidCallback? onSaved;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.content,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.env.writeFile(widget.path, _controller.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
    });
    if (result.isOk) {
      widget.onSaved?.call();
      if (mounted) {
        // l10n:ignore
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            // l10n:ignore
            content: Text('Saved'), // l10n:ignore
            duration: Duration(seconds: 1),
          ),
        );
      }
    } else {
      setState(() {
        _error = result.errorOrNull?.message ?? 'Save failed';
      });
      if (mounted) {
        // l10n:ignore
        ScaffoldMessenger.of(context).showSnackBar(
          // l10n:ignore
          SnackBar(content: Text('Save failed: $_error')), // l10n:ignore
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.path.split('/').last,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontFamily: 'JetBrainsMono',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_saving)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.save),
                tooltip: 'Save', // l10n:ignore
                onPressed: _saving ? null : _save,
              ),
            ],
          ),
        ),
        Expanded(
          child: TextField(
            controller: _controller,
            expands: true,
            maxLines: null,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(8),
            ),
          ),
        ),
      ],
    );
  }
}
