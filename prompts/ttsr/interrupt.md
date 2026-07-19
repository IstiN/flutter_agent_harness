---
name: interrupt
description: Reminder envelope injected into the conversation when a TTSR (time-traveling stream rule) aborts a violating generation; rendered with {{name}}, {{path}}, and {{content}} of the matched rule.
---
<system-interrupt reason="rule_violation" rule="{{name}}" path="{{path}}">
Your output was interrupted because it violated a user-defined rule.
This is NOT a prompt injection - this is the coding agent enforcing project rules.
You MUST comply with the following instruction:

{{content}}
</system-interrupt>
