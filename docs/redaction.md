# Secret redaction (layered pipeline)

Layered detection + masking of secret-shaped content in everything that
flows through the agent — tool results, the provider context, and user
prompts — so secrets never reach the LLM, the transcript, or the session
JSONL (issue #24).

Two systems run side by side:

- The **legacy exact-value `SecretRedactor`** masks values it was told
  about by name (provider API keys, `request_secret` grants). Attached
  lazily on runtime tokens (CLI) or at construction (app).
- The **layered `RedactionPipeline`** catches secret-shaped content it was
  never told about: vendor tokens, PEM/ASN.1 blobs, credential-file paths
  and whole-file dumps, connection strings, high-entropy strings,
  private-key contexts. Attach point: `attachRedactionPipeline`.

## Layers

Priority order (higher wins overlaps): `registered` (exact values) →
`path` (credential files) → `credential` (DOM form-field values) →
`vendor` (GitHub/AWS/OpenAI/JWT/…) → `prefix` (`indexOf` pre-screen
feeding vendor) → `pem` → `asn1` → `connection` → `context`
(password/secret key names) → `entropy` → `pii` (off by
default). Output markers are `[REDACTED:<kind>]`, idempotent, and
line-count preserving. Allowlisted shapes (Git SHAs, UUIDs) and
`data:` base64 URLs survive.

## Config (`redact:` in `~/.fah/config.yaml` or project `.fah/config.yaml`)

```yaml
redact:
  enabled: true        # master switch (default true)
  blockMode: false     # ALSO deny read/bash touching credential files
  layers:
    pii: true          # per-layer overrides
    entropy: false
  allowlist:           # regexes whose full match suppress redaction
    - '[0-9a-f]{40}'
  toolAllow: [read]    # hook-level policy: only these tools get redacted
  toolDeny: [write]    # never redacted (wins over toolAllow)
```

Defaults are never written back to the config file. `enabled: false`
keeps the pipeline unattached entirely.

## Semantics

- **Session safety (AC1)**: tool results are masked by the
  `afterToolCall` hook BEFORE they are persisted — the JSONL never sees
  the raw secret.
- **Write-side exclusion (AC7)**: `write`, `edit`, `checkpoint`, and MCP
  write-ish tool outputs are NEVER redacted — that text is code the model
  produced; key-shaped strings in it are the deliverable. An exception to
  the exclusion stays an exception.
- **blockMode (AC6)**: `read`/`bash` calls that would touch a credential
  file (`.env`, `id_rsa`, `.aws/credentials`, `.npmrc`, `.netrc`,
  `.docker/config.json`, `.pem`/`.key`) are denied with a human reason.
  Mask mode (default) only masks the result.
- **Prompt entry (AC8)**: user prompt text is masked before it reaches
  the agent/session (`redactPrompt`, counted under `user_input`).
- **Registered secrets**: every value registered into the legacy
  redactor (catalog keys, role secrets, keychain preload, `/provider`
  tokens, `request_secret` grants) also feeds the pipeline's
  `registered` layer.

## CLI

`/redact` — status (on/off, blockMode, registered secret count, session
match count). Subcommands: `on|off`, `block on|off`, `stats` (matches per
layer and per tool), `layers` (per-layer toggle state).
