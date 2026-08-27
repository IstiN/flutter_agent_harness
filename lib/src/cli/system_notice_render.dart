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

/// Splits [text] into transcript lines with notice blocks restyled.
/// Streaming-safe for the complete-block writes notices actually use; an
/// unterminated open tag renders as a quote from that line onward.
List<String> renderSystemNoticeLines(String text) {
  if (!text.contains(_openTag)) return text.split('\n');
  final out = <String>[];
  var inside = false;
  for (final line in text.split('\n')) {
    var rest = line;
    while (true) {
      if (!inside) {
        final i = rest.indexOf(_openTag);
        if (i < 0) {
          out.add(rest);
          break;
        }
        out.addAll(_noticeLine(rest.substring(0, i)));
        rest = rest.substring(i + _openTag.length);
        inside = true;
      } else {
        final i = rest.indexOf(_closeTag);
        if (i < 0) {
          out.addAll(_noticeLine(rest));
          break;
        }
        out.addAll(_noticeLine(rest.substring(0, i)));
        rest = rest.substring(i + _closeTag.length);
        inside = false;
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
