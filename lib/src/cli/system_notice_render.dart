/// Renders `<system-notice>…</system-notice>` blocks as transcript quotes.
///
/// System notices (background-shell settlements, inter-agent mail, task
/// completions) reach the transcript verbatim, tags included — which read
/// like debug noise. This rewrites the tagged block into `> ` lines that
/// AnsiMarkdown formats as a dim blockquote with a `⚙` marker, so a
/// notice looks like a sidebar note instead of leaked markup. Non-notice
/// text passes through untouched, and the model-visible session records
/// keep the raw tags — only the TUI view changes.
library;

const _openTag = '<system-notice>';
const _closeTag = '</system-notice>';
const _taskOpenPrefix = '<task-result';
const _taskCloseTag = '</task-result>';

/// Line prefixes of plain-text service notes that get the same quote
/// treatment: compaction and maintenance receipts written by the harness.
const _servicePrefixes = [
  '[auto-compacted',
  '[context trimmed',
  '[memory maintained',
];

/// Splits [text] into transcript lines with notice blocks restyled.
/// Streaming-safe for the complete-block writes notices actually use; an
/// unterminated open tag renders as a quote from that line onward.
List<String> renderSystemNoticeLines(String text) {
  final needsRewrite =
      text.contains(_openTag) ||
      text.contains(_taskOpenPrefix) ||
      _servicePrefixes.any(text.contains);
  if (!needsRewrite) return text.split('\n');
  final out = <String>[];
  var inside = false;
  var closer = '';
  for (final line in text.split('\n')) {
    if (!inside && _servicePrefixes.any(line.trimLeft().startsWith)) {
      out.add('> ⚙ ${line.trim()}');
      continue;
    }
    var rest = line;
    while (true) {
      if (!inside) {
        // `<task-result` may carry attributes (`<task-result id="a">`):
        // match the prefix and consume through the tag's own `>`.
        final i1 = rest.indexOf(_openTag);
        final i2 = rest.indexOf(_taskOpenPrefix);
        final int i;
        String opener;
        if (i1 < 0) {
          i = i2;
        } else if (i2 < 0) {
          i = i1;
        } else {
          i = i1 < i2 ? i1 : i2;
        }
        if (i < 0) {
          out.add(rest);
          break;
        }
        out.addAll(_noticeLine(rest.substring(0, i)));
        if (i == i1) {
          opener = _openTag;
          closer = _closeTag;
        } else {
          opener = _taskOpenPrefix;
          closer = _taskCloseTag;
        }
        var end = i + opener.length;
        if (opener == _taskOpenPrefix) {
          final gt = rest.indexOf('>', end - 1);
          if (gt < 0) {
            out.add(rest);
            break;
          }
          end = gt + 1;
        }
        rest = rest.substring(end);
        inside = true;
      } else {
        final i = rest.indexOf(closer);
        if (i < 0) {
          out.addAll(_noticeLine(rest));
          break;
        }
        out.addAll(_noticeLine(rest.substring(0, i)));
        rest = rest.substring(i + closer.length);
        inside = false;
        // A close tag consuming the whole rest leaves nothing to emit.
        if (rest.isEmpty) break;
      }
    }
  }
  return out;
}

List<String> _noticeLine(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return const [];
  return ['> ⚙ $trimmed'];
}
