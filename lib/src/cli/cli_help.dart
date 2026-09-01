/// The `fa --help` text: a complete, grouped reference of every invocation
/// shape, flag, provider, config section, and REPL command the CLI actually
/// supports. Plain grep-friendly text (like git help); kept in pure Dart so
/// tests can guard that it stays in sync with the flags `parseCliArgs`
/// accepts and the features the binary wires.
///
/// This is terminal output, not an LLM prompt — it deliberately does NOT
/// live under `prompts/` (see AGENTS.md).
library;

/// The full `--help` output printed by the `fa` executable. [version] is
/// threaded through from the executable (`_version` in `bin/fah.dart`) — the
/// single source of truth shared with `--version` — and rendered in the
/// header line.
String cliHelpText(String version) =>
    '''
fa — flutter_agent_harness CLI agent v$version${_buildFilterNote()}

USAGE
  fa [options]                          interactive REPL
  fa [options] "fix the tests"          headless: run one prompt and exit
  fa [options] -p "fix the tests"       headless, prompt used verbatim
  fa [options] notes.md "summarize"     headless, existing file as prompt source

INVOCATION
  Interactive REPL: no prompt arguments. Type a message to run the agent;
  /commands manage the session (see REPL COMMANDS below). While a run is
  streaming, typed input steers the agent; Ctrl-C aborts the run, Ctrl-C
  while idle exits.

  Headless mode: a prompt via positional arguments (joined with spaces) or
  -p/--prompt runs a single non-interactive prompt and exits. The response
  streams to stdout; tool indicators and notices go to stderr (stdout stays
  pipeable). Nothing is ever prompted interactively — approval/ask prompts
  are denied per the non-interactive rule. The session persists like a
  normal REPL turn (including auto-compaction). Exit codes: 0 ok,
  1 provider error, 130 aborted (Ctrl-C).

  File-as-prompt: a first positional naming an EXISTING file is the prompt
  source — text files (.md, .markdown, .txt) are inlined as the prompt, any
  other file is attached as a path reference the agent can open with its
  tools; trailing text appends as the instruction. A path that does not
  exist is treated as plain prompt text. -p text is always used verbatim
  (never a file).

OPTIONS
  -p, --prompt <text>          Run a single headless prompt and exit
  --model <id>                 Model id (default per provider, see PROVIDERS)
  --provider <kind>            openai-completions | anthropic | google | dial
                               | minimax | zai
                               (default: openai-completions, via OpenRouter)
  --base-url <url>             Override the provider API base URL
  --mode <name>                Initial mode: code | architect | review
  --system-prompt <text>       Override the system prompt for this run
                               (verbatim; beats the config prompts: section
                               and the built-in mode prompts)
  --system-prompt-file <path>  Same, but read from a Markdown file
                               (frontmatter stripped; ~ expanded; relative to
                               the current directory). Cannot be combined
                               with --system-prompt.
  --vision-model <id>          Enable the inspect_image tool with this vision
                               model (e.g. gpt-4o, openai/gpt-4o)
  --vision-base-url <url>      Override the vision provider base URL
  --transcribe-model <id>      Enable the transcribe_audio tool with this
                               transcription model (default: whisper-1)
  --transcribe-base-url <url>  Override the transcription endpoint base URL
  --plugin <name>              Enable a built-in plugin (repeatable):
                               inspect_image, transcribe_audio
  --prompt-template-dir <path> Add a prompt template directory (repeatable)
  --cwd <dir>                  Working directory (default: current directory)
  --session-root <dir>         Session storage root (default: ~/.fah/sessions;
                               macOS: ~/Library/Group Containers/group.dev.fa1.shared/fa/sessions)
  --session <name>             Resume or create a named session for this cwd
  --help, -h                   Show this help
  --version                    Print the version

QUICK COMMANDS
  update                       Download the latest release binary and swap
                               it in (pub-global installs re-activate)
  uninstall                    Remove the binary and its PATH entry after a
                               y/N confirmation; ~/.fah (sessions, config)
                               is kept unless a second confirmation says yes

PROVIDERS AND API KEYS${_providerSectionSuffix()}
  openai-completions (default)
      Key: OPENROUTER_API_KEY (fallback OPENAI_API_KEY)
      Default model: anthropic/claude-sonnet-4 @ https://openrouter.ai/api/v1
  anthropic
      Key: ANTHROPIC_API_KEY
      Default model: claude-sonnet-4-5 @ https://api.anthropic.com
  google
      Key: GOOGLE_API_KEY
      Default model: gemini-2.5-pro @
      https://generativelanguage.googleapis.com/v1beta
  dial
      Key: DIAL_API_KEY (sent as the Api-Key header, not Bearer)
      EPAM DIAL Core: chat at {baseUrl}/openai/deployments/<model>/chat/
      completions; --model names the deployment (required, no default).
      Default endpoint https://ai-proxy.lab.epam.com; override with
      --base-url. DIAL_API_VERSION optionally appends ?api-version=<value>.
  zai
      Key: ZAI_API_KEY (fallback Z_AI_API_KEY)
      Default model: glm-5.3 @ https://api.z.ai/api/coding/paas/v4
      (the CODING plan endpoint; an env key activates it out of the box
      when no provider is configured).

  Custom endpoints: --provider openai-completions --base-url <url> talks to
  any OpenAI-compatible server — a local Ollama (http://localhost:11434/v1),
  Ollama Cloud (https://ollama.com/v1), vLLM, etc. Pick the model with
  --model. The API key is optional there: local servers (llama.cpp, Ollama,
  LM Studio) need none, and no Authorization header is sent without one.

  Env preconfig (Docker/headless): FA_PROVIDER_TYPE + FA_PROVIDER_CONFIG
  boot a declared provider with no saved config, and the declaration is
  the session default for every model role (default/smol/slow/plan) —
  the same selection a /provider switch makes:
      FA_PROVIDER_TYPE=zai
      FA_PROVIDER_CONFIG='{"baseUrl":"https://api.z.ai/api/coding/paas/v4",
        "model":"glm-5.3","apiKeyEnvVar":"ZAI_API_KEY"}'
      ZAI_API_KEY=sk-...
  baseUrl and model are required (no catalog defaults — a missing field
  fails at boot). apiKeyEnvVar is optional: declared, the named var (or
  its _BASE64 twin) must hold the key; omitted, the provider boots
  keyless and the spec's usual env names are never probed. Every text
  value has a base64 twin (FA_PROVIDER_CONFIG_BASE64,
  <apiKeyEnvVar>_BASE64) for platforms that mangle special characters:
  the plain value wins when both carry the same value; mismatched or
  malformed twins fail loud at boot.

  In the REPL, /provider [name] [baseUrl] [token] switches the provider and
  endpoint live (openrouter, kimi, openai, anthropic, google, codemie, dial,
  minimax, zai, or a saved custom provider by name): without a token the key
  resolves per below; an explicit
  token is persisted in the OS secure store when one is available — under an
  endpoint-scoped name (FA_KEY_<HOST>, the same scheme custom providers
  use), never the shared env name, so a key written for one endpoint cannot
  be picked up by another. /provider custom starts a guided setup: pick the
  api type from a menu (openai-like / anthropic-like / google-like), enter
  the base URL (Enter applies the shown default), optionally a key, then the
  model — from the endpoint's /models list when it has one, typed manually
  otherwise. The provider is saved (customProviders: in ~/.fah/config.yaml)
  and listed first in the /provider picker, remembering its last-used
  model; selecting a saved provider in /provider opens its Edit/Delete
  picker.
  /provider openrouter oauth opens a browser PKCE flow that mints a user-
  controlled OpenRouter API key and stores it as OPENROUTER_API_KEY; add
  `headless` for terminals without a browser (copy the URL, paste the code).

  Secure key storage: keys resolve in order — a genuine environment value
  of the catalog env names, then the endpoint-scoped secure-store entry
  (FA_KEY_<HOST>, or FA_KEY_<HOST>_<NAME> for a saved custom provider —
  several accounts on the same endpoint keep separate keys), then legacy
  env-name store entries written by older versions. The store is the macOS
  Keychain, Secret Service on Linux (secret-tool/libsecret; unavailable on
  headless hosts), or the Windows Credential Locker. /key shows per key
  where the value comes from (never the values), /key set <NAME> <value>
  stores, /key delete <NAME> removes. Rotation stacks (NAME_2, ...) stay
  env-only.

  Vision: VISION_API_KEY for --vision-model (defaults to the main key).
  Transcription: TRANSCRIBE_API_KEY for --transcribe-model (defaults to the
  main key).
  Web search: keyless DuckDuckGo works out of the box; BRAVE_API_KEY and
  TAVILY_API_KEY add those providers to the search chain.
  Key rotation: stack numbered suffixes on any key (OPENROUTER_API_KEY_2,
  OPENROUTER_API_KEY_3, ...) — the model-roles resolver rotates them on
  rate limits.

MODEL ROLES (~/.fah/config.yaml)
  The optional roles: section pins intent-based roles (default, smol, slow,
  plan) to ordered fallback chains. On 429/quota the run rotates stacked
  keys for free, retries the entry with backoff, then fails over to the next
  chain entry — every step announced, never silent. The smol role backs
  compaction summaries; modelOverrides: scopes chains to path prefixes;
  retry: tunes the backoff policy. Example:

    roles:
      default:
        - openrouter/anthropic/claude-sonnet-4
        - provider: openai
          model: gpt-4o
          apiKeyName: OPENAI_API_KEY   # optional; also baseUrl,
                                       # contextWindow, maxTokens
      smol:
        - openrouter/openai/gpt-4o-mini
    modelOverrides:
      - path: ~/work/acme
        roles:
          plan:
            - anthropic/claude-opus-4-5
    retry:
      retriesPerEntry: 2               # + baseDelayMs, maxBackoffMs,
                                       #   maxWaitMs, keyBackoffMs

  With no roles: section the CLI runs the single --provider/--model pair.
  /model lists the resolved roles and chains.

MODELS CONFIG (~/.fah/config.yaml)
  The optional models: section carries per-slot media model overrides (the
  same slot schema the Flutter app uses — a slot without an override falls
  back to the main connection) and named custom model definitions:

    models:
      slots:                       # imageGeneration, audioTts,
                                   # musicGeneration, videoGeneration,
                                   # vision, transcription
        vision:
          providerKind: openai-completions
          baseUrl: https://api.openai.com/v1
          modelId: gpt-4o
          apiKeyName: OPENAI_API_KEY   # optional; key NAME, never the value
      custom:                      # /model <name> switch targets
        fast:
          provider: openai             # catalog provider name
          baseUrl: https://api.openai.com/v1
          model: gpt-4o-mini
          contextWindow: 128000        # optional; also maxTokens, input

  In the REPL, /models config shows the effective configuration,
  /models set <slot> <model> [baseUrl] pins a media slot (the base URL
  defaults to the main connection's endpoint), /models remove <slot>
  returns a slot to the main connection — both persisted into the models:
  section. /model <custom-name> switches provider, endpoint, and model in
  one step using a models.custom definition.

PROMPTS
  Modes: the system prompt comes from the active mode — code (default),
  architect, review. Select with --mode or switch live with /mode, /code,
  /architect, /review.

  Prompt templates: Markdown files in .fah/prompts/, ~/.fah/prompts/, and
  every --prompt-template-dir become /name commands; /name args expand \$1,
  \$@, \$ARGUMENTS, \${1:-default}, \${@:2} in the template body.

  Prompt overrides: the prompts: section of ~/.fah/config.yaml replaces
  built-in prompts by name. A value is a FILE when it starts with /, ~/,
  ./, ../ or ends in .md/.markdown/.txt (~ expands, relative paths resolve
  against --cwd, frontmatter stripped, missing files are a hard error);
  anything else is inline text. Names:

    system                    alias for cli/mode_code
    cli/mode_code             base CLI system prompt (default mode)
    cli/mode_architect        architect mode system prompt
    cli/mode_review           review mode system prompt
    compaction/summary_system system prompt of the summarization call
    compaction/summary        first-summary instructions
    compaction/summary_update summary-update instructions
    compaction/turn_prefix    split-turn prefix instructions

  Example:

    prompts:
      system: ~/prompts/my_system.md
      cli/mode_review: "You are a terse reviewer."
      compaction/summary: ./prompts/summary.md

  Resolution order: --system-prompt[-file] flag > config prompts: override
  > built-in prompt. Mode prompts may use {{cwd}} (substituted with the
  working directory) — overrides too.

APPROVALS
  Tool calls are gated by capability tier (read < write < exec). Modes:
    always-ask   prompt for every write/exec call
    write        auto-approve read+write, prompt for exec
    yolo         auto-approve everything (default) — except critical bash
                 patterns (e.g. rm -rf /, force pushes), which still prompt
    unattended   auto-approve everything, critical patterns included — never
                 asks; for runs without a user present (overnight/automation)
  /approval [mode] shows or sets the mode (persisted); /allow <tool>
  always-allows one tool (persisted). Prompt answers: y = once, n = deny,
  a = always for that tool. Non-interactive runs (headless or piped stdin)
  cannot prompt: prompt-policy calls are denied with a reason.

SESSIONS AND COMPACTION
  Every run (REPL or headless) appends to a JSONL session under the session
  root (--session-root, default ~/.fah/sessions; macOS: ~/Library/Group
  Containers/group.dev.fa1.shared/fa/sessions), laid out per working
  directory. Start with --session <name> or use /session, /session-new,
  /rename-session, and /sessions to manage named sessions. /reset starts a
  fresh session; /stats shows token/cost totals.

  When the context nears the model's window the history is auto-compacted:
  older messages are summarized (via the smol role when configured) and
  replaced by the summary; /compact does it on demand. Compaction prompts
  are overridable (see PROMPTS).

  The checkpoint and rewind tools let the agent mark the session before an
  exploratory detour and later prune the transcript back to the mark,
  keeping a report of what it learned.

  TTSR stream rules abort a streaming run on regex matches in the model
  output, inject the rule body as a hidden reminder, and retry. Rules come
  from the ttsr: section of ~/.fah/config.yaml and from .fah/rules.yaml in
  the project (project rules win name clashes):

    ttsr:
      enabled: true                    # contextMode, repeatMode, repeatGap,
                                       # maxInjectionsPerTurn, retryDelayMs
      rules:
        - name: no-console-log
          pattern: "console\\\\.log\\\\("
          body: Do not use console.log; use the project logger.

TOOLS
  read             read files (line ranges, hashline tags, zip/tar members,
                   SQLite db:table targets)
  write            write whole files
  edit             exact-match edits or hashline patches
  ls               list directories
  bash             run shell commands (exec tier; critical patterns prompt)
  web_search       search the web (DuckDuckGo keyless; Brave/Tavily keyed)
  web_fetch        fetch a page rendered as Markdown
  lsp              diagnostics/definition/references/rename via language
                   servers (project server map: .fah/lsp.json)
  task             spawn subagents — parallel batches, or background jobs
                   (background: true) whose results re-enter the conversation
                   as async-result messages; monitor with /tasks
  ask              ask the user structured questions mid-run
  checkpoint       mark the session for a later rewind
  rewind           prune the transcript back to a checkpoint
  inspect_image    analyze images (via --vision-model or the plugin)
  transcribe_audio transcribe audio (via --transcribe-model or the plugin)

PLUGINS
  --plugin <name> enables a built-in plugin (repeatable): inspect_image,
  transcribe_audio. The project file .fah/packages.yaml enables and
  configures plugins per project (same built-in names).

REPL COMMANDS
  /exit              quit
  /reset             start a new session
  /compact           summarize history to free context
  /stats             show token and cost totals
  /tasks [cancel <id>] list (or cancel) background agents and shell jobs
  /skills            skills menu (TUI): pick a skill to prefill /skill:<name>
                     in the input, manage third-party access, or import; in
                     line mode lists skills. /skill:<name> [args] invokes one
                     (a bare /<name> works too); /skills reload re-scans,
                     /skills access [ask|granted|denied] manages third-party
                     consent, /skills import copies third-party skills into
                     .fah/skills
  /agents             list available agent types (built-in + discovered from
                      .fah/.agents/.claude/.github/.codex agents dirs)

SKILLS AND CONTEXT FILES
  Skills are SKILL.md files with YAML frontmatter (name, description),
  discovered from .fah/skills and .agents/skills under the project and the
  home directory (project wins name clashes). Claude Code (.claude/skills,
  .claude/commands), GitHub Copilot (.github/skills) and OpenAI Codex
  (.codex/skills) skills — plus their agent types (.claude/agents,
  .github/agents/*.agent.md, .codex/agents) — are picked up BY DEFAULT
  (opt-out: /skills access denied, or the skills: section in
  ~/.fah/config.yaml; `ask` restores the startup prompt). The / menu,
  /skills and /help list skills alongside commands —
  picking one fills the input with /skill:<name> ready for args. Invocation
  renders \$ARGUMENTS/\$N/\${CLAUDE_*}
  substitutions and !`cmd` shell injections, honors allowed-tools as
  per-turn approval grants, and context: fork runs the skill as a subagent.
  Only metadata enters the system prompt — the agent loads the body with
  the read tool when the task matches (progressive disclosure). AGENTS.md,
  CLAUDE.md, GEMINI.md, GOAL.md and DESIGN.md found from the working
  directory up to the git root (plus ~/.fah/AGENTS.md and GitHub Copilot
  instruction files) are merged into the system prompt, closest last, with
  a 32 KiB leaf-first budget.
  /model [id|?|N]    show model/roles, pick from known models, or switch
                     (a models.custom definition name switches provider,
                     endpoint, and model in one step)
  /models [filter]   list known models for the current provider;
  /models config     show the effective models: configuration (media slot
                     overrides + custom model definitions)
  /models set <slot> <model> [baseUrl]
                     pin a media slot to a model (persisted); the base URL
                     defaults to the main connection's endpoint
  /models remove <slot>
                     drop a media slot override (persisted; the slot falls
                     back to the main connection)
  /model-edit [contextWindow|maxTokens <n>]
                     show or override the active model's token limits for
                     this session (an endpoint-reported window from /models
                     wins over the 200k catalog default; persist per chain
                     via roles yaml contextWindow:/maxTokens:)
  /provider [name] [baseUrl] [token] | custom | openrouter oauth [headless]
                     | chatgpt oauth [headless] | /provider copilot
                     | codemie sso [orgUrl] | dial setup | kimi
                     show or switch the provider/endpoint (token optional,
                     saved to the OS secure store when available); custom is
                     a guided setup that saves the provider (api type, url,
                     key, model); openrouter oauth authenticates via OpenRouter
                     PKCE and stores the resulting key in the secure store;
                     kimi switches to the Kimi Code OpenAI-compatible
                     endpoint (api.kimi.com/coding/v1, key: KIMI_API_KEY);
                     chatgpt oauth offers the saved ChatGPT accounts first
                     (pick one, or add another); a new sign-in stores the
                     OAuth credentials blob in that account's own
                     secure-store slot — access tokens refresh
                     automatically and the rotated blob is re-persisted;
                     codemie sso [orgUrl] signs in to a CodeMie organization
                     via browser SSO (localhost callback) and saves it as a
                     custom provider — the session JWT rides the standard
                     OpenAI-compatible adapter; dial setup runs the guided
                     DIAL Core flow (base URL, Api key, deployment) and
                     saves the org as a dial custom provider
                    /provider copilot connects a GitHub Copilot account via
                    the GitHub device flow (open the shown URL, enter the
                    code; also works headless) or by pasting an existing
                    GitHub token; the account saves as a named entry
                    (copilot-<login>, individual/business/enterprise/custom
                    endpoint) with its token in the secure store under
                    FA_KEY_COPILOT_<NAME> (env FA_COPILOT_CLIENT_ID
                    overrides the device-flow client id); the short-lived
                    Copilot token refreshes automatically
  /providers         alias for /provider
  /key [set|delete]  manage API keys in the OS secure store
  /mode [name]       show or switch the active mode
  /session [name]    show current or switch/create a named session
  /session-new <n>   create a new named session
  /sessions          list all sessions across workspaces
  /resume            switch to the most recent session
  /rename-session <n> rename the current session
  /approval [mode]   show or set tool approval (always-ask|write|yolo|unattended)
  /settings          settings hub: provider, model, approval, keys, MCP
                     (interactive picker in the TUI, summary in line mode)
  /allow [tool]      always-allow a tool (or list them)
  /mcp [list|reload] show MCP servers or reload the config
  /dap [host ...]    DAP hub status, or connect to a hub (agent-to-agent
                     messaging; protocol + server guide: docs/dap.md)
  /code              switch to coding mode
  /architect         switch to architect mode
  /review            switch to review mode
  /help              in-REPL command summary
  !<command>         run a shell command directly
  /<template> args   expand a prompt template (see PROMPTS)
  While a run is streaming, typed input steers the agent; Ctrl-C aborts.

TERMINAL
  The TUI captures the mouse so two-finger scroll scrolls the session
  (the alternate screen has no native scrollback). Select-to-copy still
  works through your terminal's bypass modifier — hold Shift and drag
  in most terminals. FA_TUI_MOUSE=0 hands the mouse back to the
  terminal for always-on native selection instead.
  While a run streams, Enter queues the message (❯ rows above the input);
  ↑ pops the last queued message back for editing. With an empty input
  ↑/↓ browses the submitted-message history (shell-style); PgUp/PgDn
  scrolls the transcript.

CONFIGURATION FILES
  ~/.fah/config.yaml   user preferences: provider, model, baseUrl, mode,
                       approvalMode, allowedTools, plus the prompts:, roles:,
                       modelOverrides:, retry:, ttsr:, and models: sections.
                       Invalid roles/ttsr/prompts/models sections fail
                       loudly at startup.
  .fah/packages.yaml   project plugin configuration
  .fah/rules.yaml      project TTSR stream rules
  .fah/lsp.json        project LSP server map
  .fah/prompts/        project prompt templates (~/.fah/prompts/ for user)
  ~/.dap/              DAP hub state: identity keys, channels.json,
                       config.json (see docs/dap.md)
  ~/.fah/sessions/     session storage root (Linux/Windows)
  ~/Library/Group Containers/group.dev.fa1.shared/fa/sessions/  session storage root (macOS)
''';

/// The build-time provider filter note (empty without `FA_PROVIDERS`).
String _buildFilterNote() {
  const define = String.fromEnvironment('FA_PROVIDERS');
  if (define.isEmpty || define == 'all' || define == '*') return '';
  return '\nbuild: providers restricted to $define (FA_PROVIDERS dart-define)';
}

/// Suffix for the providers section header under a subset build.
String _providerSectionSuffix() {
  const define = String.fromEnvironment('FA_PROVIDERS');
  if (define.isEmpty || define == 'all' || define == '*') return '';
  return ' (enabled in this build: $define)';
}
