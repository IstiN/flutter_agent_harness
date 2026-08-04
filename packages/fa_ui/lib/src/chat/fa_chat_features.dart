// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Feature flags for [FaChatScreen]: every capability beyond plain
/// text-in/text-out is opt-out per host. A minimal host (no sandbox, no
/// attachments, no voice) turns the flags off and gets a clean simple chat.
final class FaChatFeatures {
  /// Creates a feature set; everything on by default.
  const FaChatFeatures({
    this.attachments = true,
    this.voiceInput = true,
    this.approvals = true,
    this.askSheets = true,
    this.secretRequests = true,
    this.mediaPlayback = true,
    this.thinkingBlocks = true,
    this.copyTranscript = true,
    this.fileBrowser = true,
    this.appLauncher = true,
  });

  /// Minimal text chat: everything optional off.
  const FaChatFeatures.minimal()
    : attachments = false,
      voiceInput = false,
      approvals = false,
      askSheets = false,
      secretRequests = false,
      mediaPlayback = false,
      thinkingBlocks = false,
      copyTranscript = false,
      fileBrowser = false,
      appLauncher = false;

  /// Composer attachment button (gallery/camera/file picking + sandbox
  /// staging via [FaChatService.stageAttachment]).
  final bool attachments;

  /// Microphone button (requires the host ASR hook — see FaChatHost).
  final bool voiceInput;

  /// Approval prompts and the composer approval-mode selector.
  final bool approvals;

  /// `ask_user` sheets (multi-step questions from the agent).
  final bool askSheets;

  /// Secret-request sheets (agent asks for an API key mid-run).
  final bool secretRequests;

  /// Inline audio/video playback inside message tiles.
  final bool mediaPlayback;

  /// Collapsible thinking/reasoning blocks in assistant tiles.
  final bool thinkingBlocks;

  /// The copy-transcript toolbar action.
  final bool copyTranscript;

  /// The files side panel (requires `FaChatHost.fileBrowserBuilder`).
  final bool fileBrowser;

  /// Launching js mini-apps from tool results (requires
  /// `FaChatHost.appLauncher`).
  final bool appLauncher;
}
