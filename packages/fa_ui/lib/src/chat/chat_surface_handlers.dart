// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        ApprovalDecision,
        ApprovalRequest,
        AskAnswer,
        AskQuestion,
        RequestSecretResult;

import 'approval_ui.dart';
import 'ask_ui.dart';
import 'fa_chat_service.dart';
import 'secret_request_sheet.dart';

/// Installs the interactive handler trio — approval dialog, ask sheet,
/// secret-request sheet — on a chat service for as long as a chat
/// SURFACE is showing. [FaChatScreen] hosts its own copies of this
/// wiring; this binder exists for surfaces that render their own
/// transcript instead (the extension panel's session sheet), which
/// previously shipped with NO handlers — every approval then stalled on
/// the service-worker's 120s backstop and was denied with the user never
/// asked.
///
/// Attach on show (and whenever the active service changes), detach on
/// hide/dispose. Detach clears exactly the handlers this binder
/// installed — a foreign handler (tests, an embedding host) survives.
final class FaChatSurfaceHandlers {
  /// Creates a binder bound to [context]'s Navigator. The context is
  /// only used when a dialog/sheet actually shows; a defunct context
  /// makes every handler resolve to the conservative default (deny /
  /// cancelled / declined).
  FaChatSurfaceHandlers({required BuildContext context}) : _context = context;

  BuildContext _context;
  FaChatService? _service;

  /// Installs the trio on [service]. Attaching over an already-bound
  /// service is a no-op; attaching a DIFFERENT service moves the trio.
  void attach(FaChatService service) {
    if (identical(_service, service)) return;
    detach();
    _service = service;
    service.approvalPromptHandler ??= _handleApprovalPrompt;
    service.askHandler ??= _handleAsk;
    service.secretRequestHandler ??= _handleSecretRequest;
  }

  /// Clears the trio from the bound service — only slots this binder
  /// filled; a foreign handler stays.
  void detach() {
    final service = _service;
    if (service == null) return;
    _service = null;
    if (service.approvalPromptHandler == _handleApprovalPrompt) {
      service.approvalPromptHandler = null;
    }
    if (service.askHandler == _handleAsk) {
      service.askHandler = null;
    }
    if (service.secretRequestHandler == _handleSecretRequest) {
      service.secretRequestHandler = null;
    }
  }

  /// Retargets an attached binder at a new Navigator context (a surface
  /// that outlives its original element).
  void updateContext(BuildContext context) => _context = context;

  Future<ApprovalDecision> _handleApprovalPrompt(ApprovalRequest request) {
    if (!_mounted) return Future.value(ApprovalDecision.deny);
    return showApprovalPrompt(_context, request);
  }

  Future<List<AskAnswer>?> _handleAsk(List<AskQuestion> questions) {
    if (!_mounted) return Future.value(null);
    return showAskSheet(_context, questions);
  }

  Future<RequestSecretResult?> _handleSecretRequest(
    String name,
    String reason,
  ) {
    if (!_mounted) return Future.value(null);
    return showSecretRequestSheet(_context, name, reason);
  }

  bool get _mounted => _context.mounted;
}
