/// A single message in a conversational LLM exchange.
///
/// [images] are base64 data URLs (e.g. `data:image/png;base64,...`) used by
/// vision-capable models. They are serialized into OpenAI-compatible content
/// blocks.
class LlmMessage {
  final String role;
  final String content;
  final List<String>? images;

  const LlmMessage({required this.role, required this.content, this.images});

  Map<String, dynamic> toJson() {
    final hasImages = images != null && images!.isNotEmpty;
    if (!hasImages) {
      return {'role': role, 'content': content};
    }

    final contentList = <Map<String, dynamic>>[
      {'type': 'text', 'text': content},
    ];
    for (final image in images!) {
      contentList.add({
        'type': 'image_url',
        'image_url': {'url': image},
      });
    }

    return {'role': role, 'content': contentList};
  }
}
