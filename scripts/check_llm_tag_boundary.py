#!/usr/bin/env python3
"""Live-provider tag-boundary lint (gh-1199 AC2/AC3).

The merge-blocking Quality gate is deterministic-only: every test that
performs live provider I/O must carry the `llm` tag (and is then excluded
from every per-PR leg by `--exclude-tags llm` / shard_files.py
`--exclude-tag llm`). This lint makes the boundary self-enforcing: a test
file that LOOKS live fails the gate, so a new live test can never silently
join the gate again ("raz i navsegda").

Markers (comments stripped before matching; string literals are what
count — same discipline as shard_files.file_has_tag):
    1. a real provider base URL as a string literal
       (openrouter.ai, anthropic.com, api.openai.com, openai.azure.com,
       generativelanguage.googleapis.com, api.groq.com, api.mistral.ai,
       api.deepseek.com, ollama.com, api.x.ai, api.cohere.ai,
       api.together.xyz, api.fireworks.ai, chatgpt.com, api.z.ai)
       → violation in ANY test file: a hardcoded real endpoint is the
       strongest live-I/O signal there is;
    2. a concrete provider credential env key as a string literal
       (OPENAI/OPENROUTER/ANTHROPIC/GOOGLE/GEMINI/OLLAMA/GROQ/MISTRAL/
       DEEPSEEK/GLM/ZAI/CODEGPT/COPILOT/CHATGPT/... + _API_KEY/_TOKEN/
       _SECRET/_CREDENTIALS)
       → violation only in a file tagged `integration` WITHOUT the `llm`
       tag AND without any mock/loopback marker (`MockLlmServer`,
       `127.0.0.1`, `localhost`): injecting a dummy key to drive key
       resolution against a loopback mock is the standard deterministic
       pattern (see fa_cube_headless_helper.scrubbedChildEnv), while a key
       literal in an integration test with no mock in sight means the real
       catalog endpoint is the fallback target. Untagged unit tests are
       out of scope for this marker: they never reach the integration
       gate and key-resolution unit fixtures name keys constantly.

A flagged file that is genuinely deterministic must be pinned in
AUDIT_MOCK below with a one-line justification; the list is part of the
PR review surface (gh-1199 AC3 — every entry is an audited `mock`
classification).

Scanned roots: test/, packages/*/test/, flutter_app/test/,
browser_ext/dart/test/.

Pure stdlib. Exit 0 on clean, 1 on any violation.

Run:
    python3 scripts/check_llm_tag_boundary.py
"""

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shard_files import file_has_tag

# ── gh-1199 AC3 audit: deterministic files pinned after individual review ──
# Every entry is a deliberate classification decision reviewed in the PR;
# keep the justification truthful and short.
AUDIT_MOCK = {
    # gh-760: names CHATGPT_OAUTH_CREDENTIALS to inject a DUMMY value and
    # assert the key gate is passed — the live-wire leg was split into
    # provider_codex_boot_live_test.dart (llm); the remaining legs all
    # repoint baseUrl at the loopback MockLlmServer.
    "test/integration/poisoned_provider_boot_test.dart":
        "dummy creds only; live-wire leg lives in provider_codex_boot_live_test.dart",
}

CREDENTIAL_KEY = re.compile(
    r"['\"]"
    r"(?:OPENAI|OPENROUTER|ANTHROPIC|GOOGLE(?:_AI)?|GEMINI|OLLAMA|GROQ|"
    r"MISTRAL|DEEPSEEK|GLM|ZAI|CODEGPT|COPILOT|CHATGPT|AZURE|COHERE|"
    r"TOGETHER|FIREWORKS|XAI|PERPLEXITY)"
    r"[A-Z0-9_]*(?:API_KEY|TOKEN|SECRET|CREDENTIALS)"
    r"['\"]")

PROVIDER_URL = re.compile(
    r"https://[a-z0-9.-]*(?:"
    r"openrouter\.ai|anthropic\.com|api\.openai\.com|openai\.azure\.com|"
    r"generativelanguage\.googleapis\.com|api\.groq\.com|api\.mistral\.ai|"
    r"api\.deepseek\.com|ollama\.com|api\.x\.ai|api\.cohere\.ai|"
    r"api\.together\.xyz|api\.fireworks\.ai|chatgpt\.com|api\.z\.ai"
    r")")

MOCK_MARKER = re.compile(
    r"MockLlmServer|127\.0\.0\.1|localhost")

SCANS = ["test", *[p for p in glob.glob("packages/*/test")
                   if os.path.isdir(p)],
         "flutter_app/test", "browser_ext/dart/test"]


def strip_comments(source: str) -> str:
    """Code only: the `//` portion of every line drops (a doc comment
    merely MENTIONING a provider URL must not tag anything)."""
    return "\n".join(re.sub(r"//.*", "", line)
                     for line in source.splitlines())


def live_markers(path: str, code: str, integration_tagged: bool) -> list:
    markers = sorted({f"provider URL {m.group(0)}"
                      for m in PROVIDER_URL.finditer(code)})
    if integration_tagged and not MOCK_MARKER.search(code):
        markers += sorted({f"credential key {m.group(0)}"
                           for m in CREDENTIAL_KEY.finditer(code)})
    return markers


def main() -> int:
    violations = []
    classified_live = 0
    classified_mock = 0
    for root in SCANS:
        for path in sorted(glob.glob(os.path.join(root, "**", "*_test.dart"),
                                     recursive=True)):
            norm = path.replace(os.sep, "/")
            try:
                with open(path, encoding="utf-8") as f:
                    code = strip_comments(f.read())
            except OSError:
                continue
            integration_tagged = file_has_tag(path, "integration")
            markers = live_markers(path, code, integration_tagged)
            if not markers:
                continue
            if file_has_tag(path, "llm"):
                classified_live += 1
                continue
            if norm in AUDIT_MOCK:
                classified_mock += 1
                continue
            violations.append((norm, markers))

    for norm, markers in violations:
        print(f"::error::{norm}: live-provider I/O without the llm tag — "
              f"{'; '.join(markers)}. Tag it @Tags([... 'llm']) (leaves the "
              f"deterministic gate) or pin a reviewed justification in "
              f"scripts/check_llm_tag_boundary.py AUDIT_MOCK.",
              file=sys.stderr)

    print(f"llm tag boundary: {classified_live} live (llm-tagged), "
          f"{classified_mock} mock-pinned, {len(violations)} violation(s)")
    if violations:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
