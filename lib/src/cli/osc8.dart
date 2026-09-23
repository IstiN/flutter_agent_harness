/// OSC 8 hyperlink marking (issue #808): `[text](url)` links and bare
/// URLs become terminal hyperlinks — `ESC ]8;;url BEL text ESC ]8;; BEL` —
/// when the mode and the session profile allow, plain text otherwise.
///
/// Terminator: BEL (`\x07`), omp's choice — the ST form (`ESC \`)'s
/// backslash collides with marked's codespan escaping (omp
/// markdown.ts normalizeOsc8); well-formed ST input is normalized to BEL
/// by [stripOsc8]'s regex, which accepts both.
///
/// Mode (umbrella #802): `off` never wraps; `always` always wraps;
/// `auto` (the default) wraps only when the resolved color profile is
/// truecolor or 256-color — legacy 16-color and styling-off terminals
/// render plain text. Resolution happens once at CLI boot
/// ([resolveOsc8Links]); the globals mirror the `tuiChromeEnabled` kill-
/// switch pattern so tests set them directly and the pure formatter stays
/// side-effect free.
library;

import 'tui_theme.dart' show ColorProfile;

/// How hyperlinks may be emitted (the `tui.links` config key).
enum Osc8LinksMode { off, auto, always }

/// Boot-resolved globals (see the library comment). Defaults keep any
/// host that never resolves them on today's plain-text behavior.
Osc8LinksMode osc8LinksMode = Osc8LinksMode.auto;

/// Whether the session profile can carry OSC 8 (truecolor / 256-color).
/// Set together with [osc8LinksMode] at boot; tests set it directly.
bool osc8ProfileUsable = false;

/// Resolves both globals from the parsed `tui.links` value (null/unknown
/// → auto) and the session profile. Pure: writes nothing but the globals.
void resolveOsc8Links(String? configured, ColorProfile? profile) {
  osc8LinksMode = switch (configured) {
    'off' => Osc8LinksMode.off,
    'always' => Osc8LinksMode.always,
    _ => Osc8LinksMode.auto,
  };
  osc8ProfileUsable = switch (profile) {
    null => false,
    ColorProfile.trueColor || ColorProfile.ansi256 => true,
    _ => false,
  };
}

/// Whether [osc8Wrap] emits escape sequences right now.
bool get osc8Active => switch (osc8LinksMode) {
      Osc8LinksMode.off => false,
      Osc8LinksMode.always => true,
      Osc8LinksMode.auto => osc8ProfileUsable,
    };

/// Wraps [text] in an OSC 8 hyperlink to [url], or returns [text] unchanged
/// when hyperlinks are off. The url is sanitized (ESC/BEL stripped — omp
/// does the same) so the payload can never break out of the sequence.
String osc8Wrap(String text, String url) {
  if (!osc8Active || url.isEmpty) return text;
  final safe =
      url.replaceAll('\x1b', '').replaceAll('\x07', '');
  if (safe.isEmpty) return text;
  return '\x1b]8;;$safe\x07$text\x1b]8;;\x07';
}

/// Strips every OSC 8 sequence (BEL- or ST-terminated), keeping the visible
/// text. Shared by the width walker and the plain-render path.
String stripOsc8(String text) =>
    text.contains('\x1b]') ? text.replaceAll(_osc8SequenceRe, '') : text;

/// An OSC 8 span: `ESC ]8;params;url` closed by BEL or ST. Only `]8;`
/// spans are matched — other OSC sequences are not emitted by this module.
final _osc8SequenceRe = RegExp(r'\x1b\]8;[^\x07\x1b]*(?:\x07|\x1b\\)');
