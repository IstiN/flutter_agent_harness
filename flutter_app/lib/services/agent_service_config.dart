// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the yaml config application internals
// (issue #1078) — ttsr attach + the live redaction toggle — live here so
// the main file stays under the 2800-line guard. Same library, so
// private members resolve.

part of 'agent_service.dart';

extension AgentServiceAppConfig on AgentService {
  /// Attaches the ttsr controller when the yaml section ships rules
  /// (issue #1078 AC3) — the CLI's exact pair ([TtsrManager] over
  /// [TtsrController]) watching this agent's stream. Injections persist
  /// through the same crash-safe chain the transcript uses
  /// ([AgentServicePersistence]); the closure reads the LIVE session, so
  /// a session switch re-points the sink without a re-attach.
  void _attachAppConfigTtsr(AppFahSections? appConfig) {
    final ttsr = appConfig?.ttsr;
    if (ttsr == null || !ttsr.settings.enabled) return;
    final manager = TtsrManager(settings: ttsr.settings);
    for (final rule in ttsr.rules) {
      manager.addRule(rule);
    }
    for (final warning in manager.warnings) {
      AppLog.i('ttsr', warning);
    }
    if (!manager.hasRules()) return;
    // The controller self-subscribes (it owns its unsubscribe); no other
    // lifecycle is needed — session switches ride the live sink closure.
    TtsrController(
      agent: _agent,
      manager: manager,
      sink: TtsrSessionSink(
        session: () => _session,
        persistedMessageCount: () => _persistedCount,
        persistMessage: (message) async {
          final session = _session;
          if (session == null) return;
          await session.appendMessage(message);
          _persistedCount++;
        },
        persistInjection: (content, ruleNames) async {
          final session = _session;
          if (session == null) return;
          await session.appendCustomMessageEntry(
            customType: ttsrInjectionCustomType,
            content: content,
            display: false,
            details: {'rules': ruleNames},
          );
          await session.appendCustomEntry(
            customType: ttsrInjectionRecordType,
            data: {'rules': ruleNames},
          );
          _persistedCount++;
        },
      ),
      onTriggered: (rules) => AppLog.i(
        'ttsr',
        'rule violation: '
        '${rules.map((rule) => rule.name).join(', ')} — retrying',
      ),
      onWarning: (message) => AppLog.i('ttsr', message),
    );
  }

  /// Live redaction toggle (issue #1078 AC4/E3 — the settings-screen
  /// surface, mirroring the CLI settings flow): flips the layered
  /// pipeline's config in place, building + attaching it on demand when
  /// redaction was yaml-disabled or never configured. Persistence of the
  /// choice is the caller's (settings store) — this is the engine side.
  void setRedactionEnabled(bool enabled) {
    final pipeline = _redactionPipeline;
    if (pipeline == null) {
      if (!enabled) return;
      _redactionPipeline = RedactionPipeline(
        registeredSecrets: const [],
        config: (_yamlRedactConfig ?? const RedactionConfig()).copyWith(
          enabled: true,
        ),
      );
      attachRedactionPipeline(_agent, _redactionPipeline!);
      return;
    }
    pipeline.config = pipeline.config.copyWith(enabled: enabled);
  }
}
