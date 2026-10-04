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
  final parseSw = Stopwatch()..start();
  final records = await session.getBranch();
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
    case 'tail':
      io.writeln('trajectory: following records — Ctrl+C to stop');
      final tailer = TrajectoryTailer(width: io.columns);
      final metadata = await session.getMetadata();
      for (final line in tailer.tail(records)) {
        io.write('$line\n');
      }
      while (true) {
        await Future<void>.delayed(trajectoryPollInterval);
        final List<SessionRecord> fresh;
        try {
          fresh = await (await repo.open(metadata)).getBranch();
        } on Object catch (error) {
          io.writeln('trajectory: tail failed: $error');
          return 1;
        }
        for (final line in tailer.tail(fresh)) {
          io.write('$line\n');
        }
      }
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

/// Prints trajectory payload lines to stdout (newline-terminated).
int _printTrajectory(CliIO io, List<String> lines) {
  for (final line in lines) {
    io.write('$line\n');
  }
  return 0;
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
