// parity-fixture main.js (issue #32): one extension exercising EVERY bridge
// family — tools, hooks (all six events), slash commands, provider flows,
// session notes, fs reads, exec runs, io writes, and capability probes.
//
// ES2020, no modules; touches only jsr.ext.*, __extEngineId, and JSON so it
// runs identically on every engine adapter (qjs, flutter_js, worker, fake).
// The Dart mirror of every behavior here lives in parity_contract.dart; the
// engine suites prove the two never drift.
(function (g) {
  'use strict';
  var ext = g.jsr.ext;
  var engineId = g.__extEngineId; // captured at load; per-transport identity

  function firstLine(text) {
    return String(text).split('\n')[0];
  }

  ext.registerTool({
    name: 'parity_echo',
    description: 'parity: engine identity + capability probe + fs read + echo',
    schema: { type: 'object', properties: { text: { type: 'string' } } },
    tier: 'read',
    call: function (args) {
      var text = args && typeof args.text === 'string' ? args.text : '';
      return ext.has('fs').then(function (hasFs) {
        return ext.fs.readFile('parity_data.txt').then(function (content) {
          return {
            content: [{
              type: 'text',
              text: 'engine=' + engineId +
                ' has_fs=' + hasFs +
                ' file=' + firstLine(content) +
                ' echo=' + text
            }]
          };
        });
      });
    }
  });

  ext.registerTool({
    name: 'parity_exec',
    description: 'parity: runs `echo ok` through the exec bridge',
    schema: { type: 'object', properties: {} },
    call: function () {
      return ext.exec.run({ command: 'echo', args: ['ok'] }).then(function (res) {
        return { text: String(res.stdout).trim() };
      });
    }
  });

  ext.registerSlashCommand('parity-slash', {
    description: 'parity: writes its args back',
    run: function (args, io) {
      io.writeln('slash:' + args.join(','));
    }
  });

  ext.menus.registerProviderFlow({
    id: 'parity-flow',
    title: 'Parity Provider',
    description: 'parity: flow submit contract',
    fields: [{ name: 'token', label: 'Token', secret: true }],
    onSubmit: function (values) {
      return {
        providerName: 'parity',
        baseUrl: 'https://x.test',
        apiKey: values.token
      };
    }
  });

  ext.onHook('beforeToolCall', function (payload) {
    var p = payload || {};
    if (p.args && p.args.block === 'yes') {
      return { block: true, reason: 'parity-block' };
    }
    return undefined;
  });

  ext.onHook('afterToolCall', function (payload) {
    var p = payload || {};
    if (p.tool === 'parity_echo') {
      return { append: '[appended by parity]' };
    }
    return undefined;
  });

  ext.onHook('prepareNextTurn', function () { return undefined; });
  ext.onHook('onSteering', function () { return undefined; });

  ext.onHook('onSessionStart', function () {
    return ext.session.appendNote('parity note onSessionStart');
  });
  ext.onHook('onSessionEnd', function () {
    return ext.session.appendNote('parity note onSessionEnd');
  });
})(globalThis);
