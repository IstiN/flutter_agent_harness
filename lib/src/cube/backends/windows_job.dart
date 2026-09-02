/// Windows backend: Job Object limit descriptor generation.
///
/// Windows has no POSIX-style exec wrapper this harness can shell out to;
/// confining a process tree requires a Job Object via FFI
/// (`CreateJobObject`/`SetInformationJobObject`/`AssignProcessToJobObject`).
/// Phase 4 ships the FFI execution side; this backend contributes the pure
/// descriptor math ([WindowsJobBackend.buildJobDescriptor]) — the limit
/// flags and values a Job Object would be configured with — and reports
/// `enforces = false` honestly: no fake confinement.
library;

import '../config/resource_limits.dart';
import 'cube_backend.dart';

/// The Windows backend: Job Object descriptor generation (execution needs
/// FFI — Phase 4 follow-up).
final class WindowsJobBackend implements CubeSandboxBackend {
  /// Creates the Windows backend.
  const WindowsJobBackend();

  /// `JOB_OBJECT_LIMIT_PROCESS_MEMORY` — a per-process memory cap.
  static const processMemoryFlag = 0x100;

  /// `JOB_OBJECT_LIMIT_CPU_RATE` — a CPU rate control.
  static const cpuRateFlag = 0x4;

  /// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` — stray children die with the job.
  static const killOnJobCloseFlag = 0x2000;

  @override
  bool get enforces => false;

  @override
  String wrapCommand(
    String command, {
    required String profilePath,
    Map<String, String> env = const {},
  }) => command;

  @override
  String describe() =>
      'Windows Job Object descriptor generated (execution needs FFI — '
      'Phase 4 follow-up)';

  /// Computes the Job Object limit descriptor for [limits]:
  ///
  /// - `memoryBytes` → [processMemoryFlag] plus
  ///   `processMemoryLimitBytes`.
  /// - `cpu` as a percentage (`"50%"`) → [cpuRateFlag] plus `cpuRate`
  ///   (percent × 100; 50% → 5000). Other cpu spellings (bare fractions)
  ///   have no mapping yet and are omitted.
  /// - `timeout` → `timeoutMilliseconds` (wall clock, enforced by the job
  ///   runner's timer rather than a Job Object flag).
  /// - [killOnJobCloseFlag] is always set.
  ///
  /// With no limits at all the flags word is `0`.
  static Map<String, Object?> buildJobDescriptor(CubeResourceLimits limits) {
    var flags = killOnJobCloseFlag;
    final cpu = limits.cpu;
    final cpuPercent = cpu == null
        ? null
        : cpu.endsWith('%')
        ? double.tryParse(cpu.substring(0, cpu.length - 1))
        : null;
    if (cpuPercent != null) flags |= cpuRateFlag;
    final memoryBytes = limits.memoryBytes;
    if (memoryBytes != null) flags |= processMemoryFlag;
    return {
      'flags': flags,
      'processMemoryLimitBytes': ?memoryBytes,
      if (cpuPercent != null) 'cpuRate': (cpuPercent * 100).round(),
      'timeoutMilliseconds': ?limits.timeout?.inMilliseconds,
    };
  }
}
