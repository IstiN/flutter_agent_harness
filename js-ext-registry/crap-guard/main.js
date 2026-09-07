// crap-guard — bundled reference extension (issue #32): post-edit CRAP +
// file-size guard. ES2020, no modules; uses only jsr.ext.*, Date.now, JSON.
// Registers exactly two hooks (afterToolCall, onSessionEnd) — no
// tools/slash/flows.
(function (g) {
  'use strict';
  var ext = g.jsr.ext;

  var DEBOUNCE_MS = 2000;       // edits inside this window collapse into one check
  var MAX_LINES = 2800;         // repo line cap (ci.yml file-size guard)
  var EXEC_TIMEOUT_MS = 180000;
  var DEFAULT_THRESHOLD = 12.0; // used when crap4dart.yaml is absent/unreadable
  var CRAP_ARGS = ['pub', 'global', 'run', 'crap4dart', 'analyze'];
  var MISSING_MSG = 'crap-guard: crap4dart not activated — activate: ' +
    'dart pub global activate crap4dart 0.2.1 (checks idle until then)';

  // Session state (lives in this closure; one instance per main.js eval).
  var lastCheckAt = 0;          // Date.now() of the last executed check
  var checkedFiles = new Set(); // files edited since the last executed check
  var editsCount = 0;           // qualifying edits this session (survives checks)
  var missingToolNoted = false; // E17: degradation note at most once per session
  var coverageNoted = false;    // complexity-only note at most once per session
  var threshold;                // crap4dart.yaml threshold, cached after first read

  function norm(p) { return String(p).split('\\').join('/'); }

  // Only non-generated .dart files inside the project (per the repo's
  // crap4dart.yaml exclude globs: '**.g.dart', '**.freezed.dart',
  // 'vendor/**', 'build/**').
  function isGuarded(p) {
    var n = norm(p);
    if (!/\.dart$/.test(n)) { return false; }
    if (/\.g\.dart$/.test(n) || /\.freezed\.dart$/.test(n)) { return false; }
    if (n.indexOf('vendor/') === 0 || n.indexOf('/vendor/') >= 0) { return false; }
    if (n.indexOf('build/') === 0 || n.indexOf('/build/') >= 0) { return false; }
    return true;
  }

  // Naive YAML read: first `threshold: <number>` line; the fallback applies
  // when the file is missing, unreadable, or has no such line.
  function readThreshold() {
    if (threshold !== undefined) { return Promise.resolve(threshold); }
    return ext.fs.readFile('crap4dart.yaml').then(
      function (text) {
        var m = /(^|[\n\r])\s*threshold:\s*([0-9]+(?:\.[0-9]+)?)/.exec(String(text));
        threshold = m ? parseFloat(m[2]) : DEFAULT_THRESHOLD;
        return threshold;
      },
      function () {
        threshold = DEFAULT_THRESHOLD;
        return threshold;
      }
    );
  }

  function runCrap() {
    return ext.exec.run({ command: 'dart', args: CRAP_ARGS, timeoutMs: EXEC_TIMEOUT_MS });
  }

  // crap4dart not activated / dart missing: exit 127, shell wording, or a
  // pub resolution error. A bridge-level rejection (no res) stays silent.
  function looksMissing(res) {
    if (!res) { return false; }
    if (res.exitCode === 127) { return true; }
    var text = String(res.stdout || '') + '\n' + String(res.stderr || '');
    return /not found|is not recognized|Could not find package/i.test(text);
  }

  // Parses `crap4dart analyze` table rows. Columns are whitespace-separated
  // (two-space gutters, right-aligned numerics): CRAP COV% BR% CC
  // Class.method file:startLine. CRAP is the string 'N/A' when no coverage
  // data exists. Header, separator, and verdict lines never parse as rows.
  function parseRows(text) {
    var rows = [];
    var lines = String(text).split('\n');
    for (var i = 0; i < lines.length; i += 1) {
      var t = lines[i].trim().split(/\s+/);
      if (t.length < 6) { continue; }
      var score = t[0] === 'N/A' ? null : parseFloat(t[0]);
      if (score === null && t[0] !== 'N/A') { continue; }
      if (score !== null && isNaN(score)) { continue; }
      var where = t[t.length - 1];
      if (!/:([0-9]+)$/.test(where)) { continue; }
      rows.push({
        score: score,
        method: t[t.length - 2],
        file: where.slice(0, where.lastIndexOf(':'))
      });
    }
    return rows;
  }

  // True when an analyze row's file refers to the edited path (analyze runs
  // from the project root; edited paths may be relative or absolute).
  function rowMatches(rowFile, edited) {
    var r = norm(rowFile);
    var p = norm(edited);
    if (r === p) { return true; }
    if (r.slice(-(p.length + 1)) === '/' + p) { return true; }
    if (p.slice(-(r.length + 1)) === '/' + r) { return true; }
    return r.slice(r.lastIndexOf('/') + 1) === p.slice(p.lastIndexOf('/') + 1);
  }

  function regressionLine(row, t) {
    return 'CRAP regression in ' + row.method + ': score ' + row.score.toFixed(2) +
      ' (max ' + t + ') — simplify or add tests';
  }

  // One aggregated check over every accumulated file: line counts per file +
  // CRAP rows from the full analyze. Returns undefined (nothing to report),
  // {append}, or the one-time missing-tool note.
  function checkFiles(files) {
    return readThreshold().then(function (t) {
      return runCrap().then(function (res) {
        if (!res || res.exitCode !== 0) {
          if (!looksMissing(res)) { return undefined; }
          if (missingToolNoted) { return undefined; } // E17: noted once, then idle
          missingToolNoted = true;
          return { append: MISSING_MSG };
        }
        var out = String(res.stdout || '') + '\n' + String(res.stderr || '');
        var rows = parseRows(out);
        // Coverage is stale when the analyze report has complexity-only rows
        // (CRAP column 'N/A') or explicitly says coverage is missing.
        var stale = rows.some(function (r) { return r.score === null; }) ||
          /coverage[^\n]*(missing|stale|not found|unavailable)|no coverage/i.test(out);
        return Promise.all(files.map(function (p) {
          return ext.fs.readFile(p).then(function (c) { return c; }, function () { return null; });
        })).then(function (contents) {
          var lines = [];
          var flagged = 0;
          for (var f = 0; f < files.length; f += 1) {
            var path = files[f];
            var before = lines.length;
            var content = contents[f];
            if (content !== null) {
              var n = String(content).split('\n').length;
              if (n > MAX_LINES) {
                lines.push(path + ': ' + n + ' lines (max ' + MAX_LINES + ') — split the file');
              }
            }
            for (var r = 0; r < rows.length; r += 1) {
              var row = rows[r];
              if (row.score !== null && row.score > t && rowMatches(row.file, path)) {
                lines.push(regressionLine(row, t));
              }
            }
            if (lines.length > before) { flagged += 1; }
          }
          if (stale && lines.length > 0 && !coverageNoted) {
            coverageNoted = true;
            lines.push('(complexity-only: coverage stale)');
          }
          if (lines.length === 0) { return undefined; }
          return { append: flagged + ' files over threshold: ' + lines.join('; ') };
        });
      });
    });
  }

  ext.onHook('afterToolCall', function (payload) {
    var p = payload || {};
    if (p.isError) { return undefined; }
    if (p.tool !== 'write' && p.tool !== 'edit') { return undefined; }
    var args = p.args || {};
    var path = typeof args.path === 'string' ? args.path : '';
    if (!path || !isGuarded(path)) { return undefined; }
    editsCount += 1;
    checkedFiles.add(path);
    var now = Date.now();
    if (now - lastCheckAt < DEBOUNCE_MS) { return undefined; } // burst: accumulate
    lastCheckAt = now;
    var files = Array.from(checkedFiles);
    checkedFiles.clear();
    return checkFiles(files);
  });

  ext.onHook('onSessionEnd', function () {
    // Guard: a session with no guarded edits never runs the full analyze.
    if (checkedFiles.size === 0 && editsCount === 0) { return undefined; }
    return readThreshold().then(function (t) {
      return runCrap().then(function (res) {
        if (!res || res.exitCode !== 0) {
          if (!looksMissing(res)) { return undefined; }
          if (missingToolNoted) { return undefined; } // E17: one note, then idle
          missingToolNoted = true;
          return ext.session.appendNote(MISSING_MSG);
        }
        var out = String(res.stdout || '') + '\n' + String(res.stderr || '');
        var rows = parseRows(out);
        var offenders = [];
        var methods = [];
        for (var i = 0; i < rows.length; i += 1) {
          if (rows[i].score !== null && rows[i].score > t) {
            offenders.push(regressionLine(rows[i], t));
            methods.push(rows[i].method);
          }
        }
        if (offenders.length === 0) { return undefined; }
        return ext.session.appendNote('crap-guard session report:\n' + offenders.join('\n'))
          .then(function () {
            return ext.session.enqueueFollowUp(
              'CRAP regressions: ' + methods.join(', ') + ' — fix before next session'
            );
          });
      });
    });
  });
})(globalThis);
