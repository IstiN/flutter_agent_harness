"""FaConfig — the standalone config dataclass for the fa ALE deployer.

Upstream convention (``ale_run/orchestration/factory.py
_config_class_for``): a deployer in package ``<pkg>`` resolves its config
as ``<pkg>.config.<Stem>Config`` where stem = deployer class name minus
``Deployer``. Vendored layout: ``ale_run/agents/fa_code/config.py`` with
``FaConfig``. There is intentionally NO shared base class (every ALE
agent config is standalone and declares only the knobs its deployer
consumes).

Secrets ride config, never env-whitelisting: ``api_key: ${env:VAR}`` in
the preset yaml resolves host-side at experiment parse (config_loader's
``${env:VAR}`` substitution — KeyError when unset, so a missing key
fails loud before any trial) and travels with the serialized config into
the deployer substrate, the same documented mechanism claude_code uses.

Timeout knobs ride config too — the lifecycle's env passthrough
whitelist is a fixed upstream list our FA_* names are not on. The
deployer maps them onto the same env contract
``bench/fa_agent_timeout.py`` defines (FA_STALL_GAP_SEC /
FA_AGENT_TIMEOUT_ABS_CEILING_SEC / FA_PROGRESS_EXTENSION /
FA_EXTERNAL_CAP_SEC) and resolves the deadline via
``resolve_deadline``. Defaults leave every knob absent — the
no-clock contract: ALE's per-task wall budget
(``lifecycle.py``: task_meta ``timeout_s``) stays the authoritative
kill, and fa never invents a clock the dispatch didn't declare.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import ClassVar


# REG-1 parity (gh-1471): the default resolves the exact 3-field zai
# config bench.yml / bench-harbor.yml hardcode, byte-identical.
_ZAI_DEFAULT_CONFIG = (
    '{"baseUrl":"https://api.z.ai/api/coding/paas/v4",'
    '"model":"glm-5.3-flash","apiKeyEnvVar":"FA_KEY_API_Z_AI_Z_AI"}'
)


@dataclass
class FaConfig:
    """Only what FaDeployer consumes. Defaults = the zai bench identity."""

    name: ClassVar[str] = "fa"

    #: LLM id recorded with the run (sugar: the preset's ``model:`` key).
    model: str = "glm-5.3-flash"

    #: FA_PROVIDER_TYPE for fa's env-provider preconfig.
    provider_type: str = "zai"

    #: FA_PROVIDER_CONFIG JSON (baseUrl/model/apiKeyEnvVar). The key
    #: itself NEVER rides here — it comes only from ``api_key``.
    provider_config: str = _ZAI_DEFAULT_CONFIG

    #: The API key (preset: ``${env:FA_BENCH_ZAI_KEY}``). Injected into
    #: the launched fa process under the config's ``apiKeyEnvVar`` name.
    api_key: str | None = None

    #: fa CLI bundle release asset (fa-linux-x64.tar.gz) fetched in-VM at
    #: install(). The sandbox VM is where the deployer runs; there is no
    #: host-to-VM file channel for non-task files, so the bundle arrives
    #: by URL — the repo's published release asset, pinned by sha256.
    bundle_url: str = (
        "https://github.com/IstiN/flutter_agent_harness/releases/"
        "download/v1.0.698/fa-linux-x64.tar.gz"
    )
    #: Integrity pin verified right after download (None = unverified,
    #: only for throwaway debugging — CI always pins).
    bundle_sha256: str | None = None

    #: ── adapter timeout knobs (AGENTS.md "Bench round 3 knobs") ──
    #: Absent-by-default trio: ALE's wall budget owns the kill. A
    #: dispatch that declares knobs gets the same stall/ceiling watch
    #: the harbor adapter runs, folded with the optional dispatch-level
    #: external cap via min(). stall_gap_sec/abs_ceiling_sec REQUIRE
    #: progress_extension (without it the knob module's effective cap
    #: collapses to the flat base — the deployer fails loud on that
    #: half-declared watch instead of handing fa a surprise clock).
    progress_extension: bool = False
    stall_gap_sec: float | None = None
    abs_ceiling_sec: float | None = None
    external_cap_sec: float | None = None

    #: Bundle install prefix inside the VM (harbor adapter convention:
    #: /opt/fa with bin/fah, shimmed as `fa` on PATH).
    install_prefix: str = "/opt/fa"

    #: fa MCP tool-call ceiling. ALE GUI actions (screenshot, click,
    #: drag on a 1024x768 Xvfb desktop) can be slow; the fa default
    #: (60000) is tuned for local dev tools, not computer-use round
    #: trips. Exposed for ALE-tuned dispatches.
    mcp_tool_call_timeout_ms: int = 120000
