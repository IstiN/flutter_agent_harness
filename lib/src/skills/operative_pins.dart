/// Compaction-pinned skill operative lines (gh-1409): a skill's
/// `operative:` directives become durable session context — pinned
/// verbatim across every compaction fold and re-injected on resume —
/// instead of dying silently in the summarizer's paraphrase.
///
/// The registry is DERIVED state, rebuilt at provider-request assembly
/// from the skills known to the host (the image-registry pattern,
/// `../agent/image_registry.dart`): the session JSONL stays byte-identical
/// (P1), identical window + identical manifests rebuild an identical pin
/// set and carrier placement (P2), and every rendered pin is byte-identical
/// to its declared front-matter string (P3) — the pipeline cannot
/// paraphrase a pin because the carrier text is generated here, from the
/// registry, never from summary memory.
///
/// Invariants mirrored from the image registry:
///
/// - **P4 (no dangling, never silent):** a pin whose owner skill is no
///   longer discoverable is dropped with a notice naming the skill
///   ([SkillOperativePins.diff] reports it; resume notices render it).
/// - **P5 (no silent rebind):** a content-key change supersedes the old
///   pin and is reported — never a silently swapped instruction.
/// - **P6 (budget, never silent):** pins are capped per window
///   ([defaultPinBudgetChars], the `defaultMaxImagesPerRequest`
///   precedent); overflow drops by priority (current-session reads >
///   newest > older) with a drop notice.
/// - **Consent inheritance (F7):** pins inherit exactly the discovery
///   consent state of reads — an unconsented third-party skill never
///   reaches [SkillOperativePins.build] because `discoverSkills` already
///   filtered it out; no second gate, no second bypass.
///
/// Security posture: pins are rendered as notice TEXT inside a
/// harness-generated fixed wrapper, never as system-role instructions and
/// never as user input; a hostile `operative:` line is inert quoted text
/// (E8). Pinning changes persistence, not permission.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../compaction/structured/markers.dart'
    show
        isCompactionMarkerText,
        localTrimMarkerPrefix,
        pinBlockCloseTag,
        pinBlockOpenTag;
import '../context.dart' show UserMessage, ToolResultMessage;
import '../session/session_tree.dart'
    show branchSummaryPrefix, compactionSummaryPrefix;
import '../types.dart';
import 'skills.dart' show Skill;

// The pin block's fixed wrapper tags live in ONE place
// (`compaction/structured/markers.dart`) next to the sanitizer's envelope
// match, so a renderer rename cannot silently orphan the sanitizer's
// exemption (review gh-1409 round 2, suggestion 5). Re-exported here for
// the established consumers of this library.
export '../compaction/structured/markers.dart'
    show pinBlockCloseTag, pinBlockOpenTag;

/// Default per-window pin budget in characters (gh-1409 Q3: ~2048 tokens
/// at the 4-chars/token heuristic). Lines vary in length, so the budget is
/// measured over the RENDERED carrier block, not per-pin count.
const defaultPinBudgetChars = 8192;

/// The previous window's pin registry — the diff baseline behind the P4/P5
/// lifecycle notices (supersede/drop). Process-wide like
/// [operativePinNotice] (supported hosts run one agent per process);
/// tests reset it directly between cases.
SkillOperativePins? lastOperativePinRegistry;

/// Settings for the skill-pin surface (`skills.pins` config precedent,
/// same process-wide pattern as `imageRegistryConfig`): the carrier
/// injection happens deep inside the agent loop's request build, far from
/// any host config object.
class OperativePinConfig {
  const OperativePinConfig({this.enabled = true, this.budgetChars});

  /// Kill switch: `false` reproduces today's request shape byte-for-byte
  /// (no carrier injection at all).
  final bool enabled;

  /// Per-window pin budget in characters; `null` → [defaultPinBudgetChars].
  final int? budgetChars;
}

/// Process-wide skill-pin settings. An IN-CODE knob for now: no host or
/// config section publishes it yet (unlike the `imageRegistryConfig`
/// precedent, which is wired from the `images:` yaml section at boot).
/// Tests and embedders may assign it before first use; the `enabled`
/// kill switch and [OperativePinConfig.budgetChars] are unreachable from
/// host config until a `skills.pins:` section is wired.
OperativePinConfig operativePinConfig = const OperativePinConfig();

/// Host-visible pin notice (drops, supersedes, repairs — never silent).
/// Set by hosts that surface them (CLI prints a dim transcript line; the
/// app logs via AppLog). Same pattern as `imageDropNotice`.
void Function(String notice)? operativePinNotice;

/// Where a pinned line came from: the owning skill's name and file path
/// (the "source root" of the ticket's provenance requirement — every
/// rendered pin names its owner).
class PinProvenance {
  const PinProvenance({required this.skillName, required this.skillPath});

  /// The owning skill's name.
  final String skillName;

  /// The owning SKILL.md path (first-party, builtin://, or granted
  /// third-party — consent was already applied at discovery).
  final String skillPath;
}

/// One pinned operative line: content-keyed, provenance-tagged (E3: a
/// line declared by two skills is ONE pin with dual provenance and a
/// single content key; E10: keys are exact bytes — lookalike lines are
/// distinct pins, no fuzzy merging).
class OperativePin {
  const OperativePin({required this.line, required this.provenance});

  /// The verbatim declared line — byte-identical to the frontmatter
  /// string in every rendered context (P3).
  final String line;

  /// Ordered, deduped provenance (first-declared skill first).
  final List<PinProvenance> provenance;

  /// Content key: SHA-256 over the exact UTF-8 bytes of [line] (E10).
  String get contentKey => sha256.convert(utf8.encode(line)).toString();

  /// Whether [skillName] is one of the owning skills.
  bool ownedBy(String skillName) =>
      provenance.any((p) => p.skillName == skillName);
}

/// One pin dropped by the per-window budget (P6: never silent).
class DroppedPin {
  const DroppedPin({required this.pin, required this.reason});

  final OperativePin pin;

  /// Machine-readable drop reason (`budget` today).
  final String reason;
}

/// The per-window pin registry: rebuilt deterministically from the skills
/// known to the session (P2), content-keyed, budget-capped.
class SkillOperativePins {
  const SkillOperativePins._(this.pins, this.dropped);

  /// The empty registry (no kept pins, no drops) — the all-skills-gone
  /// baseline for the P4 lifecycle diff (round 3: the empty-list corner).
  static const SkillOperativePins empty = SkillOperativePins._([], []);

  /// The kept pins, ordered: current-session reads first (P6 priority),
  /// then first-declared order.
  final List<OperativePin> pins;

  /// Pins dropped by the budget, in drop order.
  final List<DroppedPin> dropped;

  /// Whether no pins are kept.
  bool get isEmpty => pins.isEmpty;

  /// The `{content key → pin}` map of the kept pins.
  Map<String, OperativePin> get pinByKey => {
    for (final pin in pins) pin.contentKey: pin,
  };

  /// Rebuilds the registry from [skills] (discovery order: project > user
  /// > builtin, consent already applied). [readSkillPaths] are the
  /// SKILL.md paths read in the current window — their pins win the
  /// budget (P6: current-session reads > newest > older; a non-read pin
  /// from a later-declared skill outranks an older non-read one).
  ///
  /// Deterministic: identical inputs → identical [pins], [dropped] and
  /// rendering (P2).
  factory SkillOperativePins.build(
    List<Skill> skills, {
    Set<String> readSkillPaths = const {},
    int? budgetChars,
  }) {
    final byKey = <String, OperativePin>{};
    final order = <String>[];
    for (final skill in skills) {
      for (final line in skill.manifest.operative) {
        if (line.isEmpty) continue;
        final key = sha256.convert(utf8.encode(line)).toString();
        final existing = byKey[key];
        final provenance = PinProvenance(
          skillName: skill.name,
          skillPath: skill.filePath,
        );
        if (existing == null) {
          byKey[key] = OperativePin(line: line, provenance: [provenance]);
          order.add(key);
        } else if (!existing.ownedBy(skill.name)) {
          // E3: duplicate identical line across skills — one pin, dual
          // provenance, single content key.
          byKey[key] = OperativePin(
            line: existing.line,
            provenance: [...existing.provenance, provenance],
          );
        }
      }
    }
    final all = [for (final key in order) byKey[key]!];
    // P6 priority classes: current-session reads first; inside a class,
    // declaration order (first-declared first) and the budget drops from
    // the tail of the LOWEST class (older non-read pins first — the
    // newest-survives semantics of the image cap).
    bool isRead(OperativePin pin) =>
        pin.provenance.any((p) => readSkillPaths.contains(p.skillPath));
    final readPins = [
      for (final pin in all)
        if (isRead(pin)) pin,
    ];
    final otherPins = [
      for (final pin in all)
        if (!isRead(pin)) pin,
    ];
    // Budget over the rendered block: measure the exact carrier text so
    // the cap tracks what the request actually pays.
    final budget =
        budgetChars ?? operativePinConfig.budgetChars ?? defaultPinBudgetChars;
    final dropped = <DroppedPin>[];
    var kept = [...readPins, ...otherPins];
    String render(List<OperativePin> pins) =>
        pinCarrierBlock(SkillOperativePins._(pins, const []));
    while (kept.isNotEmpty && render(kept).length > budget) {
      // Drop the OLDEST non-read pin first (P6 priority: current-session
      // reads > newest > older — kept is first-declared order, so the
      // first non-read entry is the oldest).
      var dropIndex = -1;
      for (var i = 0; i < kept.length; i++) {
        if (!isRead(kept[i])) {
          dropIndex = i;
          break;
        }
      }
      if (dropIndex < 0) dropIndex = 0; // all read: drop the oldest read.
      dropped.add(DroppedPin(pin: kept[dropIndex], reason: 'budget'));
      kept = [...kept]..removeAt(dropIndex);
    }
    // Kept order: read class first (first-declared within the class),
    // then the rest — deterministic regardless of budget pressure.
    final orderedKept = [
      ...readPins.where(kept.contains),
      ...otherPins.where(kept.contains),
    ];
    return SkillOperativePins._(orderedKept, dropped);
  }

  /// Diffs this (current) registry against [previous] (P4/P5): pins whose
  /// content key changed while their owner skill persists are SUPERSEDED;
  /// pins whose owners all vanished (deleted, renamed, consent revoked)
  /// — or whose owner still exists but no longer declares the line — are
  /// DROPPED. Never silent — render the notices.
  ///
  /// Budget drops are deliberately NOT part of the diff: a pin dropped by
  /// the previous window's budget was already reported at drop time (P6)
  /// and is not a lifecycle change — the diff baseline covers kept pins
  /// only.
  OperativePinDiff diff(SkillOperativePins previous) {
    final currentKeys = pinByKey.keys.toSet();
    final currentSkills = {
      for (final pin in pins)
        for (final p in pin.provenance) p.skillName,
    };
    final superseded = <({OperativePin previous, OperativePin current})>[];
    final droppedPins = <OperativePin>[];
    // Round 3: a successor may serve at most ONE supersede — a skill that
    // edited two pinned lines between two windows has TWO distinct
    // new-key pins, and binding both old lines to the first match named
    // the wrong "→" line in one of the notices.
    final claimedSuccessors = <String>{};
    for (final old in previous.pins) {
      if (currentKeys.contains(old.contentKey)) continue;
      if (old.provenance.any((p) => currentSkills.contains(p.skillName))) {
        // The successor must be a CURRENT pin of the same owner skill
        // carrying a NEW content key — never just the skill's first pin
        // (a multi-pin skill's unrelated surviving line must not be named
        // as the replacement, review gh-1409 round 2) and never a pin
        // already claimed by an earlier supersede in this same diff
        // (round 3).
        OperativePin? replacement;
        for (final pin in pins) {
          final isNewKey = !previous.pinByKey.containsKey(pin.contentKey) &&
              !claimedSuccessors.contains(pin.contentKey);
          final sameOwner = pin.provenance.any(
            (p) => old.provenance.any((o) => o.skillName == p.skillName),
          );
          if (isNewKey && sameOwner) {
            replacement = pin;
            claimedSuccessors.add(pin.contentKey);
            break;
          }
        }
        if (replacement != null) {
          superseded.add((previous: old, current: replacement));
        } else {
          droppedPins.add(old);
        }
      } else {
        droppedPins.add(old);
      }
    }
    return OperativePinDiff._(superseded: superseded, dropped: droppedPins);
  }
}

/// The P4/P5 change report between two pin registries.
class OperativePinDiff {
  const OperativePinDiff._({required this.superseded, required this.dropped});

  /// Pins replaced by a new content key of the same owner skill (P5).
  final List<({OperativePin previous, OperativePin current})> superseded;

  /// Pins whose owner skills are gone (P4).
  final List<OperativePin> dropped;

  /// Whether anything changed.
  bool get isEmpty => superseded.isEmpty && dropped.isEmpty;

  /// Human-readable notices, one per change.
  List<String> notices() => [
    for (final change in superseded)
      'skill pin superseded: "${change.previous.line}" (skill '
          '`${change.previous.provenance.first.skillName}`) → '
          '"${change.current.line}"',
    for (final pin in dropped)
      'skill pin dropped: "${pin.line}" — skill '
          '`${pin.provenance.first.skillName}` no longer discoverable or '
          'no longer declares it',
  ];
}

/// Renders one pin line of a pin block: the verbatim line inside inert
/// quotes plus its provenance (E8: the wrapper is harness-fixed, the
/// content is quoted text). [restored] marks the AC3 repair: the pin was
/// absent from the window and this block restores it from the registry.
String _renderPinLine(OperativePin pin, {bool restored = false}) {
  final owners = pin.provenance
      .map((p) => 'skill `${p.skillName}`')
      .join(' + ');
  final restoreNote = restored
      ? ' — restored: dropped from the checkpoint summary'
      : '';
  return '- "${pin.line}" (pinned from $owners$restoreNote)';
}

/// Renders the verbatim pin block (the fold carrier / resume notice
/// body). Empty pins → empty string (E1: no empty carrier block).
/// [restoredKeys] marks pins that were absent from the window and are
/// restored verbatim by this block (AC3 repair — reported, never silent).
String pinCarrierBlock(
  SkillOperativePins registry, {
  Set<String> restoredKeys = const {},
}) {
  if (registry.pins.isEmpty) return '';
  return '$pinBlockOpenTag\n'
      'Operative directives pinned verbatim from skill manifests — follow '
      'them even where the original skill text was compacted away:\n'
      '${registry.pins.map((pin) => _renderPinLine(pin, restored: restoredKeys.contains(pin.contentKey))).join('\n')}\n'
      '$pinBlockCloseTag';
}

/// Renders the summarizer-input block carrying the verbatim-preserve duty
/// (gh-1409 AC3): the pinned lines must appear VERBATIM in the checkpoint
/// output — the prompt is belt; the carrier is the boundary. Empty pins →
/// null (the section is omitted entirely).
String? pinnedOperativePromptBlock(SkillOperativePins registry) {
  if (registry.pins.isEmpty) return null;
  final buffer = StringBuffer(
    'PINNED OPERATIVE LINES (verbatim-preserve duty — every line below is '
    'pinned from a skill manifest and MUST appear VERBATIM, '
    'character-for-character, in the checkpoint output; do not paraphrase, '
    'shorten, translate, or drop any of them):',
  );
  for (final pin in registry.pins) {
    buffer
      ..writeln()
      ..write(_renderPinLine(pin));
  }
  return buffer.toString();
}

/// Whether [message] is a projected renumbering boundary: a classic
/// compaction summary, a branch summary, a structured hidden/checkpoint
/// marker, or the local trim valve note. Carriers render only AFTER such
/// a boundary — pre-boundary the skill body is still in context and a
/// duplicate block would be noise (gh-1409 E6, the image-carrier
/// degradation rule).
bool isPinRenumberingBoundary(Message message) {
  if (message is UserMessage) {
    final content = message.content;
    if (content is String) {
      return content.startsWith(compactionSummaryPrefix) ||
          content.startsWith(branchSummaryPrefix) ||
          content.startsWith(localTrimMarkerPrefix) ||
          isCompactionMarkerText(content);
    }
    return false;
  }
  if (message is ToolResultMessage) {
    // Structured hide keeps the tool_use visible and projects the hidden
    // result as a lone marker text — a renumbering boundary too.
    return message.content.any(
      (block) => block is TextContent && isCompactionMarkerText(block.text),
    );
  }
  return false;
}

/// Scans [messages] for `read` tool calls on skill manifest paths,
/// returning the set of SKILL.md paths read in the current window (the
/// P6 "current-session reads" priority class).
Set<String> readSkillPathsInWindow(List<Message> messages, List<Skill> skills) {
  if (skills.isEmpty || messages.isEmpty) return const {};
  final skillPaths = {for (final skill in skills) skill.filePath};
  final reads = <String>{};
  for (final message in messages) {
    if (message is! AssistantMessage) continue;
    for (final block in message.content) {
      if (block is! ToolCall || block.name != 'read') continue;
      final path = block.arguments['path'];
      if (path is String && skillPaths.contains(path)) reads.add(path);
    }
  }
  return reads;
}

/// Injects the pinned-operative carrier into the OUTGOING request window
/// (never the transcript): ONE verbatim block placed immediately after the
/// LAST renumbering boundary in the window — outside the summarized range
/// (gh-1409 AC2). No boundary in the window → the list is returned
/// unchanged (E6: pre-boundary the body is still in context; no
/// duplication). No pins → unchanged (E1).
///
/// [onNotice] receives every non-silent event: budget drops (P6), P4/P5
/// lifecycle changes (diffed against [lastOperativePinRegistry], the
/// previous window's registry), and repairs (a pin absent from the whole
/// window text — its carrier line is the repair from the registry, AC3).
///
/// Returns the SAME list instance when there is nothing to inject, so
/// pin-free sessions pay nothing.
List<Message> injectOperativePinCarriers(
  List<Message> messages, {
  required List<Skill> skills,
  int? budgetChars,
  void Function(String notice)? onNotice,
}) {
  if (!operativePinConfig.enabled || messages.isEmpty) {
    return messages;
  }
  if (skills.isEmpty) {
    // The everything-gone-at-once corner (round 3): the last batch of pin
    // drops must still be reported (P4) — diff the previous baseline
    // against an empty registry and reset it. The `enabled` kill switch
    // and an empty window stay fully inert by contract (an empty window
    // has nothing to report against).
    _reportAllPinsGone(onNotice);
    return messages;
  }
  final registry = _buildRegistry(
    skills,
    readSkillPathsInWindow(messages, skills),
    budgetChars,
    onNotice,
  );
  if (registry.isEmpty) return messages; // E1: no pins → no carrier.
  final boundary = _lastRenumberingBoundary(messages);
  if (boundary < 0) return messages; // E6: no fold yet → no carrier.
  return _insertCarrier(
    messages,
    registry,
    boundary,
    _repairProbe(messages, registry, onNotice),
  );
}

/// Reports the all-skills-gone turn: the previous baseline (if any pins
/// were live) diffs against [SkillOperativePins.empty] — every kept pin
/// becomes a P4 drop notice — and the baseline resets so the drop batch
/// is reported exactly once (round 3, empty-list corner).
void _reportAllPinsGone(void Function(String notice)? onNotice) {
  final previous = lastOperativePinRegistry;
  if (previous == null || previous.isEmpty) return;
  lastOperativePinRegistry = SkillOperativePins.empty;
  for (final notice in SkillOperativePins.empty.diff(previous).notices()) {
    onNotice?.call(notice);
  }
}

/// Builds the window's pin registry and reports every non-silent event
/// around it: budget drops (P6) and the P4/P5 lifecycle diff against
/// [lastOperativePinRegistry] (supersede/drop — reported even when the
/// new registry ends up empty, e.g. the last pin-owning skill vanished).
SkillOperativePins _buildRegistry(
  List<Skill> skills,
  Set<String> readPaths,
  int? budgetChars,
  void Function(String notice)? onNotice,
) {
  final registry = SkillOperativePins.build(
    skills,
    readSkillPaths: readPaths,
    budgetChars: budgetChars,
  );
  for (final drop in registry.dropped) {
    onNotice?.call(
      'skill pin dropped (budget): "${drop.pin.line}" — pinned from skill '
      '`${drop.pin.provenance.first.skillName}`',
    );
  }
  final previous = lastOperativePinRegistry;
  lastOperativePinRegistry = registry;
  if (previous != null) {
    for (final notice in registry.diff(previous).notices()) {
      onNotice?.call(notice);
    }
  }
  return registry;
}

/// The LAST renumbering boundary in [messages], or -1 when the window has
/// none (E6: the carrier must sit after the compaction boundary — never
/// inside the summarized range).
int _lastRenumberingBoundary(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (isPinRenumberingBoundary(messages[i])) return i;
  }
  return -1;
}

/// The AC3 repair probe: keys of pins absent from the WHOLE window text
/// (body folded AND the checkpoint summary dropped them) — their carrier
/// line is the repair from the registry, reported, never silent. Scans
/// per message with early exit (review gh-1409 round 2, suggestion 6): no
/// window-sized join, each probe pays O(its message), same as the image
/// registry's membership scan.
Set<String> _repairProbe(
  List<Message> messages,
  SkillOperativePins registry,
  void Function(String notice)? onNotice,
) {
  final restoredKeys = <String>{
    for (final pin in registry.pins)
      if (!messages.any((message) => _messageText(message).contains(pin.line)))
        pin.contentKey,
  };
  for (final pin in registry.pins) {
    if (restoredKeys.contains(pin.contentKey)) {
      onNotice?.call(
        'skill pin restored from registry (missing from checkpoint '
        'summary): "${pin.line}" — pinned from skill '
        '`${pin.provenance.first.skillName}`',
      );
    }
  }
  return restoredKeys;
}

/// Anchors the carrier immediately AFTER [boundary]: a user message rides
/// directly after the boundary message; a tool-result boundary extends to
/// the end of its result run first (nothing may sit inside a call/result
/// run — the image-carrier anchor rule). The registry is non-empty here,
/// so the rendered block is non-empty by construction ([pinCarrierBlock]
/// returns empty only for empty pins).
List<Message> _insertCarrier(
  List<Message> messages,
  SkillOperativePins registry,
  int boundary,
  Set<String> restoredKeys,
) {
  var anchor = boundary;
  while (anchor + 1 < messages.length &&
      messages[anchor + 1] is ToolResultMessage &&
      messages[anchor] is ToolResultMessage) {
    anchor++;
  }
  final carrier = UserMessage(
    content: pinCarrierBlock(registry, restoredKeys: restoredKeys),
    timestamp: messages[anchor].timestamp,
  );
  return [
    ...messages.sublist(0, anchor + 1),
    carrier,
    ...messages.sublist(anchor + 1),
  ];
}

/// The plain-text surfaces of [message] (fast-path text extraction for
/// the window-membership probe).
String _messageText(Message message) {
  switch (message) {
    case UserMessage(:final content):
      if (content is String) return content;
      return [
        for (final block in content as List<ContentBlock>)
          if (block is TextContent) block.text,
      ].join();
    case AssistantMessage(:final content):
      return [
        for (final block in content)
          if (block is TextContent) block.text,
      ].join();
    case ToolResultMessage(:final content):
      return [
        for (final block in content)
          if (block is TextContent) block.text,
      ].join();
    default:
      return '';
  }
}
