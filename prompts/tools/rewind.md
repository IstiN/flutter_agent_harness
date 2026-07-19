---
name: rewind
description: Description of the rewind tool that ends an active checkpoint by pruning the exploratory context and retaining the agent's report verbatim, ported from oh-my-pi's rewind tool prompt.
---
End an active checkpoint. Rewind context to it, replacing intermediate exploration with your report.

Call immediately after `checkpoint`-started investigative work.

Requirements:
- `report` MUST be concise, factual, and actionable.
- Include key findings, decisions, and any unresolved risks.
- AVOID raw scratch logs unless essential.
- You MUST call this before finishing if a checkpoint is active.

Behavior:
- If no checkpoint is active, this tool errors. If the checkpoint already rewound, continue from the retained report instead of retrying.
- On success, the session rewinds, keeps your report as retained context, and closes the checkpoint.
- A successful rewind is final for that checkpoint; repeat calls error.
