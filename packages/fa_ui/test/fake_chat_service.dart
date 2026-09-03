// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Stand-in backend for widget tests: satisfies the full [FaChatService]
/// surface with no-ops and feeds the trajectory ledger through a real
/// [TrajectoryServiceFeed] (available as [feed]).
class FakeChatService extends ChangeNotifier implements FaChatService {
  final TrajectoryServiceFeed feed = TrajectoryServiceFeed();

  @override
  Stream<TrajectorySnapshot> get trajectory => feed.stream;
  @override
  List<FaChatMessage> get messages => const [];
  @override
  ExecutionEnv? get sandboxEnv => null;
  @override
  bool get isStreaming => false;
  @override
  String? get error => null;
  @override
  List<String> get pendingSteerTexts => const [];
  @override
  Future<void> sendText(String text) async {}
  @override
  Future<void> sendAttachments({
    required List<FaStagedAttachment> attachments,
    String text = '',
  }) async {}
  @override
  Future<String> stageAttachment({
    required String name,
    required Uint8List bytes,
  }) async => name;
  @override
  Future<void> discardStagedAttachment(String path) async {}
  @override
  void abort() {}
  @override
  String transcriptMarkdown() => '';
  @override
  ApprovalPrompt? approvalPromptHandler;
  @override
  AskCallback? askHandler;
  @override
  RequestSecretCallback? secretRequestHandler;
  @override
  ApprovalManager get approval => ApprovalManager();
  @override
  void setApprovalMode(ApprovalMode mode) {}
}
