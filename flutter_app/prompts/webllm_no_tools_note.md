---
name: webllm_no_tools_note
description: >-
  Note appended to the WebLLM system prompt when the agent's tool registry
  is empty: the prompt-tools wrapper is a passthrough without tools, so the
  model must be told plainly that it cannot call any.
---
IMPORTANT: this conversation runs on-device (WebLLM) with NO tools registered — no shell, no file access. Do not emit tool calls, function calls, or shell/file actions; there is nothing to execute them. Answer in plain text only.
