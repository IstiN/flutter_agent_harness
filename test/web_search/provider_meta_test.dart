// Metadata getters (id/label/apiKeyName/role) — trivial members that the
// CRAP ratchet still counts when uncovered (CC x 0% coverage).
import 'package:flutter_agent_harness/src/types.dart';
import 'package:flutter_agent_harness/src/web_search/providers.dart';
import 'package:flutter_agent_harness/src/web_search/site_handlers.dart';
import 'package:test/test.dart';

void main() {
  test('search provider metadata', () {
    const ddg = DuckDuckGoSearchProvider();
    expect(ddg.id, 'duckduckgo');
    expect(ddg.label, 'DuckDuckGo');
    expect(ddg.apiKeyName, isNull);

    const brave = BraveSearchProvider();
    expect(brave.id, 'brave');
    expect(brave.label, 'Brave');
    expect(brave.apiKeyName, 'BRAVE_API_KEY');

    const tavily = TavilySearchProvider();
    expect(tavily.id, 'tavily');
    expect(tavily.label, 'Tavily');
    expect(tavily.apiKeyName, 'TAVILY_API_KEY');

    const pubDev = PubDevHandler();
    expect(pubDev.id, 'pub.dev');
  });

  test('assistant message role is assistant', () {
    final message = AssistantMessage(
      content: const [TextContent(text: 'hi')],
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );
    expect(message.role, 'assistant');
  });
}
