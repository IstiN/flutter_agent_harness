/// The three conversation kinds supported by the messenger projection.
enum ChatListEntryKind { localAgent, networkChannel, networkAgent }

/// Presence supplied by the network aggregate. Local sessions use streaming
/// metadata instead of pretending to have network presence.
enum ChatPresence { live, busy, offline }

/// Stable, typed identity for a conversation row.
///
/// A local session id and a network channel/agent id may be identical. The
/// kind and network id are therefore part of identity, not just presentation.
final class ChatEntryId {
  const ChatEntryId._(this.kind, this.networkId, this.value);

  factory ChatEntryId.local(String sessionId) =>
      ChatEntryId._(ChatListEntryKind.localAgent, null, sessionId);

  factory ChatEntryId.network(
    ChatListEntryKind kind, {
    required String networkId,
    required String id,
  }) {
    assert(kind != ChatListEntryKind.localAgent);
    return ChatEntryId._(kind, networkId, id);
  }

  final ChatListEntryKind kind;
  final String? networkId;
  final String value;

  /// Persistence-safe canonical form. Length-prefixing would be unnecessary
  /// here: the separators are namespaced by the typed prefix and ids remain
  /// opaque (no parsing is performed by the stores).
  String get canonical => kind == ChatListEntryKind.localAgent
      ? 'local:$value'
      : 'network:${kind.name}:$networkId:$value';

  @override
  String toString() => canonical;

  @override
  bool operator ==(Object other) =>
      other is ChatEntryId &&
      other.kind == kind &&
      other.networkId == networkId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(kind, networkId, value);
}

/// Opaque reference to the last aggregate inbox envelope.
///
/// [payload] deliberately has no chat-list interpretation. Decryption and
/// preview extraction belong to the later typed network-detail integration.
final class NetworkEnvelopeRef {
  const NetworkEnvelopeRef({
    required this.id,
    required this.createdAt,
    required this.senderId,
    required this.senderName,
    required this.senderKey,
    required this.payload,
    required this.mentions,
  });

  final String id;
  final String createdAt;
  final String senderId;
  final String senderName;
  final String senderKey;
  final Object? payload;
  final List<String> mentions;

  factory NetworkEnvelopeRef.fromJson(Map<String, dynamic> json) =>
      NetworkEnvelopeRef(
        id: json['id'] as String? ?? '',
        createdAt: json['createdAt'] as String? ?? '',
        senderId: json['senderId'] as String? ?? '',
        senderName: json['senderName'] as String? ?? '',
        senderKey: json['senderKey'] as String? ?? '',
        payload: json['payload'],
        mentions: [
          for (final value in json['mentions'] as List? ?? const [])
            if (value is String) value,
        ],
      );
}

/// One source-independent messenger conversation projection.
final class ChatListEntry {
  const ChatListEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdAt,
    this.networkId,
    this.networkName,
    this.folderName,
    this.folderPath,
    this.avatarUrl,
    this.avatarLabel,
    this.preview,
    this.lastActivity,
    this.unreadCount,
    this.pinned = false,
    this.presence,
    this.isStreaming = false,
    this.isLoading = false,
    this.parentId,
    this.isSubagent = false,
    this.localMessageCount,
    this.lastEnvelope,
  });

  final ChatEntryId id;
  final ChatListEntryKind kind;
  final String? networkId;
  final String? networkName;
  final String? folderName;

  /// Full local working directory used to distinguish equal folder names.
  final String? folderPath;
  final String title;
  final String? avatarUrl;
  final String? avatarLabel;
  final String? preview;
  final DateTime createdAt;
  final DateTime? lastActivity;

  /// Null means unknown/not applicable, never zero.
  final int? unreadCount;
  final bool pinned;
  final ChatPresence? presence;
  final bool isStreaming;
  final bool isLoading;

  /// Local tree metadata retained from the session projection.
  final String? parentId;
  final bool isSubagent;

  /// Monotonic local read cursor unit (the live transcript message count).
  final int? localMessageCount;
  final NetworkEnvelopeRef? lastEnvelope;

  ChatListEntry copyWith({bool? pinned, int? unreadCount}) => ChatListEntry(
    id: id,
    kind: kind,
    networkId: networkId,
    networkName: networkName,
    folderName: folderName,
    folderPath: folderPath,
    title: title,
    avatarUrl: avatarUrl,
    avatarLabel: avatarLabel,
    preview: preview,
    createdAt: createdAt,
    lastActivity: lastActivity,
    unreadCount: unreadCount ?? this.unreadCount,
    pinned: pinned ?? this.pinned,
    presence: presence,
    isStreaming: isStreaming,
    isLoading: isLoading,
    parentId: parentId,
    isSubagent: isSubagent,
    localMessageCount: localMessageCount,
    lastEnvelope: lastEnvelope,
  );
}
