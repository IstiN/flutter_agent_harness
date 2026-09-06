// Prompt-injection defense for the scripting tools (issue #30 v2.1).
//
// [InjectionValidator] refuses to run agent-authored JavaScript on pages
// shaped like credential collectors (login/SSO/OAuth) and refuses
// keystroke-capture code everywhere. The page shape comes from a
// [PageClassifier] seam so the surface stays pure Dart — the host probes
// the DOM, the validator only reasons about the answer.
//
// Honest v2.1 limitation: every credential-shape disjunct needs
// [PageClassification.hasPasswordField], a DOM fact, and the shipped
// default [urlHeuristicClassifier] is URL-only — so with the default the
// `login_form` refusal NEVER fires. Keystroke-capture refusal is
// unaffected (pure code-shape matching). Hosts wanting credential-shape
// defense must supply a DOM-probing classifier.
//
// Pure Dart — compiled into the MV3 service worker: no dart:io, no
// js_interop.
library;

/// The shape of the page a script is about to run on.
///
/// The classifier fills this from the live DOM where it can; the default
/// [urlHeuristicClassifier] can only fill [loginShapedUrl] and leaves the
/// DOM booleans false (a URL alone never proves a credential form).
final class PageClassification {
  const PageClassification({
    required this.hasPasswordField,
    required this.hasFormSubmit,
    required this.loginShapedUrl,
    required this.url,
  });

  /// The page (or any frame the classifier saw) has an `<input
  /// type="password">`.
  final bool hasPasswordField;

  /// The page has a form with a submit control.
  final bool hasFormSubmit;

  /// The URL itself looks like a login/SSO/OAuth endpoint.
  final bool loginShapedUrl;

  /// The page URL the classification was made for.
  final String url;
}

/// Classifies the page [tabId] (currently at [url]) before an injection.
///
/// The seam the tool surface calls before every MAIN/ISOLATED injection
/// and every cdp_eval; hosts plug a DOM-probing implementation here.
typedef PageClassifier =
    Future<PageClassification> Function(int tabId, String url);

/// URL shapes that suggest a login/SSO/OAuth endpoint. Deliberately broad
/// (`auth` matches `author` too) — by itself it never refuses anything,
/// it only feeds the [PageClassification.loginShapedUrl] half of the
/// credential-page shape, which still needs a password field.
final RegExp loginShapedUrlPattern = RegExp(
  r'/login|signin|sign-in|auth|sso|oauth|account\/login',
  caseSensitive: false,
);

/// The default [PageClassifier]: URL heuristic only. Both DOM booleans
/// are false because a static URL cannot prove a credential form.
Future<PageClassification> urlHeuristicClassifier(int tabId, String url) async {
  return PageClassification(
    hasPasswordField: false,
    hasFormSubmit: false,
    loginShapedUrl: loginShapedUrlPattern.hasMatch(url),
    url: url,
  );
}

/// One injection-validation outcome. [allowed] decisions carry no code;
/// refusals carry a stable machine code for the tool error.
final class InjectionDecision {
  const InjectionDecision.allowed() : code = null, message = null;

  const InjectionDecision.refused(this.code, this.message);

  /// Stable refusal code (`'login_form'`, `'keylogger_shaped'`), null
  /// when allowed.
  final String? code;

  /// Human/model-facing explanation of the refusal, null when allowed.
  final String? message;

  bool get allowed => code == null;
}

/// Global keyboard-listener shapes: the signature of keystroke capture.
/// Assignment form (`el.onkeydown = ...`) and the addEventListener /
/// `document.onkey…` / `window.onkey…` spellings all count.
final List<RegExp> keyCapturePatterns = [
  RegExp(r"""addEventListener\s*\(\s*['"]key(down|press|up)"""),
  RegExp(r'document\.onkey'),
  RegExp(r'window\.onkey'),
  RegExp(r'onkeydown\s*='),
];

/// Refuses agent scripts on credential-shaped pages and keystroke-capture
/// code anywhere. Pure and stateless — one check per call site.
final class InjectionValidator {
  const InjectionValidator();

  /// Validates [code] against the [page] it would run on.
  ///
  /// Login/SSO/OAuth-shaped pages (password field + form submit, or a
  /// login-shaped URL + password field) refuse with `'login_form'`:
  /// page content there can rewrite the injected script into a credential
  /// harvester, so no scripting is worth the risk. Keystroke-capture code
  /// refuses with `'keylogger_shaped'` regardless of page. Everything
  /// else — including `beforeunload` listeners with value capture, which
  /// is not credential-shaped — passes.
  InjectionDecision validateJs({
    required String code,
    required PageClassification page,
  }) {
    for (final pattern in keyCapturePatterns) {
      if (pattern.hasMatch(code)) {
        return const InjectionDecision.refused(
          'keylogger_shaped',
          'code registers a global keyboard listener — the shape of '
              'keystroke capture; refused on every page',
        );
      }
    }
    final credentialShaped =
        (page.hasPasswordField && page.hasFormSubmit) ||
        (page.loginShapedUrl && page.hasPasswordField);
    if (credentialShaped) {
      return InjectionDecision.refused(
        'login_form',
        'page ${page.url} is credential-shaped (password field'
            '${page.hasFormSubmit ? ' + form submit' : ''}); injecting '
            'JavaScript there is refused because page content could '
            'rewrite the script into a credential harvest',
      );
    }
    return const InjectionDecision.allowed();
  }

  /// CSS cannot execute, so nothing refuses today; kept as a passthrough
  /// for symmetry with [validateJs] and a place for future CSS policy.
  InjectionDecision validateCss(String css) =>
      const InjectionDecision.allowed();
}
