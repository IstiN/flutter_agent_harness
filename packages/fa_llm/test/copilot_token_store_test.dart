import 'package:fa_llm/src/copilot/copilot_token_store.dart';
import 'package:test/test.dart';

void main() {
  test('writes then reads a token by name', () async {
    final store = MemoryCopilotTokenStore();
    await store.write('copilot-alice', 'gho_1');
    expect(await store.read('copilot-alice'), 'gho_1');
  });

  test('missing key reads null', () async {
    final store = MemoryCopilotTokenStore();
    expect(await store.read('nope'), isNull);
  });

  test('delete removes the key', () async {
    final store = MemoryCopilotTokenStore();
    await store.write('copilot-alice', 'gho_1');
    await store.delete('copilot-alice');
    expect(await store.read('copilot-alice'), isNull);
  });

  test('delete of a missing key is a no-op', () async {
    final store = MemoryCopilotTokenStore();
    await store.delete('nope');
  });

  test('names are isolated', () async {
    final store = MemoryCopilotTokenStore();
    await store.write('copilot-alice', 'gho_1');
    await store.write('copilot-bob', 'gho_2');
    expect(await store.read('copilot-alice'), 'gho_1');
    expect(await store.read('copilot-bob'), 'gho_2');
    await store.write('copilot-alice', 'gho_3');
    expect(await store.read('copilot-alice'), 'gho_3');
    expect(await store.read('copilot-bob'), 'gho_2');
  });
}
