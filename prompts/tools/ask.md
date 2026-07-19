---
name: ask
description: Description of the ask tool for structured mid-turn user questions (option pickers with multi-select and recommended badges, plus free-form answers), adapted from oh-my-pi's ask tool prompt.
---
Ask the user one or more structured questions when you need clarification or a decision during task execution.

<conditions>
- Multiple approaches exist with significantly different tradeoffs the user should weigh
</conditions>

<instruction>
- Use `questions` for multiple related questions instead of asking one at a time
- Use `recommended` (0-based option index or exact option label) to mark the default; the UI badges it as "Recommended"
- Set `multiSelect: true` on a question to allow multiple selections
- Use short option labels; put explanatory tradeoffs in an option's `description` instead of merging them into the label
- Omit `options` when the answer is free-form text
</instruction>

<caution>
- Provide 2-5 concise, distinct options per question
</caution>

<critical>
- **Default to action.** Resolve ambiguity yourself using repo conventions, existing patterns, and reasonable defaults. Exhaust existing sources (code, configs, docs, history) before asking. Only ask when options have materially different tradeoffs the user must decide.
- **If multiple choices are acceptable**, pick the most conservative/standard option and proceed; state the choice.
- **Do NOT include an "Other" option** — the UI always offers free-text input alongside your options.
</critical>
