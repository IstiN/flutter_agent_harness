// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

// Part of agent_service.dart: the system-prompt composition lives here so
// the main file stays under the 2800-line guard (the same part-file
// discipline as the other agent_service_*.dart members). The class keeps
// thin static accessors; the composition itself is library-private
// top-level so both the class and its parts share it.

part of 'agent_service.dart';

/// The platform whose commands the system prompt advertises, decided with
/// the same signal [createPlatformEnv] uses to pick the [ExecutionEnv]:
/// web → android / ios → desktop.
SandboxPlatform _sandboxPlatformOf() => isWebPlatform
    ? SandboxPlatform.web
    : isAndroidPlatform
    ? SandboxPlatform.android
    : isIosPlatform
    ? SandboxPlatform.ios
    : SandboxPlatform.desktop;

/// The system prompt plus a secret-name hint (names only, never values).
///
/// The `{{commands}}` placeholder is filled from the central sandbox
/// registry ([formatSandboxCommandSection]) for the current platform, so
/// the model sees exactly the shell commands that exist here. Sandboxed
/// hosts (web/android/ios) additionally get the host-profile section
/// ([formatSandboxHostProfile], issue #692 B) pinning the runtime reality
/// (platform, WASI, no sockets, tool classes, WASI failure first aid);
/// the desktop prompt stays byte-identical (issue #692 AC2).
String _effectiveAgentSystemPrompt(
  AgentConfig config,
  SecretRedactor? redactor, [
  SandboxPlatform? platformOverride,
]) {
  final platform = platformOverride ?? _sandboxPlatformOf();
  final commandSection = formatSandboxCommandSection(platform);
  debugPrint(
    '[Fa] system prompt platform=$platform, '
    'commands section ${commandSection.length} chars',
  );
  var base = (config.systemPrompt ?? sandboxSystemPrompt).replaceAll(
    '{{commands}}',
    commandSection,
  );
  final hostProfile = formatSandboxHostProfile(platform);
  if (hostProfile.isNotEmpty) {
    base = '$base\n\n$hostProfile';
  }
  final names = redactor?.names ?? const <String>[];
  final now = DateTime.now();
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hh = offset.inHours.abs().toString().padLeft(2, '0');
  final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  final dated =
      '$base\n\nCurrent date and time: ${now.toIso8601String()} '
      '(local device time, UTC$sign$hh:$mm). Use this for any date- or '
      'time-relative reasoning ("today", "tomorrow", "this week").';
  if (names.isEmpty) return dated;
  return '$dated\n\nAvailable secret env vars: ${names.join(', ')} — '
      'reference them as \$NAME in shell commands; never ask the user for '
      'their values and never print them.';
}
