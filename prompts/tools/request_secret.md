---
name: request_secret
description: Description of the request_secret tool for asking the user for a missing credential (API key, token) through the host's secure key prompt, which stores it as a secret env var instead of exposing it in chat text.
---
Ask the user for a credential (API key, token, password) that you need and that is not available yet.

<conditions>
- A command or call fails because a credential is missing, or the task clearly requires one
- The secret is NOT already in the "Available secret env vars" list
</conditions>

<instruction>
- Set `name` to the conventional env var name for the service (GITHUB_TOKEN, OPENAI_API_KEY, NPM_TOKEN...); the user can adjust it before saving
- Explain in `reason` what you need the credential for — the user sees this text
- After the user saves it, reference it as $NAME in shell commands; the value itself never enters the conversation
</instruction>

<critical>
- NEVER ask the user to paste a secret into the chat as plain text — always use this tool, so the value is stored securely and redacted from the transcript
- NEVER print, echo, or write the secret value after it is saved
- If the user declines, do not immediately retry the same request; find another way or explain the blocker
</critical>
