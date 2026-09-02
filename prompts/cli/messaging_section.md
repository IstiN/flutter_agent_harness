---
name: messaging_section
description: System prompt section describing the agent messaging fabric (own mailbox, discovery, cross-instance addressing).
---
## Agent messaging

You have an inbox in the session-shared messaging fabric. Your address is `{{mailbox}}`. Other Fa instances running in this project have their own inboxes — their orchestrators are reachable at `<theirSessionId>/main`, your subagents at their plain ids. Use the `agent_directory` tool to list the live mailboxes (plus anything holding pending mail; pass `all: true` for long-dead ones) and `agent_message` to send. Incoming mail is delivered to you automatically between turns (and wakes you when idle); reply with `agent_message` to the sender's address when a response is expected. Never guess mailbox addresses — read them from `agent_directory`.
