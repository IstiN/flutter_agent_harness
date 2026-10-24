// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/dap_enrollment_service.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const invite = 'wss://hub.fa1.dev/ws?channel=$channel';
  const block =
      "fa dap import '$invite' && DAP_HUB_URL=wss://hub.fa1.dev/ws "
      "DAP_CLIENT_SECRET='test-only-enrollment-credential' "
      'DAP_AGENT_NAME=app-agent fa';

  test('full enrollment paste is recognized and mapped to joined', () async {
    DapJoinBundle? joined;
    final service = DapEnrollmentService(
      supported: true,
      join: (bundle) async => joined = bundle,
    );

    final attempt = service.startPaste(block);
    expect(attempt, isNotNull);
    final result = await attempt!.result;

    expect(result.status, DapEnrollmentStatus.joined);
    expect(result.channel, channel);
    expect(joined!.invite.channel, channel);
    expect(joined!.agentName, 'app-agent');
    expect(
      joined!.clientSecret == 'test-only-enrollment-credential',
      isTrue,
      reason: 'the credential crosses only the parsed join boundary',
    );
  });

  test('ordinary DAP prose is left for the model', () {
    final service = DapEnrollmentService(supported: true, join: (_) async {});
    expect(service.startPaste('What does DAP_CLIENT_SECRET do?'), isNull);
    expect(service.startPaste('please explain fa dap import'), isNull);
  });

  test('bare channel uses an explicitly supplied default hub', () async {
    final service = DapEnrollmentService(supported: true, join: (_) async {});
    final attempt = service.startPaste(
      '#team_channel',
      defaultHubUrl: 'wss://hub.fa1.dev/ws',
    );
    expect(attempt, isNotNull);
    expect((await attempt!.result).status, DapEnrollmentStatus.joined);
  });

  test('accepted bundle with an invalid explicit hub fails safely', () async {
    final service = DapEnrollmentService(supported: true, join: (_) async {});
    final attempt = service.startPaste(
      "fa dap import '$invite' && DAP_HUB_URL=not-a-url "
      "DAP_CLIENT_SECRET='test-only-enrollment-credential' fa",
    );
    expect(attempt, isNotNull);
    expect((await attempt!.result).status, DapEnrollmentStatus.failed);
  });

  test('web-unsupported result never invokes the native join', () async {
    var joins = 0;
    final service = DapEnrollmentService(
      supported: false,
      join: (_) async => joins++,
    );
    final attempt = service.startPaste(block);
    expect(attempt, isNotNull);
    expect((await attempt!.result).status, DapEnrollmentStatus.unsupported);
    expect(joins, 0);
  });

  test('dedicated store round-trips reconnect data in the app env', () async {
    final env = ProjectMountEnv(MemoryExecutionEnv(cwd: '/app'))
      ..mountedRoot = '/host/project';
    expect(env.appStorageCwd, '/app');
    final bundle = parseDapJoinBundle(block);
    final store = await DapEnrollmentStore.load(
      env,
      projectCwd: '/work/project',
    );
    await store.save(bundle);
    final projectArtifact = await env.readTextFile(
      '/project/${DapEnrollmentStore.fileName('/work/project')}',
    );
    expect(projectArtifact.valueOrNull, isNull);

    final restored = await DapEnrollmentStore.load(
      env,
      projectCwd: '/work/project',
    );
    final enrollment = restored.enrollment;
    expect(enrollment, isNotNull);
    expect(enrollment!.invite.channel, channel);
    expect(enrollment.clientSecret == bundle.clientSecret, isTrue);
    expect(
      DapEnrollmentStore.fileName('/work/project') ==
          DapEnrollmentStore.fileName('/work/other'),
      isFalse,
    );
  });
}
