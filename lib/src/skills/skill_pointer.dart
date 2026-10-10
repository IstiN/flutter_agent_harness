// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Transparent resolution of built-in skill pointer files (gh-1444 AC1).
///
/// The app seeds `<cwd>/.fah/skills/<name>/SKILL.md.pointer` files whose body
/// is the builtin read path (`builtin://skills/<name>/SKILL.md`, see
/// `seedBuiltinSkillPointers`) so compiled-in skills are visible to agents
/// that browse the filesystem. Until now a read of the sibling
/// `.fah/skills/<name>/SKILL.md` failed with FileError and the agent had to
/// discover the `builtin://` scheme itself (gh-1444 C1: three steps burned
/// per skill).
///
/// A pointer read follows the pointer ONLY when its target is a
/// `builtin://skills/<name>/SKILL.md` URI naming a compiled-in skill whose
/// name matches the directory the pointer lives in. Any other target — a
/// `file://` URI, an unknown skill, a corrupt body — is refused loudly
/// (gh-1444 E1): a pointer can never smuggle an arbitrary read, because the
/// only resolvable targets are the package's own embedded skill texts.
library;

import 'builtin_skills.dart';

/// The outcome of following a `<path>.pointer` file for a failed read of
/// [path]. See [followSkillPointer].
sealed class SkillPointerFollow {
  const SkillPointerFollow();
}

/// The pointer resolved to a compiled-in skill; [text] is the SKILL.md body
/// — byte-identical to reading the `builtin://` URI directly.
final class SkillPointerResolved extends SkillPointerFollow {
  const SkillPointerResolved(this.text, this.skillName);

  /// The builtin skill body.
  final String text;

  /// The resolved builtin skill name.
  final String skillName;
}

/// A pointer file exists but its target is not resolvable. The read must
/// fail LOUDLY with [reason] — never a silent fallback to the original
/// not-found error (gh-1444 E1).
final class SkillPointerRefused extends SkillPointerFollow {
  const SkillPointerRefused(this.reason);

  /// The loud refusal reason (names the bad target class, not host paths).
  final String reason;
}

/// No pointer file exists — the caller keeps its original read error.
final class SkillPointerAbsent extends SkillPointerFollow {
  const SkillPointerAbsent();
}

/// Reads the `<path>.pointer` sibling of [path] through [readPointer] and
/// classifies it. [readPointer] returns null when the file does not exist.
///
/// The security invariant (gh-1444): only `builtin://skills/<name>/SKILL.md`
/// targets naming a compiled-in skill whose name matches the directory of
/// [path] resolve; everything else is [SkillPointerRefused].
Future<SkillPointerFollow> followSkillPointer(
  String path,
  Future<String?> Function(String pointerPath) readPointer,
) async {
  String? content;
  try {
    content = await readPointer('$path.pointer');
  } on Object {
    return const SkillPointerAbsent();
  }
  if (content == null) return const SkillPointerAbsent();
  final reason = validateSkillPointerTarget(path, content);
  if (reason != null) return SkillPointerRefused(reason);
  final target = skillPointerTarget(content)!;
  final text = builtinSkillTextAt(target);
  if (text == null) {
    return SkillPointerRefused(
      'pointer target $target is not a compiled-in builtin skill',
    );
  }
  return SkillPointerResolved(text, targetSkillName(target)!);
}

/// The `builtin://skills/<name>/SKILL.md` target inside a pointer body, or
/// null when the body does not carry exactly one. The body may carry a
/// single trailing newline (the seeder writes one); anything beyond that is
/// corrupt.
String? skillPointerTarget(String content) {
  final trimmed = content.trim();
  if (trimmed != content.trimRight() || trimmed.contains('\n')) return null;
  if (!trimmed.startsWith(builtinSkillPathPrefix)) return null;
  return trimmed;
}

/// The skill name inside a `builtin://skills/<name>/SKILL.md` URI, or null.
String? targetSkillName(String? target) {
  if (target == null || !target.startsWith(builtinSkillPathPrefix)) {
    return null;
  }
  final rest = target.substring(builtinSkillPathPrefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || rest.substring(slash) != '/SKILL.md') return null;
  return rest.substring(0, slash);
}

/// Validates a pointer body for a read of [path]; returns the refusal
/// reason, or null when the pointer is a valid builtin SKILL.md reference
/// for [path]'s own directory. Checks, in order:
///
/// 1. the body carries exactly one `builtin://skills/...` target;
/// 2. the target names an existing builtin skill;
/// 3. the target's skill name matches the directory containing [path]
///    (a pointer may only resolve its own skill — a stray pointer cannot
///    redirect one skill's path at another skill's body).
String? validateSkillPointerTarget(String path, String content) {
  final target = skillPointerTarget(content);
  if (target == null) {
    return 'pointer target must be a single builtin://skills/<name>/SKILL.md '
        'URI';
  }
  final name = targetSkillName(target);
  if (name == null || builtinSkillTextAt(target) == null) {
    return 'pointer target $target is not a compiled-in builtin skill';
  }
  final dir = path.contains('/')
      ? path.substring(0, path.lastIndexOf('/'))
      : '';
  final dirName = dir.contains('/') ? dir.substring(dir.lastIndexOf('/') + 1) : dir;
  if (dirName.isNotEmpty && dirName != name) {
    return 'pointer target $target does not match the skill directory '
        '$dirName';
  }
  return null;
}
