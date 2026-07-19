/// Shared display formatting for the built-in tools.
library;

/// Formats a byte count as a human-readable size (pi's `formatSize`).
String formatToolSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
