/// Minimal glob matching for skill/agent activation patterns (`paths:`,
/// `applyTo:`): supports `*` (one path segment), `**` (any depth, `**/`
/// also matches zero directories) and `?` (one char). No external
/// dependency — the patterns here never need character classes or braces.
library;

/// Compiles a glob [pattern] into an anchored [RegExp].
RegExp globToRegExp(String pattern) {
  final buffer = StringBuffer('^');
  var i = 0;
  while (i < pattern.length) {
    final char = pattern[i];
    if (char == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        var next = i + 2;
        if (next < pattern.length && pattern[next] == '/') {
          // `**/` crosses any number of directories, including zero.
          buffer.write('(?:.*/)?');
          next++;
        } else {
          buffer.write('.*');
        }
        i = next;
      } else {
        buffer.write('[^/]*');
        i++;
      }
    } else if (char == '?') {
      buffer.write('[^/]');
      i++;
    } else {
      buffer.write(RegExp.escape(char));
      i++;
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

/// Whether [path] matches the glob [pattern] (both `/`-separated).
bool globMatches(String pattern, String path) =>
    globToRegExp(pattern).hasMatch(path);
