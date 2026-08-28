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
bool _needsRewrite(String text) =>
    text.contains(_openTag) ||
    text.contains(_taskOpenPrefix) ||
    _servicePrefixes.any(text.contains);

bool _isServiceLine(String line, bool inside) =>
    !inside && _servicePrefixes.any(line.trimLeft().startsWith);

/// The earliest opener tag in [rest] with its opener text and matching
/// closer — `(-1, '', '')` when none. `<task-result` may carry attributes
/// (`<task-result id="a">`); the opener's own `>` decides the real end
/// (see [_taskOpenerEnd]).
(int, String, String) _nextOpenTag(String rest) {
  final i1 = rest.indexOf(_openTag);
  final i2 = rest.indexOf(_taskOpenPrefix);
  final int i;
  if (i1 < 0) {
    i = i2;
  } else if (i2 < 0) {
    i = i1;
  } else {
    i = i1 < i2 ? i1 : i2;
  }
  if (i < 0) return (-1, '', '');
  if (i == i1) return (i, _openTag, _closeTag);
  return (i, _taskOpenPrefix, _taskCloseTag);
}

/// The substring end after the opener at [from] — task openers extend
/// through their tag's own `>`; -1 when it has none (malformed).
int _taskOpenerEnd(String rest, int from) {
  final gt = rest.indexOf('>', from - 1);
  return gt < 0 ? -1 : gt + 1;
}

List<String> renderSystemNoticeLines(String text) {
  if (!_needsRewrite(text)) return text.split('\n');
  final out = <String>[];
  var inside = false;
  var closer = '';
  for (final line in text.split('\n')) {
    if (_isServiceLine(line, inside)) {
      out.add('> ⚙ ${line.trim()}');
      continue;
    }
    var rest = line;
    while (true) {
      if (!inside) {
        final (index, opener, tagCloser) = _nextOpenTag(rest);
        if (index < 0) {
          out.add(rest);
          break;
        }
        out.addAll(_noticeLine(rest.substring(0, index)));
        closer = tagCloser;
        var end = index + opener.length;
        if (opener == _taskOpenPrefix) {
          final gtEnd = _taskOpenerEnd(rest, end);
          if (gtEnd < 0) {
            out.add(rest);
            break;
          }
          end = gtEnd;
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
