"""fa on Agents' Last Exam (ALE-V1) — deployer package + bench tooling.

The deployer half of this directory (``config.py`` / ``deployer.py``) is
vendored verbatim by ``build_run.py stage`` into the ALE checkout as
``ale_run/agents/fa_code/`` (the same in-tree path convention upstream
uses for vendored third-party agents), where the ALE framework imports it
via the fully-qualified harness path ``ale_run.agents.fa_code.deployer.
FaDeployer`` — no ALE fork, no AGENT_REGISTRY edit (gh-1686 recon:
``resolve_agent`` accepts any importable FQN).

``deployer.py`` imports the shared timeout-knob module one level up
(``bench/fa_agent_timeout.py``) with a fallback to the flat staged copy
(``fa_agent_timeout.py`` next to ``deployer.py`` inside ``fa_code/``) so
the same file works in both layouts.

Issue #1686. Design references: bench-harbor.yml (shape), bench/mls_bench
(5h-class budget ladder), bench/harbor_fa/fa_agent.py (fa invocation +
ATIF contract), AGENTS.md "Bench round 3 knobs".
"""
