// gh-1041 — the deferred store-appearance check.
//
// Two layers, matching the repo's pipeline-test conventions:
//
//  1. Static lint over the new workflow + the Fastfile change (AC1/AC2):
//     the schedule is exactly daily-publish + 120 min, dispatch + read-only
//     permissions are in place, and the 900s group-appearance wait-loop is
//     GONE from the submit lanes' failing path.
//  2. IT over the real check script (scripts/store_appearance_check.rb)
//     against LOCAL fake ASC/Play/pub.dev endpoints serving the recorded
//     fixtures (AC5: present / absent / API error / version-rollover — no
//     real network) with a stubbed `gh`, proving the issue lifecycle:
//     exactly one stub per absent store, in-place updates, rollover
//     resolution, once-a-day green summaries, and real ES256/RS256 JWTs on
//     the wire (AC2/AC7 transport shape).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const workflowPath = '.github/workflows/store-appearance-check.yml';
const scriptPath = 'scripts/store_appearance_check.rb';
const modulePath = 'flutter_app/fastlane/store_appearance.rb';
const fixturesDir = 'flutter_app/fastlane/test/fixtures/store_appearance';

bool rubyAvailable = false;

void main() {
  setUpAll(() {
    rubyAvailable = Process.runSync('ruby', ['-v']).exitCode == 0;
  });

  group('workflow — store-appearance-check.yml (AC2)', () {
    final workflow = loadYaml(read(workflowPath)) as Map;
    final on =
        (workflow['on'] ?? workflow[true]) as Map; // YAML 1.1 keys `on` as true

    test('schedule = daily-publish + exactly 120 minutes (owner ruling)', () {
      final daily =
          loadYaml(read('.github/workflows/daily-publish.yml')) as Map;
      final dailyOn = (daily['on'] ?? daily[true]) as Map;
      String cronOf(Map trigger) =>
          ((trigger['schedule'] as List).first as Map)['cron'].toString();
      final dailyCron = cronOf(dailyOn);
      final checkCron = cronOf(on);
      final dailyParts = dailyCron.split(' ');
      final checkParts = checkCron.split(' ');
      expect(
        checkParts,
        hasLength(5),
        reason: 'the check carries a cron schedule',
      );
      expect(
        checkParts[0],
        dailyParts[0],
        reason: 'same minute as the daily legs',
      );
      expect(
        int.parse(checkParts[1]) - int.parse(dailyParts[1]),
        2,
        reason: 'exactly 120 min after the daily publish legs start (gh-1041)',
      );
    });

    test('manual dispatch with a stores choice + horizon input', () {
      final dispatch = on['workflow_dispatch'] as Map;
      final inputs = dispatch['inputs'] as Map;
      expect(
        (inputs['stores'] as Map)['options'].toString(),
        allOf(contains('testflight'), contains('play'), contains('pubdev')),
      );
      expect(inputs.keys, contains('horizon_minutes'));
    });

    test('read-only token + issues:write for the stub lifecycle', () {
      final perms = workflow['permissions'] as Map;
      expect(perms['contents'].toString(), 'read');
      expect(
        perms['issues'].toString(),
        'write',
        reason: 'stub filing/updates and green summaries need issues:write',
      );
      expect(
        perms['actions'].toString(),
        'read',
        reason:
            'gh run list resolves the daily legs\' started-at for the horizon '
            '— without actions:read the GITHUB_TOKEN 403s, since stays nil, '
            'stub_due? is unconditionally true and the horizon input is dead '
            '(review gh-1041 thread 1)',
      );
      expect(
        perms.containsKey('id-token'),
        isFalse,
        reason:
            'the check is read-only against the stores — no upload-grade token',
      );
    });

    test(
      'concurrency group + explicit timeout (watch arithmetic stays real)',
      () {
        expect(
          (workflow['concurrency'] as Map)['group'].toString(),
          'store-appearance-check',
        );
        final job = (workflow['jobs'] as Map)['check'] as Map;
        expect(job['timeout-minutes'].toString(), '20');
      },
    );

    test('reuses the submit legs credentials — no new secrets (I3)', () {
      final text = read(workflowPath);
      for (final secret in [
        r'secrets.APP_STORE_CONNECT_KEY_ID',
        r'secrets.APP_STORE_CONNECT_ISSUER_ID',
        r'secrets.APP_STORE_CONNECT_KEY_CONTENT',
        r'secrets.PLAY_STORE_SERVICE_ACCOUNT_JSON',
        r'vars.TESTFLIGHT_EXTERNAL_GROUP',
      ]) {
        expect(
          text,
          contains(secret),
          reason: '$secret must ride through to the check',
        );
      }
    });

    test('runs the shared check script (logic stays in one tested place)', () {
      final job = (workflow['jobs'] as Map)['check'] as Map;
      final steps = (job['steps'] as YamlList)
          .whereType<YamlMap>()
          .map((s) => s['run'].toString())
          .join('\n');
      expect(steps, contains('ruby scripts/store_appearance_check.rb'));
      expect(
        read(scriptPath),
        contains('--only'),
        reason: 'the dispatch stores input routes through --only',
      );
    });

    test(
      'dispatch inputs reach the script through env:, never ${{}} interpolation '
      '(review gh-1041 thread 4 — script injection hardening)',
      () {
        final text = read(workflowPath);
        // `type: choice` is NOT enforced for REST/gh CLI dispatches, and this
        // job's env carries the ASC .p8 + Play service account — an
        // interpolated input would be shell syntax before ruby validates it.
        expect(
          text,
          isNot(contains(r'--only "${{ inputs.stores }}"')),
          reason: 'the stores input must not expand into the run: script',
        );
        final job = (workflow['jobs'] as Map)['check'] as Map;
        final steps = (job['steps'] as YamlList).whereType<YamlMap>().toList();
        final onlyStep = steps.firstWhere(
          (s) => s['run'].toString().contains('--only'),
        );
        expect(
          onlyStep['run'].toString(),
          contains('"\$STORES_INPUT"'),
          reason:
              'the input rides an intermediate env var (GitHub hardening guide)',
        );
        final env = onlyStep['env'] as YamlMap;
        expect(env['STORES_INPUT'].toString(), r'${{ inputs.stores }}');
      },
    );
  });

  group('Fastfile — the 900s wait leaves the failing path (AC1)', () {
    final fastfile = read('flutter_app/fastlane/Fastfile');

    test('no verify timeout env, no deadline loop, no poll sleep', () {
      expect(
        fastfile,
        isNot(contains('TESTFLIGHT_VERIFY_TIMEOUT_SECONDS')),
        reason: 'the 900s wait-loop env is gone',
      );
      expect(
        fastfile,
        isNot(contains('never appeared in the external group')),
        reason: 'the user_error! verdict is gone',
      );
      expect(
        fastfile,
        isNot(contains('sleep(60)')),
        reason: 'no poll loop may remain in the submit path',
      );
      expect(
        fastfile,
        isNot(contains('deadline = Time.now')),
        reason: 'no blocking deadline may remain',
      );
    });

    test(
      'the verify becomes a non-failing note linking the deferred check',
      () {
        expect(
          fastfile,
          contains('store-appearance-check'),
          reason: 'the note must point at the deferred workflow',
        );
        expect(
          fastfile,
          contains('the submit stays GREEN'),
          reason: 'the leg must say explicitly that lag is not a failure',
        );
        // The probe still exists (observability), called by both lanes —
        // store_automation_guard_test.dart pins the 3 occurrences.
        expect('verify_external_distribution!'.allMatches(fastfile).length, 3);
      },
    );

    test(
      'fastlane processing wait is untouched (upload-owned, not the custom wait)',
      () {
        expect(fastfile, contains('skip_waiting_for_build_processing: false'));
        expect(fastfile, contains('TESTFLIGHT_WAIT_TIMEOUT_SECONDS'));
      },
    );

    test('touched workflows are still valid YAML', () {
      for (final path in [
        workflowPath,
        '.github/workflows/build-mobile.yml',
        '.github/workflows/build-macos.yml',
        '.github/workflows/daily-publish.yml',
      ]) {
        loadYaml(read(path));
      }
    });
  });

  group('check logic wiring (AC5)', () {
    test('pure decision module exists and the plain-ruby suite covers it', () {
      expect(File(modulePath).existsSync(), isTrue);
      final rubyTest = read(
        'flutter_app/fastlane/test/store_appearance_test.rb',
      );
      for (final scenario in ['present', 'absent', 'rolled_over', 'error']) {
        expect(
          rubyTest,
          contains(scenario),
          reason: 'AC5 matrix case missing: $scenario',
        );
      }
    });

    test('the script routes every decision through the module', () {
      final script = read(scriptPath);
      expect(script, contains("require_relative"));
      expect(
        script,
        contains('store_appearance'),
        reason: 'requires the pure module',
      );
      for (final call in [
        'resolve_expected',
        'decide_presence',
        'stub_due?',
        'plan_lifecycle',
      ]) {
        expect(
          script,
          contains(call),
          reason: '$call must not be re-decided in the script',
        );
      }
    });

    test('ci.yml picks the ruby suite up automatically (pre-flight loop)', () {
      expect(
        read('.github/workflows/ci.yml'),
        contains('for t in flutter_app/fastlane/test/*_test.rb'),
      );
    });
  });

  group('IT — check script against fake store endpoints (no real network)', () {
    final servers = <HttpServer>[];
    late String stubDir;
    late String fixtureRepo;
    final capturedAuth = <String>[];
    final capturedGrants = <String>[];

    /// Per-scenario store mode: which recorded fixture each fake endpoint
    /// serves — present / absent / rollover / error (500s).
    Future<void> startServer({
      String asc = 'present',
      String play = 'present',
      String pubdev = 'present',
    }) async {
      Future<void> serveJson(
        HttpRequest req,
        Object? json, [
        int status = 200,
      ]) async {
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(json is String ? json : jsonEncode(json));
        await req.response.close();
      }

      Future<void> serveFixture(HttpRequest req, String name) async =>
          serveJson(req, read('$fixturesDir/$name'));

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      server.listen((req) async {
        final path = req.uri.path;
        final auth = req.headers.value('authorization');
        if (auth != null) capturedAuth.add('${req.method} $path $auth');
        if (path.startsWith('/asc/')) {
          if (asc == 'error') {
            await serveJson(req, {
              "errors": [
                {"status": "500", "title": "Internal Server Error (fixture)"},
              ],
            }, 500);
            return;
          }
          if (path == '/asc/v1/apps') return serveFixture(req, 'asc_apps.json');
          if (path.startsWith('/asc/v1/betaGroups?') ||
              path == '/asc/v1/betaGroups') {
            return serveFixture(req, 'asc_beta_groups.json');
          }
          if (path.startsWith('/asc/v1/betaGroups/GRP-EXTERNAL/builds')) {
            return serveFixture(
              req,
              asc == 'present'
                  ? 'asc_group_builds_present.json'
                  : 'asc_group_builds_absent.json',
            );
          }
          if (path.startsWith('/asc/v1/builds')) {
            return serveFixture(
              req,
              asc == 'present'
                  ? 'asc_app_builds_present.json'
                  : 'asc_app_builds_absent.json',
            );
          }
        }
        if (path == '/play-token') {
          final body = await utf8.decoder.bind(req).join();
          capturedGrants.add(body);
          await serveJson(req, {"access_token": "fake-play-access-token"});
          return;
        }
        if (path.startsWith('/play/')) {
          if (play == 'error') {
            await serveJson(req, {
              "error": {"code": 500, "message": "backend error (fixture)"},
            }, 500);
            return;
          }
          if (path.endsWith('/edits')) {
            await serveJson(req, {"id": "EDIT-1"});
            return;
          }
          if (path.endsWith('/edits/EDIT-1')) {
            req.response.statusCode = 204;
            await req.response.close();
            return;
          }
          if (path.endsWith('/tracks/beta')) {
            if (play == 'notrack') {
              await serveJson(req, {
                "error": {"code": 404, "message": "track empty (fixture)"},
              }, 404);
              return;
            }
            return serveFixture(
              req,
              play == 'present'
                  ? 'play_track_present.json'
                  : 'play_track_absent.json',
            );
          }
        }
        if (path.startsWith('/pubdev/packages/')) {
          if (pubdev == 'error') {
            await serveJson(req, 'backend error (fixture)', 500);
            return;
          }
          return serveFixture(
            req,
            pubdev == 'present'
                ? 'pubdev_package_present.json'
                : 'pubdev_package_absent.json',
          );
        }
        req.response.statusCode = 404;
        await req.response.close();
      });
    }

    /// A throwaway git repo whose pubspec + tag define the EXPECTED version —
    /// the same tag/version-file resolution the production run uses.
    void makeFixtureRepo(String version) {
      final dir = Directory.systemTemp.createTempSync('store-appearance-');
      Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
      Process.runSync('git', [
        'config',
        'user.email',
        't@t',
      ], workingDirectory: dir.path);
      Process.runSync('git', [
        'config',
        'user.name',
        't',
      ], workingDirectory: dir.path);
      File(
        '${dir.path}/pubspec.yaml',
      ).writeAsStringSync('name: fixture\nversion: $version\n');
      Process.runSync('git', ['add', '.'], workingDirectory: dir.path);
      Process.runSync('git', [
        'commit',
        '-q',
        '-m',
        'seed',
      ], workingDirectory: dir.path);
      Process.runSync('git', ['tag', 'v$version'], workingDirectory: dir.path);
      fixtureRepo = dir.path;
    }

    /// A stub `gh` that records every invocation and answers the issue/run
    /// reads from canned files (same style as release_hygiene_test.dart).
    void makeGhStub({
      List<Map<String, Object>> openStubs = const [],
      List<int> publishStubs = const [],
      String summarizedBodies = '',
      String dailyRunJson = '',
      bool failIssueList = false,
    }) {
      final root = Directory.systemTemp.createTempSync('gh-stub-');
      stubDir = root.path;
      Directory('$stubDir/bin').createSync();
      File('$stubDir/open_stubs.json').writeAsStringSync(jsonEncode(openStubs));
      File('$stubDir/publish_stubs.json').writeAsStringSync(
        jsonEncode(publishStubs.map((n) => {'number': n}).toList()),
      );
      File('$stubDir/summarized.txt').writeAsStringSync(summarizedBodies);
      File('$stubDir/daily_run.json').writeAsStringSync(dailyRunJson);
      File('$stubDir/log').writeAsStringSync('');
      final gh = File('$stubDir/bin/gh');
      gh.writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
if [ -n "\$GH_FAIL_VERB" ] && [ "\$1 \$2" = "\$GH_FAIL_VERB" ]; then exit 1; fi
case "\$1 \$2" in
  "issue list"*)
    if [ "\$FAIL_ISSUE_LIST" = "1" ]; then exit 1; fi
    if [[ "\$*" == *"--label store-appearance-check"* ]]; then cat "\$GH_STUB_DIR/open_stubs.json"
    else cat "\$GH_STUB_DIR/publish_stubs.json"; fi
    exit 0 ;;
  "issue view"*) cat "\$GH_STUB_DIR/summarized.txt"; exit 0 ;;
  "run list"*) cat "\$GH_STUB_DIR/daily_run.json"; exit 0 ;;
esac
copy=0
for arg in "\$@"; do
  if [ "\$copy" = "1" ]; then cp "\$arg" "\$GH_STUB_DIR/last-body.md" 2>/dev/null; copy=0; fi
  [ "\$arg" = "--body-file" ] && copy=1
done
if [ "\$1 \$2" = "issue create" ]; then echo "https://github.com/OWNER/REPO/issues/42"; fi
exit 0
''');
      Process.runSync('chmod', ['+x', gh.path]);
    }

    Future<ProcessResult> runCheck({
      String asc = 'present',
      String play = 'present',
      String pubdev = 'present',
      String fixtureVersion = '1.0.485',
      String? now = '2026-09-29T07:17:00Z',
      String? since = '2026-09-29T05:17:00Z',
      bool withSecrets = true,
      bool dryRun = false,
      String? only,
      List<Map<String, Object>> openStubs = const [],
      List<int> publishStubs = const [],
      String summarizedBodies = '',
      String dailyRunJson = '',
      bool failIssueList = false,
      String? ghFailVerb,
    }) async {
      await startServer(asc: asc, play: play, pubdev: pubdev);
      makeFixtureRepo(fixtureVersion);
      makeGhStub(
        openStubs: openStubs,
        publishStubs: publishStubs,
        summarizedBodies: summarizedBodies,
        dailyRunJson: dailyRunJson,
        failIssueList: failIssueList,
      );
      final summaryFile = File('$fixtureRepo/step-summary.md');
      final port = servers.last.port;
      final env = <String, String>{
        'PATH': '$stubDir/bin:${Platform.environment['PATH']!}',
        'GH_TOKEN': 'stub',
        'GH_STUB_DIR': stubDir,
        'GH_LOG_FILE': '$stubDir/log',
        'GITHUB_REPOSITORY': 'OWNER/REPO',
        'GITHUB_RUN_ID': '4242',
        'GITHUB_STEP_SUMMARY': summaryFile.path,
        'TESTFLIGHT_EXTERNAL_GROUP': 'External Beta',
        'IOS_BUNDLE_ID': 'dev.fa1.app',
        'PLAY_PACKAGE_NAME': 'dev.fa1.app',
        'PLAY_TRACK': 'beta',
        'STORE_APPEARANCE_ASC_BASE': 'http://127.0.0.1:$port/asc',
        'STORE_APPEARANCE_PLAY_BASE': 'http://127.0.0.1:$port/play',
        'STORE_APPEARANCE_PLAY_TOKEN_URL': 'http://127.0.0.1:$port/play-token',
        'STORE_APPEARANCE_PUBDEV_BASE': 'http://127.0.0.1:$port/pubdev',
        'STORE_APPEARANCE_RUN_URL': 'https://ci/runs/it',
        if (dryRun) 'STORE_APPEARANCE_DRY_RUN': '1',
        'STORE_APPEARANCE_NOW': ?now,
        'STORE_APPEARANCE_SINCE': ?since,
        if (failIssueList) 'FAIL_ISSUE_LIST': '1',
        'GH_FAIL_VERB': ?ghFailVerb,
        if (withSecrets) ...{
          'APP_STORE_CONNECT_KEY_ID': 'TESTKID',
          'APP_STORE_CONNECT_ISSUER_ID': 'TESTISSUER',
          'APP_STORE_CONNECT_KEY_CONTENT': read('$fixturesDir/test_asc_key.p8'),
          'PLAY_STORE_SERVICE_ACCOUNT_JSON': read(
            '$fixturesDir/test_play_service_account.json',
          ),
        },
      };
      final result = await Process.run(
        'ruby',
        [
          File(scriptPath).absolute.path,
          if (only != null) ...['--only', only],
        ],
        workingDirectory: fixtureRepo,
        environment: env,
      );
      return result;
    }

    Map<String, dynamic> resultOf(ProcessResult r) {
      final line = r.stdout
          .toString()
          .split('\n')
          .lastWhere(
            (l) => l.startsWith('STORE_APPEARANCE_RESULT '),
            orElse: () => '',
          );
      expect(
        line,
        isNotEmpty,
        reason:
            'the script must always print its result JSON\n'
            'stdout: ${r.stdout}\nstderr: ${r.stderr}',
      );
      return jsonDecode(line.substring('STORE_APPEARANCE_RESULT '.length))
          as Map<String, dynamic>;
    }

    List<String> ghLog() => File('$stubDir/log').readAsLinesSync();

    tearDown(() async {
      for (final server in servers) {
        await server.close(force: true);
      }
      servers.clear();
      Directory(fixtureRepo).deleteSync(recursive: true);
      Directory(stubDir).deleteSync(recursive: true);
      capturedAuth.clear();
      capturedGrants.clear();
    });

    test(
      'all stores present → green summary on the publish stubs, exit 0',
      () async {
        if (!rubyAvailable) return;
        final r = await runCheck(publishStubs: [7, 8]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final result = resultOf(r);
        expect((result['verdicts'] as Map)['testflight']['verdict'], 'present');
        expect((result['verdicts'] as Map)['play']['verdict'], 'present');
        expect((result['verdicts'] as Map)['pubdev']['verdict'], 'present');
        final log = ghLog();
        expect(
          log.where((l) => l.contains('issue create')),
          isEmpty,
          reason: 'nothing absent — no stub may be filed',
        );
        expect(
          log.where((l) => l.contains('issue comment 7')).length,
          1,
          reason: 'the green summary lands on the day\'s publish stub',
        );
        expect(log.where((l) => l.contains('issue comment 8')).length, 1);
        expect(
          File('$stubDir/last-body.md').readAsStringSync(),
          contains('Store appearance check — all green'),
        );
        expect(
          File('$fixtureRepo/step-summary.md').readAsStringSync(),
          contains('Store appearance check'),
        );
      },
    );

    test(
      'real JWTs ride the wire: ES256 to ASC, RS256 assertion to the Play token endpoint',
      () async {
        if (!rubyAvailable) return;
        await runCheck();
        final ascAuth = capturedAuth.firstWhere(
          (a) => a.contains('/asc/v1/apps'),
        );
        final ascToken = ascAuth.split('Bearer ').last;
        expect(ascAuth, contains('Bearer '));
        expect(
          ascToken.split('.').length,
          3,
          reason: 'a real ES256 JWT, not a stub string',
        );
        expect(
          ascToken.split('.')[0],
          'eyJhbGciOiJFUzI1NiIsImtpZCI6IlRFU1RLSUQiLCJ0eXAiOiJKV1QifQ',
          reason: 'header decodes to {alg:ES256, kid:TESTKID, typ:JWT}',
        );
        final grant = capturedGrants.single;
        expect(
          grant,
          contains(
            'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer',
          ),
        );
        final assertion = Uri.splitQueryString(grant)['assertion']!;
        expect(
          assertion.split('.').length,
          3,
          reason: 'a real RS256 assertion minted from the SA key',
        );
      },
    );

    test(
      'absent past the horizon → exactly one stub per absent store, exit 1',
      () async {
        if (!rubyAvailable) return;
        final r = await runCheck(
          asc: 'absent',
          play: 'absent',
          pubdev: 'absent',
        );
        expect(r.exitCode, 1, reason: 'absence past the horizon is loud');
        final result = resultOf(r);
        for (final store in ['testflight', 'play', 'pubdev']) {
          expect((result['verdicts'] as Map)[store]['verdict'], 'absent');
        }
        final log = ghLog();
        expect(
          log.where((l) => l.contains('issue create')).length,
          3,
          reason: 'one evidence stub per absent store — never more',
        );
        expect(
          File('$stubDir/last-body.md').readAsStringSync(),
          contains('still **absent**'),
        );
        expect(
          File('$stubDir/last-body.md').readAsStringSync(),
          contains('https://ci/runs/it'),
          reason: 'the stub carries the check run as evidence',
        );
      },
    );

    test(
      'a second identical check updates the stubs in place (no duplicates, REG)',
      () async {
        if (!rubyAvailable) return;
        final r = await runCheck(
          asc: 'absent',
          play: 'absent',
          pubdev: 'absent',
          openStubs: [
            {
              'number': 11,
              'title': '[store-appearance-check] TestFlight 1.0.485 absent',
            },
            {
              'number': 12,
              'title': '[store-appearance-check] Play 1.0.485 absent',
            },
            {
              'number': 13,
              'title': '[store-appearance-check] pub.dev 1.0.485 absent',
            },
          ],
        );
        expect(r.exitCode, 1);
        final log = ghLog();
        expect(
          log.where((l) => l.contains('issue create')),
          isEmpty,
          reason: 'the stubs exist — filing again would duplicate',
        );
        expect(log.where((l) => l.startsWith('issue comment 11')).length, 1);
        expect(log.where((l) => l.startsWith('issue comment 12')).length, 1);
        expect(log.where((l) => l.startsWith('issue comment 13')).length, 1);
      },
    );

    test('absence below the horizon only reports — no stub, exit 0', () async {
      if (!rubyAvailable) return;
      final r = await runCheck(
        asc: 'absent',
        play: 'absent',
        pubdev: 'absent',
        now: '2026-09-29T06:00:00Z',
      );
      expect(r.exitCode, 0, reason: 'an early manual check must not alarm');
      expect(resultOf(r)['stub_due'], false);
      expect(ghLog().where((l) => l.contains('issue create')), isEmpty);
    });

    test('version rollover resolves: stubs close, exit 0', () async {
      if (!rubyAvailable) return;
      final r = await runCheck(
        fixtureVersion: '1.0.484',
        openStubs: [
          {
            'number': 11,
            'title': '[store-appearance-check] TestFlight 1.0.484 absent',
          },
          {
            'number': 12,
            'title': '[store-appearance-check] pub.dev 1.0.484 absent',
          },
        ],
      );
      expect(r.exitCode, 0);
      final result = resultOf(r);
      expect(
        (result['verdicts'] as Map)['testflight']['verdict'],
        'rolled_over',
      );
      expect((result['verdicts'] as Map)['pubdev']['verdict'], 'rolled_over');
      final log = ghLog();
      expect(log.where((l) => l.contains('issue create')), isEmpty);
      expect(log.where((l) => l.startsWith('issue close 11')).length, 1);
      expect(log.where((l) => l.startsWith('issue close 12')).length, 1);
    });

    test(
      'API errors never file stubs (noise guard) — but the run stays red',
      () async {
        if (!rubyAvailable) return;
        final r = await runCheck(asc: 'error', play: 'error', pubdev: 'error');
        expect(r.exitCode, 1, reason: 'an API error is loud, just not stubbed');
        final result = resultOf(r);
        expect(
          (result['errors'] as Map).keys.toList(),
          containsAll(['testflight', 'play', 'pubdev']),
        );
        expect(ghLog().where((l) => l.contains('issue create')), isEmpty);
        expect(
          ghLog().where((l) => l.contains('issue close')),
          isEmpty,
          reason: 'an erroring store must not resolve existing stubs either',
        );
      },
    );

    test(
      'once-a-day guard: the green summary is not repeated within the day (REG)',
      () async {
        if (!rubyAvailable) return;
        final r = await runCheck(
          publishStubs: [7],
          summarizedBodies:
              '<!-- store-appearance-check:green-summary 2026-09-29 -->',
        );
        expect(r.exitCode, 0);
        expect(
          ghLog().where((l) => l.contains('issue comment 7')),
          isEmpty,
          reason: 'the marker already carries today\'s summary',
        );
      },
    );

    test(
      '--only scopes the run, and missing secrets skip green-neutrally',
      () async {
        if (!rubyAvailable) return;
        final r = await runCheck(pubdev: 'absent', only: 'pubdev');
        expect(r.exitCode, 1);
        final result = resultOf(r);
        expect((result['verdicts'] as Map).keys, [
          'pubdev',
        ], reason: '--only must scope both the checks and the stub family');
        expect(ghLog().where((l) => l.contains('issue create')).length, 1);

        // Without the ASC/Play secrets those stores skip (green-neutral, the
        // leg semantics) — they never error and never file.
        final dryRun = await runCheck(
          withSecrets: false,
          dryRun: true,
          pubdev: 'absent',
        );
        expect(dryRun.exitCode, 1, reason: 'the pub.dev absence is still loud');
        final verdicts = resultOf(dryRun)['verdicts'] as Map;
        expect(
          verdicts.containsKey('testflight'),
          isFalse,
          reason: 'no ASC key → the store skips, it never errors',
        );
        expect(verdicts.containsKey('play'), isFalse);
        expect(verdicts['pubdev']['verdict'], 'absent');
      },
    );

    test(
      'the play leg stays read-only: the edit is always deleted, never committed',
      () async {
        if (!rubyAvailable) return;
        await runCheck(play: 'absent');
        expect(
          capturedAuth.any(
            (a) => a.startsWith('POST /play/') && a.contains('/edits '),
          ),
          isTrue,
          reason: 'the edit is created (reads require one)',
        );
        expect(
          capturedAuth.any((a) => a.startsWith('DELETE /play/')),
          isTrue,
          reason: 'edits.insert must be abandoned (read-only contract)',
        );
        expect(
          capturedAuth.where(
            (a) =>
                a.startsWith('POST /play/') &&
                a.contains('edits/EDIT-1:commit'),
          ),
          isEmpty,
          reason: 'a commit would PUBLISH — forbidden (I3)',
        );
      },
    );

    test('a failed gh READ aborts the lifecycle — never a duplicate stub '
        '(review gh-1041 thread 3)', () async {
      if (!rubyAvailable) return;
      // Everything absent + past the horizon: the state WOULD file stubs —
      // but the stub-list read itself fails, so the run must go red and
      // plan nothing instead of reading the failure as "no stubs exist".
      final r = await runCheck(
        asc: 'absent',
        play: 'absent',
        pubdev: 'absent',
        failIssueList: true,
      );
      expect(r.exitCode, 1, reason: 'a failed gh read is loud, not silent');
      final result = resultOf(r);
      expect(
        (result['lifecycle_error'] as String?) ?? '',
        isNotEmpty,
        reason: 'the aborted lifecycle is part of the machine result',
      );
      expect(
        ghLog().where((l) => l.contains('issue create')),
        isEmpty,
        reason: 'no stub may be planned on partially-read state (AC3)',
      );
    });

    test('a partial --only run posts no all-green summary '
        '(review gh-1041 thread 2)', () async {
      if (!rubyAvailable) return;
      final r = await runCheck(only: 'pubdev', publishStubs: [7]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final verdicts = resultOf(r)['verdicts'] as Map;
      expect(verdicts.keys, ['pubdev']);
      expect(
        ghLog().where((l) => l.contains('issue comment 7')),
        isEmpty,
        reason:
            'one store is not "all stores" — the summary and its '
            'day-marker must wait for the full family',
      );
    });

    test('the horizon follows the REAL leg state: still running → report only '
        '(review gh-1041 thread 5)', () async {
      if (!rubyAvailable) return;
      // since env unset → the script resolves the legs via `gh run list`
      // (needs the workflow's actions:read); the day's run is IN PROGRESS,
      // so the build may not even be uploaded — absence must not stub.
      final running = await runCheck(
        asc: 'absent',
        play: 'absent',
        pubdev: 'absent',
        since: null,
        dailyRunJson:
            '{"createdAt":"2026-09-29T05:17:00Z","status":"in_progress","conclusion":null}',
      );
      expect(running.exitCode, 0, reason: 'a running leg owns the horizon');
      expect(
        ghLog().any((l) => l.contains('run list')),
        isTrue,
        reason: 'the leg state is fetched via gh run list (actions:read)',
      );
      expect(
        ghLog().where((l) => l.contains('issue create')),
        isEmpty,
        reason: 'no stub while the publish leg is still running',
      );
      expect(resultOf(running)['since'], '2026-09-29T05:17:00Z');

      final finished = await runCheck(
        asc: 'absent',
        play: 'absent',
        pubdev: 'absent',
        since: null,
        dailyRunJson:
            '{"createdAt":"2026-09-29T05:17:00Z","status":"completed","conclusion":"success"}',
      );
      expect(finished.exitCode, 1, reason: 'absent past the horizon is loud');
      expect(
        ghLog().where((l) => l.contains('issue create')).length,
        3,
        reason: 'a finished leg + absence past the horizon files the stubs',
      );
    });

    test('a leg that FAILED never went green → no absence stubs at all '
        '(review gh-1041 thread 7)', () async {
      if (!rubyAvailable) return;
      final failed = await runCheck(
        asc: 'absent',
        play: 'absent',
        pubdev: 'absent',
        since: null,
        dailyRunJson:
            '{"createdAt":"2026-09-29T05:17:00Z","status":"completed","conclusion":"failure"}',
      );
      expect(
        failed.exitCode,
        0,
        reason:
            'no green submit ⇒ no appearance premise; the [daily-publish] '
            'leg stub owns the signal',
      );
      expect(
        ghLog().where((l) => l.contains('issue create')),
        isEmpty,
        reason: 'an absence stub would just duplicate the leg failure stub',
      );
      expect(resultOf(failed)['stub_due'], isFalse);
    });

    test('a failed gh WRITE turns the run red and is recorded '
        '(review gh-1041 thread 8)', () async {
      if (!rubyAvailable) return;
      // All present + an open stub ⇒ exactly one close_stub action; the
      // stubbed gh fails every `issue close`, so the run must not exit 0.
      final r = await runCheck(
        openStubs: [
          {
            'number': 42,
            'title': '[store-appearance-check] TestFlight 1.0.485 absent',
          },
        ],
        ghFailVerb: 'issue close',
      );
      expect(
        r.exitCode,
        1,
        reason: 'a partially-executed lifecycle never reports a clean green',
      );
      final result = resultOf(r);
      expect((result['write_failures'] as List), isNotEmpty);
      final close =
          (result['actions'] as List).firstWhere(
                (a) => a['action'] == 'close_stub',
              )
              as Map;
      expect(close['done'], isFalse, reason: 'the failed write is annotated');
      final r2 = await runCheck(
        openStubs: [
          {
            'number': 42,
            'title': '[store-appearance-check] TestFlight 1.0.485 absent',
          },
        ],
      );
      expect(r2.exitCode, 0, reason: '${r2.stderr}');
      final close2 =
          (resultOf(r2)['actions'] as List).firstWhere(
                (a) => a['action'] == 'close_stub',
              )
              as Map;
      expect(close2['done'], isTrue);
    });
  });
}
