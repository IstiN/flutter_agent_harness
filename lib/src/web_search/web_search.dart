/// Web search and page extraction for the agent: the `web_search` tool
/// (provider chain: keyless DuckDuckGo first, keyed Brave/Tavily behind
/// secrets) and the `web_fetch` companion (pages → structured markdown with
/// link anchors preserved, site handlers behind one interface — pub.dev
/// shipped, GitHub/arXiv as follow-ups).
///
/// Ported from oh-my-pi `packages/coding-agent/src/web/` (see the per-file
/// docs for the exact sources and deliberate divergences). All HTTP goes
/// through an injectable `package:http` client; the library is pure Dart.
library;

export 'fetch_types.dart';
export 'html_markdown.dart';
export 'html_text.dart';
export 'providers.dart';
export 'search_types.dart';
export 'site_handlers.dart';
export 'web_fetch_tool.dart';
export 'web_search_tool.dart';
