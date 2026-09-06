// Scheduled-task store for background work (issue #30, IT-B1):
// 'hourly check'-style prompts the host registers with chrome.alarms.
// The task list and a fire ledger both live in chrome.storage.local, so
// they survive service-worker restarts (E21); the ledger keyed
// '<taskId>@<scheduledTs>' is what makes delivery exactly-once when
// chrome re-delivers a missed alarm after a wake. Pure Dart — time is an
// injected clock, no timers anywhere.
library;

import 'dart:async';

import '../chrome_api.dart';

/// storage.local key holding the task records (E21 persistence).
const scheduledTasksKey = 'fa.scheduled';

/// storage.local key holding `Map<taskRunKey, firedAtMs>` (exactly-once).
const firedLedgerKey = 'fa.firedLedger';

/// chrome.alarms caps at 500; the repo keeps a stricter budget so a
/// runaway scheduler fails loudly instead of silently starving chrome's
/// alarm pool, which everything else in the SW shares.
const maxScheduledTasks = 100;

/// Alarm-name prefix; the task id follows, e.g. 'fa-task-hourly-check'.
const _alarmPrefix = 'fa-task-';

/// chrome.alarms name for a task: `'fa-task-<id>'`.
String _alarmName(String id) => '$_alarmPrefix$id';

/// One schedulable background prompt.
final class ScheduledTask {
  ScheduledTask({
    required this.id,
    required this.prompt,
    this.period,
    this.whenMs,
    this.enabled = true,
  });

  /// Stable host-chosen key, e.g. 'hourly-check'. Must not contain '@':
  /// the ledger derives `'<id>@<ts>'` run keys from it.
  final String id;

  /// What the agent should run when the task fires.
  final String prompt;

  /// Repeat interval; null means one-shot at [whenMs].
  final Duration? period;

  /// One-shot fire time (ms since epoch); null for pure periodic tasks.
  final int? whenMs;

  /// Disabled tasks keep their record but get no alarm and no fires.
  bool enabled;

  Map<String, Object?> toJson() => {
    'id': id,
    'prompt': prompt,
    'periodMs': period?.inMilliseconds,
    'whenMs': whenMs,
    'enabled': enabled,
  };

  /// Accepts both the in-memory shape and the JSON-round-tripped one
  /// (`Map<String, dynamic>` after a real chrome restart).
  static ScheduledTask fromJson(Object? raw) {
    final map = Map<String, Object?>.from(raw as Map);
    return ScheduledTask(
      id: map['id'] as String,
      prompt: map['prompt'] as String,
      period: map['periodMs'] == null
          ? null
          : Duration(milliseconds: map['periodMs'] as int),
      whenMs: map['whenMs'] as int?,
      enabled: map['enabled'] as bool? ?? true,
    );
  }
}

/// Registers prompts as chrome alarms and dedups fires across SW
/// restarts via a persistent ledger.
final class AlarmScheduler {
  AlarmScheduler(this._api, {int Function()? clock, this.onDue})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ChromeApi _api;
  final int Function() _clock;

  /// Called once per due task — after the ledger recorded the tick, so a
  /// crash mid-callback replays nothing, and a restart that re-delivers
  /// the same tick stays silent.
  void Function(ScheduledTask task)? onDue;

  final Map<String, ScheduledTask> _tasks = {};
  Map<String, Object?> _ledger = {};
  StreamSubscription<Alarm>? _sub;

  /// SW-start boot: load persisted state (E21), leave alarms chrome still
  /// owns (it will deliver them, late if needed), and rebuild the ones it
  /// lost to a browser restart — firing the latest missed tick once if
  /// the ledger has no record of it, then re-arming for the NEXT period
  /// instead of double-firing.
  Future<void> boot() async {
    final stored = await _api.storage.get([scheduledTasksKey, firedLedgerKey]);
    _tasks.clear();
    for (final raw in stored[scheduledTasksKey] as List? ?? const []) {
      final task = ScheduledTask.fromJson(raw);
      _tasks[task.id] = task;
    }
    _ledger = stored[firedLedgerKey] == null
        ? {}
        : Map<String, Object?>.from(stored[firedLedgerKey] as Map);

    final now = _clock();
    final liveAlarms = {for (final a in await _api.alarms.getAll()) a.name: a};
    for (final task in _tasks.values) {
      if (!task.enabled || liveAlarms.containsKey(_alarmName(task.id))) {
        continue;
      }
      // The alarm was lost (browser restart): rebuild its phase from the
      // ledger, fire the latest missed tick once, arm the next.
      final name = _alarmName(task.id);
      if (task.period != null) {
        final periodMs = task.period!.inMilliseconds;
        final last = _lastFiredTs(task.id);
        int next;
        if (last == null) {
          next = now + periodMs; // never fired: start the phase at boot
        } else {
          var due = last;
          while (due + periodMs <= now) {
            due += periodMs;
          }
          if (due > last) await _recordAndFire(task, due);
          next = due + periodMs;
        }
        await _api.alarms.create(
          name: name,
          periodMinutes: _periodMinutes(task.period!),
          whenMs: next,
        );
      } else if (task.whenMs != null) {
        if (task.whenMs! <= now &&
            !_ledger.containsKey('${task.id}@${task.whenMs}')) {
          await _recordAndFire(task, task.whenMs!); // missed one-shot, once
        }
        if (task.whenMs! > now) {
          await _api.alarms.create(name: name, whenMs: task.whenMs);
        }
      }
    }
    _sub ??= _api.alarms.onAlarm.listen(_onAlarm);
  }

  /// Registers (or replaces) [task] and wires its chrome alarm. Storage
  /// is written before the alarm, so a crash in between heals at the next
  /// boot; storage failures (quota) pass through untouched.
  Future<void> schedule(ScheduledTask task) async {
    if (task.period == null && task.whenMs == null) {
      throw ChromeApiException(
        'bad_args',
        'task "${task.id}" needs a period or a whenMs',
      );
    }
    if (!_tasks.containsKey(task.id) && _tasks.length >= maxScheduledTasks) {
      throw ChromeApiException(
        'too_many_tasks',
        'scheduled-task cap of $maxScheduledTasks reached',
      );
    }
    // Fresh schedule = fresh dedup epoch: stale ledger keys must not
    // suppress the new schedule's ticks.
    _ledger.removeWhere((key, _) => key.startsWith('${task.id}@'));
    _tasks[task.id] = task;
    await _persist();
    await _api.alarms.clear(_alarmName(task.id));
    if (!task.enabled) return;
    await _api.alarms.create(
      name: _alarmName(task.id),
      periodMinutes: task.period == null ? null : _periodMinutes(task.period!),
      whenMs: task.whenMs,
    );
  }

  /// Drops the task, its ledger entries and its chrome alarm.
  Future<bool> remove(String id) async {
    if (_tasks.remove(id) == null) return false;
    _ledger.removeWhere((key, _) => key.startsWith('$id@'));
    await _persist();
    await _api.alarms.clear(_alarmName(id));
    return true;
  }

  /// Persisted tasks, ordered by id for deterministic assertions.
  List<ScheduledTask> list() => [
    for (final id in _tasks.keys.toList()..sort()) _tasks[id]!,
  ];

  Future<void> _persist() => _api.storage.set({
    scheduledTasksKey: [for (final t in _tasks.values) t.toJson()],
    firedLedgerKey: _ledger,
  });

  Future<void> _onAlarm(Alarm alarm) async {
    if (!alarm.name.startsWith(_alarmPrefix)) return; // not ours
    final task = _tasks[alarm.name.substring(_alarmPrefix.length)];
    if (task == null) {
      // Stale alarm for a removed task: chrome keeps it until told not to.
      await _api.alarms.clear(alarm.name);
      return;
    }
    if (task.enabled) await _recordAndFire(task, alarm.scheduledTs);
  }

  /// The exactly-once heart: the ledger records the tick BEFORE onDue
  /// runs, so a replay of the same `'<id>@<ts>'` event (restart +
  /// redelivery) becomes a no-op even if the process dies mid-callback.
  Future<void> _recordAndFire(ScheduledTask task, int scheduledTs) async {
    final key = '${task.id}@$scheduledTs';
    if (_ledger.containsKey(key)) return;
    _ledger[key] = _clock();
    await _api.storage.set({firedLedgerKey: _ledger});
    onDue?.call(task);
  }

  /// Newest ledgered tick for [id], parsed from its `'<id>@<ts>'` keys.
  int? _lastFiredTs(String id) {
    final prefix = '$id@';
    int? last;
    for (final key in _ledger.keys) {
      if (!key.startsWith(prefix)) continue;
      final ts = int.parse(key.substring(prefix.length));
      if (last == null || ts > last) last = ts;
    }
    return last;
  }

  /// chrome.alarms granularity is whole minutes (≥1); ceiling keeps the
  /// effective period never shorter than the task asked for.
  static int _periodMinutes(Duration period) {
    final minutes = (period.inMilliseconds / 60000).ceil();
    return minutes < 1 ? 1 : minutes;
  }
}
