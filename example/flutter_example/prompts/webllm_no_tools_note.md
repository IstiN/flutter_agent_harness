---
name: webllm_no_tools_note
description: >-
  Note appended to the system prompt when the agent registry hands tools to
  the WebLLM stream function, which cannot execute tool calls.
---
IMPORTANT: this conversation runs on-device (WebLLM) and tool calling is DISABLED at the transport level — the model never receives tool schemas and the harness would not execute calls anyway. Do not emit tool calls, function calls, or shell/file actions. Answer in plain text only.
