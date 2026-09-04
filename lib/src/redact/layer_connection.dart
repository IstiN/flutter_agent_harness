/// L6: passwords embedded in connection URLs.
///
/// Matches `scheme://user:password@host` forms (postgres[ql], mysql,
/// mongodb(+srv), redis(s), amqp, mqtt, mssql, ftp, http(s), ssh) and masks
/// ONLY the password span. The password may contain special characters
/// including `@`, `:` and `/`: the greedy scan takes everything up to the
/// last `@` before the host part.
library;

import 'redaction_types.dart';

/// Marker label used for connection-string passwords.
const String connectionPasswordLabel = 'Connection String Password';

final RegExp _connectionUrl = RegExp(
  r'\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?'
  r'|mqtts?|mssql|ftps?|https?|ssh)://'
  r'([^\s:@/]+):' // user
  r'([^\s]+)' // password, may contain @ : / (greedy up to the last @)
  r'@'
  r'(?=[^\s@/])', // host begins here
  caseSensitive: false,
);

/// Finds connection-string password spans in [text].
///
/// Pure function; URLs without a `user:password@` authority yield nothing.
List<RedactionMatch> layerConnection(String text, RedactionConfig cfg) {
  if (text.isEmpty || !text.contains('://')) return const [];
  final matches = <RedactionMatch>[];
  for (final m in _connectionUrl.allMatches(text)) {
    // dart:core Match has no group offsets, so locate the password as the
    // run between the user separator (first ':' after '://') and the last
    // '@' of the matched segment (the regex guarantees both exist).
    final segment = text.substring(m.start, m.end);
    final userSep = segment.indexOf(':', segment.indexOf('://') + 3);
    final hostSep = segment.lastIndexOf('@');
    if (userSep < 0 || hostSep <= userSep) continue;
    matches.add(
      RedactionMatch(
        start: m.start + userSep + 1,
        end: m.start + hostSep,
        layer: RedactionLayer.connection,
        kindLabel: connectionPasswordLabel,
      ),
    );
  }
  return matches;
}
