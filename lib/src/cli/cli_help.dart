/// The `fah --help` text: a complete, grouped reference of every invocation
/// shape, flag, provider, config section, and REPL command the CLI actually
/// supports. Plain grep-friendly text (like git help); kept in pure Dart so
/// tests can guard that it stays in sync with the flags `parseCliArgs`
/// accepts and the features the binary wires.
///
/// This is terminal output, not an LLM prompt — it deliberately does NOT
/// live under `prompts/` (see AGENTS.md).
library;

/// The full `--help` output printed by the `fah` executable. [version] is
/// threaded through from the executable (`_version` in `bin/fah.dart`) — the
/// single source of truth shared with `--version` — and rendered in the
/// header line.
String cliHelpText(String version) =>
    '''
fah — flutter_agent_harness CLI agent v$version

USAGE
  fah [options]                          interactive REPL
  fah [options] "fix the tests"          headless: run one prompt and exit
  fah [options] -p "fix the tests"       headless, prompt used verbatim
  fah [options] notes.md "summarize"     headless, existing file as prompt source

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
  --provider <kind>            openai-completions | anthropic | google
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
  --session-root <dir>         Session storage root (default: ~/.fah/sessions)
  --help, -h                   Show this help
  --version                    Print the version

PROVIDERS AND API KEYS
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

  Custom endpoints: --provider openai-completions --base-url <url> talks to
  any OpenAI-compatible server — a local Ollama (http://localhost:11434/v1),
  Ollama Cloud (https://ollama.com/v1), vLLM, etc. Pick the model with
  --model. The API key is optional there: local servers (llama.cpp, Ollama,
  LM Studio) need none, and no Authorization header is sent without one.

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
  /approval [mode] shows or sets the mode (persisted); /allow <tool>
  always-allows one tool (persisted). Prompt answers: y = once, n = deny,
  a = always for that tool. Non-interactive runs (headless or piped stdin)
  cannot prompt: prompt-policy calls are denied with a reason.

SESSIONS AND COMPACTION
  Every run (REPL or headless) appends to a JSONL session under the session
  root (--session-root, default ~/.fah/sessions), laid out per working
  directory. /reset starts a fresh session; /stats shows token/cost totals.

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
  /model [id|?|N]    show model/roles, pick from known models, or switch
  /models [filter]   list known models for the current provider
  /mode [name]       show or switch the active mode
  /approval [mode]   show or set tool approval (always-ask|write|yolo)
  /allow [tool]      always-allow a tool (or list them)
  /code              switch to coding mode
  /architect         switch to architect mode
  /review            switch to review mode
  /help              in-REPL command summary
  !<command>         run a shell command directly
  /<template> args   expand a prompt template (see PROMPTS)
  While a run is streaming, typed input steers the agent; Ctrl-C aborts.

CONFIGURATION FILES
  ~/.fah/config.yaml   user preferences: provider, model, baseUrl, mode,
                       approvalMode, allowedTools, plus the prompts:, roles:,
                       modelOverrides:, retry:, and ttsr: sections. Invalid
                       roles/ttsr/prompts sections fail loudly at startup.
  .fah/packages.yaml   project plugin configuration
  .fah/rules.yaml      project TTSR stream rules
  .fah/lsp.json        project LSP server map
  .fah/prompts/        project prompt templates (~/.fah/prompts/ for user)
  ~/.fah/sessions/     session storage root
''';
