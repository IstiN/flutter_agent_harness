part of 'fah.dart';

/// `fa trajectory <verb> [args]` — read-only trajectory views over a
/// stored session (phase 9). Runs without booting the agent: opens the
/// session store, resolves the session (id / name match / most recent),
/// projects the active branch, and prints through the pure renderers in
/// `trajectory_tui.dart`. Payload goes to stdout, diagnostics to stderr.
/// `tail` re-opens the session file on every poll until interrupted.
Future<int> _runTrajectoryCommand(
  TrajectoryCliCommand command,
  CliArgs args,
) async {
  final io = _TerminalCliIO(headless: true);
  final env = LocalExecutionEnv(cwd: args.cwd ?? Directory.current.path);
  final sessionRoot = args.sessionRoot ?? _defaultSessionRoot();
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
  final sessionId = switch (command.verb) {
    'inspect' when command.positionals.length > 1 => command.positionals[1],
    'inspect' => null,
    _ => command.positionals.isEmpty ? null : command.positionals.first,
  };
  final session = await resolveTrajectorySession(repo, sessionId);
  if (session == null) {
    io.writeln(
      sessionId == null
          ? 'trajectory: no sessions in $sessionRoot'
          : 'trajectory: session not found: $sessionId',
    );
    return 1;
  }
  // Phased open timing (issue #262 AC0): FA_TIMING=1 prints the
  // storage-read+parse, ledger-projection, and render durations to stderr.
  final timing = _envTruthy('FA_TIMING');
  // Issue #1882 AC3: no silent GB-scale operations — view/cost/inspect/
  // export page the whole branch in, so a heavy file says so (exact size
  // + the hygiene escapes) before the scan starts. tail is excluded: it
  // follows the resident window and never primes the head.
  if (command.verb != 'tail') {
    await _warnHeavyTrajectoryFile(io, env, session);
  }
  final parseSw = Stopwatch()..start();
  // gh-1555 W1 (d6): view --at/cost/inspect read the WHOLE branch, but
  // the resolver opened windowed (the only way past the gh-1073
  // full-open backstop). Page the rest in bounded doubling blocks —
  // chunked reads, never the refused materialized whole-file string.
  // The walk is storage read+parse, so it rides the parse phase.
  // `tail` is excluded (trajectoryVerbRecords): it follows the resident
  // window + live-tail ingest and never needs the head — priming would
  // re-raise the gh-1073 refusal for over-the-backstop sessions and
  // un-boundedly materialize the ledger just to print the backfill.
  final records = await trajectoryVerbRecords(session, command.verb);
  parseSw.stop();
  final buildSw = Stopwatch()..start();
  final baseSnapshot = trajectorySnapshotOf(records);
  buildSw.stop();
  final renderSw = Stopwatch()..start();
  var exitCode = 0;
  switch (command.verb) {
    case 'view':
      final snapshot = command.at == null
          ? baseSnapshot
          : trajectorySnapshotAt(records, command.at!);
      if (snapshot == null) {
        io.writeln(
          trajectoryRangeError(command.at!, baseSnapshot.records.length),
        );
        exitCode = 1;
        break;
      }
      exitCode = _printTrajectory(
        io,
        command.json
            ? [
                for (final record in snapshot.records)
                  trajectoryJsonLine(record),
              ]
            : trajectoryLines(snapshot, width: io.columns),
      );
      break;
    case 'cost':
      exitCode = _printTrajectory(io, trajectoryCostLines(baseSnapshot));
      break;
    case 'inspect':
      final snapshot = baseSnapshot;
      final index = int.parse(command.positionals.first);
      final lines = trajectoryInspectLines(snapshot, index);
      if (lines == null) {
        io.writeln(trajectoryRangeError(index, snapshot.records.length));
        exitCode = 1;
        break;
      }
      exitCode = _printTrajectory(
        io,
        command.json && snapshot.records.isNotEmpty
            ? [trajectoryJsonLine(snapshot.records[index - 1])]
            : lines,
      );
      break;
    case 'export':
      // gh-1681 Gap 2: the harbor adapter exports the trial's ATIF
      // trajectory from here after the agent phase — the leaderboard
      // static analysis requires <trial>/agent/trajectory.json.
      exitCode = await _runTrajectoryExport(io, session, baseSnapshot, command);
      break;
    case 'tail':
      // Never returns: follows until interrupted, so the render-stop and
      // timing print below are unreachable on this path (as before).
      return _runTrajectoryTail(io, session, records);
  }
  renderSw.stop();
  if (timing) {
    stderr.writeln(
      'trajectory timing: parse=${parseSw.elapsedMilliseconds}ms '
      'build=${buildSw.elapsedMilliseconds}ms '
      'render=${renderSw.elapsedMilliseconds}ms '
      'total=${parseSw.elapsedMilliseconds + buildSw.elapsedMilliseconds + renderSw.elapsedMilliseconds}ms '
      'records=${records.length}',
    );
  }
  return exitCode;
}

/// Issue #1882 AC3: the headless trajectory read's heavy-file warning —
/// exact size + the hygiene escapes, to stderr (payload goes to stdout).
Future<void> _warnHeavyTrajectoryFile(
  CliIO io,
  FileSystem env,
  Session session,
) async {
  final metadata = await session.getMetadata();
  for (final line in await heavyScanGuardIfHeavy(env, metadata.path)) {
    stderr.writeln(line);
  }
}

/// Prints trajectory payload lines to stdout (newline-terminated).
int _printTrajectory(CliIO io, List<String> lines) {
  for (final line in lines) {
    io.write('$line\n');
  }
  return 0;
}

/// `fa trajectory export` (gh-1681 Gap 2): serializes the whole-ledger
/// snapshot as an ATIF document — the format Harbor Hub stores as a
/// trial's `trajectory_path` and the leaderboard static analysis requires
/// on every rewarded trial. `--output` writes the file (the harbor
/// adapter targets /logs/agent/trajectory.json inside the task
/// container); without it the document goes to stdout. The agent identity
/// rides the CLI's own name/version; the model derives from the first
/// assistant record. An empty ledger is an honest error (ATIF requires
/// at least one step), never a fabricated empty document.
Future<int> _runTrajectoryExport(
  CliIO io,
  Session session,
  TrajectorySnapshot snapshot,
  TrajectoryCliCommand command,
) async {
  final json = exportAtifJson(
    snapshot,
    agentName: 'fa',
    agentVersion: _packageVersion(),
    sessionId: (await session.getMetadata()).id,
  );
  if (json == null) {
    io.writeln('trajectory: nothing to export — the ledger has no records');
    return 1;
  }
  final output = command.output;
  if (output == null) {
    io.write('$json\n');
    return 0;
  }
  try {
    File(output).writeAsStringSync('$json\n');
  } on Object catch (error) {
    io.writeln('trajectory: export write failed: $error');
    return 1;
  }
  return 0;
}

/// The `fa trajectory tail` follower, split out of
/// [_runTrajectoryCommand] to keep the command dispatcher under the
/// CRAP ratchet (CC ≤ 12). Prints the resident-window backfill
/// [records] first, then polls until interrupted.
///
/// gh-1555 W1 rework (review BLOCKING): the poll reads the ORIGINAL
/// [session] and the windowed live-tail ingest picks up the appended
/// suffix on every poll. Re-opening a fresh windowed session each poll
/// returned only the ~200-record resident window, so the tailer never
/// saw the appended records land and went permanently silent for any
/// session larger than the window. The tailer dedupes by record id, so
/// the window's head eviction (records sliding out of residency) cannot
/// re-silence it either.
///
/// Review IMPORTANT (same rework round): `tail` never primes the whole
/// ledger (see [trajectoryVerbRecords]) — this follower is memory-
/// bounded by the resident window at ANY ledger size.
Future<int> _runTrajectoryTail(
  CliIO io,
  Session session,
  List<SessionRecord> records,
) async {
  io.writeln('trajectory: following records — Ctrl+C to stop');
  final tailer = TrajectoryTailer(width: io.columns);
  for (final line in tailer.tail(records)) {
    io.write('$line\n');
  }
  while (true) {
    await Future<void>.delayed(trajectoryPollInterval);
    final List<SessionRecord> fresh;
    try {
      final storage = session.getStorage();
      if (storage is WindowedSessionStorage) {
        await storage.ingestAppended();
      }
      fresh = await session.getBranch();
    } on Object catch (error) {
      io.writeln('trajectory: tail failed: $error');
      return 1;
    }
    for (final line in tailer.tail(fresh)) {
      io.write('$line\n');
    }
  }
}

/// `fa serve --a2a` — mounts the fully-configured agent as an A2A endpoint
/// (Phase 5b). Every `message/send` runs one headless turn against the
/// resolved provider/model; the agent's reply becomes the task artifact.
Future<void> _serveA2a({
  required Model model,
  required String provider,
  required String apiKey,
  required int port,
  required String? token,
  required A2aMailSink? mailSink,
}) async {
  await runA2aServer(
    port: port,
    token: token,
    agentName: 'fa',
    agentDescription:
        'Fa CLI agent (flutter_agent_harness) — $provider/${model.id}',
    mailSink: mailSink,
    runner: (userMessage) async {
      final stream = providerStreamFunction(provider, apiKey)(
        model,
        Context(
          systemPrompt: cliCodeModePrompt.replaceAll(
            '{{cwd}}',
            Directory.current.path,
          ),
          messages: [UserMessage.text(userMessage)],
        ),
      );
      final response = await stream.result;
      if (response.stopReason == StopReason.error ||
          response.stopReason == StopReason.aborted) {
        throw StateError(response.errorMessage ?? 'agent turn failed');
      }
      return response.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join('\n')
          .trim();
    },
  );
}

/// Reads an int flag from the serve positionals (`--port N`).
int _serveFlagInt(List<String> args, String flag, int fallback) {
  final idx = args.indexOf(flag);
  if (idx < 0 || idx + 1 >= args.length) return fallback;
  return int.tryParse(args[idx + 1]) ?? fallback;
}

/// Reads a string flag from the serve positionals (`--token T`).
String? _serveFlagStr(List<String> args, String flag) {
  final idx = args.indexOf(flag);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

/// The messaging fabric of the launch cwd — the same
/// `<sessionRoot>/<cwd slug>/messages` root the CLI boots its agent with,
/// so extension mail lands in the inboxes `/agents` and the attach flows
/// already see.
FileMessagingRepository _projectMessagingRepository({
  required LocalExecutionEnv env,
  required String sessionRoot,
  required String? homeDir,
}) => FileMessagingRepository(
  env: env,
  root: '$sessionRoot/${encodeSessionCwd(env.cwd)}/messages',
  decodeSessionCwd: decodeSessionCwd,
  homeDir: homeDir,
);
