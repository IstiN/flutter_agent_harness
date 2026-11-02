// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

/// A staged attachment belonging to an unsent composer draft.
///
/// The sandbox [path], original [bytes], display [name], and [mimeType] all
/// stay together so restoring a draft does not change the subsequent upload.
typedef ChatComposerDraftAttachment = ({
  String name,
  String path,
  Uint8List bytes,
  String mimeType,
});

/// An immutable-by-convention snapshot of unsent composer state.
final class ChatComposerDraft {
  const ChatComposerDraft({
    this.text = '',
    this.attachments = const <ChatComposerDraftAttachment>[],
  });

  final String text;
  final List<ChatComposerDraftAttachment> attachments;

  bool get isEmpty => text.isEmpty && attachments.isEmpty;
}

/// Process-lifetime drafts keyed by conversation owner.
///
/// The store deliberately holds only text and attachment values, never a
/// text-editing controller, focus node, service, or listener. Each composer
/// therefore keeps ownership of its disposable UI resources while its unsent
/// content can survive an unmount. This is not durable disk persistence.
final class ChatComposerDraftStore {
  ChatComposerDraftStore();

  /// Shared process-lifetime store used when a composer is not given one.
  static final ChatComposerDraftStore shared = ChatComposerDraftStore();

  final Map<Object, ChatComposerDraft> _drafts = {};

  static const ChatComposerDraft _empty = ChatComposerDraft();

  ChatComposerDraft draftFor(Object key) => _drafts[key] ?? _empty;

  void save(Object key, ChatComposerDraft draft) {
    if (draft.isEmpty) {
      _drafts.remove(key);
      return;
    }
    _drafts[key] = ChatComposerDraft(
      text: draft.text,
      attachments: List<ChatComposerDraftAttachment>.unmodifiable(
        draft.attachments,
      ),
    );
  }

  /// Clears only [key]; other conversations keep their unsent drafts.
  void clear(Object key) => _drafts.remove(key);
}
