import 'package:fa_llm/src/llm_message.dart';
import 'package:test/test.dart';

void main() {
  test('serializes text-only message', () {
    const message = LlmMessage(role: 'user', content: 'hello');
    expect(message.toJson(), {'role': 'user', 'content': 'hello'});
  });

  test('serializes message with images', () {
    const message = LlmMessage(
      role: 'user',
      content: 'look',
      images: ['data:image/png;base64,abc'],
    );
    final json = message.toJson();
    expect(json['role'], 'user');
    final content = json['content'] as List<dynamic>;
    expect(content.length, 2);
    expect(content.first, {'type': 'text', 'text': 'look'});
    expect(content.last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,abc'},
    });
  });

  test('serializes text-only when images list is empty', () {
    const message = LlmMessage(role: 'user', content: 'hello', images: []);
    expect(message.toJson(), {'role': 'user', 'content': 'hello'});
  });
}
