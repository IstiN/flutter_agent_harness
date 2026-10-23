// SPDX-License-Identifier: Apache-2.0
//
// Node-parity pack tests (Buffer / URL / console / os / process / Intl):
// every expectation mirrors real Node.js behavior (v22) for the covered
// subset — these are the shapes scripts and AI feature-guards rely on.
//
// Run: dart test test/node_compat_parity_test.dart
import 'dart:convert';

import 'package:quickjs_runtime/src/node_compat.dart';
import 'package:quickjs_runtime/src/quickjs_runtime.dart';
import 'package:test/test.dart';

void main() {
  late QuickjsRuntime rt;
  final logs = <String>[];

  Object? js(String code) {
    final r = rt.eval(code, filename: '<test>');
    return r == null ? null : jsonDecode(r);
  }

  setUp(() {
    logs.clear();
    rt = QuickjsRuntime();
    installNodeCompat(
      rt,
      NodeCompatConfig(
        consoleSink: (level, message) => logs.add('$level|$message'),
        env: {'HOME': '/home/dev', 'TEMP': 'C:\\tmp'},
        scriptPath: '/proj/scripts/main.js',
      ),
    );
  });
  tearDown(() => rt.close());

  group('Buffer', () {
    test('is a real Uint8Array subclass, like Node', () {
      expect(js('''
        (function () {
          var b = Buffer.from('hi');
          return {
            iB: b instanceof Buffer,
            iU: b instanceof Uint8Array,
            tag: Object.prototype.toString.call(b),
            len: b.length,
            b0: b[0],
            json: JSON.stringify(b)
          };
        })()
      '''), {
        'iB': true,
        'iU': true,
        'tag': '[object Uint8Array]',
        'len': 2,
        'b0': 104,
        'json': '{"type":"Buffer","data":[104,105]}',
      });
    });

    test('encodings round-trip byte-faithfully', () {
      expect(js('''
        (function () {
          var utf8 = Buffer.from('héllo');
          var utf16 = Buffer.from('AB', 'utf16le');
          var hex = Buffer.from('68656c6c6f', 'hex');
          var b64 = Buffer.from('aGVsbG8=', 'base64');
          var b64u = Buffer.from('aGVsbG8', 'base64url');
          return {
            utf8Len: utf8.length,
            utf8Hex: utf8.toString('hex'),
            utf16: utf16.toString('hex'),
            hexStr: hex.toString(),
            b64Str: b64.toString(),
            b64uStr: b64u.toString(),
            hexUpper: hex.toString('hex').toUpperCase(),
            asciiTrunc: Buffer.from('€', 'ascii').length,
            latin1: Buffer.from('é', 'latin1').toString('hex')
          };
        })()
      '''), {
        // 'héllo' utf-8: 6 bytes
        'utf8Len': 6,
        'utf8Hex': '68c3a96c6c6f',
        'utf16': '41004200',
        'hexStr': 'hello',
        'b64Str': 'hello',
        'b64uStr': 'hello',
        // Node toString('hex') is lowercase
        'hexUpper': '68656C6C6F',
        // ascii truncates high bit → 1 byte
        'asciiTrunc': 1,
        // é latin1 → 0xe9
        'latin1': 'e9',
      });
    });

    test('alloc/allocUnsafe/concat/byteLength/compare', () {
      expect(js('''
        (function () {
          var a = Buffer.alloc(3);
          var f = Buffer.alloc(3, 7);
          var c = Buffer.concat([Buffer.from('ab'), Buffer.from('cd')]);
          return {
            a: a.toString('hex'),
            f: f.toString('hex'),
            c: c.toString(),
            byteLen: Buffer.byteLength('héllo'),
            byteLenB64: Buffer.byteLength('aGVsbG8=', 'base64'),
            cmp: Buffer.compare(Buffer.from('ab'), Buffer.from('ac')),
            eq: Buffer.from('x').equals(Buffer.from('x')),
            isB: Buffer.isBuffer(c),
            isNot: Buffer.isBuffer('nope')
          };
        })()
      '''), {
        'a': '000000',
        'f': '070707',
        'c': 'abcd',
        'byteLen': 6,
        'byteLenB64': 5,
        'cmp': -1,
        'eq': true,
        'isB': true,
        'isNot': false,
      });
    });

    test('instance write/fill/copy/indexOf/read-write LE-BE', () {
      expect(js('''
        (function () {
          var b = Buffer.alloc(9);
          b.write('he', 0);
          b.write('y', 2);
          b.fill(0, 3, 5);
          b.writeUInt32LE(0x64636261, 5);
          var r = {
            str: b.toString('latin1'),
            idx: b.indexOf('y'),
            idxNone: b.indexOf('z'),
            idxNum: Buffer.from([1, 2, 3]).indexOf(2),
            inc: b.includes('he')
          };
          var n = Buffer.alloc(4);
          n.writeUInt16BE(0x1234, 0);
          r.be = n.toString('hex');
          r.u16le = Buffer.from([0x34, 0x12]).readUInt16LE(0);
          r.u16be = n.readUInt16BE(0);
          var f32 = Buffer.alloc(4);
          f32.writeFloatLE(1.5, 0);
          r.f32 = f32.readFloatLE(0);
          return r;
        })()
      '''), {
        'str': 'hey\x00\x00abcd',
        'idx': 2,
        'idxNone': -1,
        'idxNum': 1,
        'inc': true,
        'be': '12340000',
        'u16le': 0x1234,
        'u16be': 0x1234,
        'f32': 1.5,
      });
    });

    test('Buffer.from(arrayBuffer) views; Buffer.from(buffer) copies', () {
      expect(js('''
        (function () {
          var src = Buffer.from('abcd');
          var copy = Buffer.from(src);
          copy[0] = 88;
          var ab = new ArrayBuffer(4);
          var view = Buffer.from(ab);
          view[1] = 9;
          var raw = new Uint8Array(ab);
          return { src: src.toString(), rawB1: raw[1], viewLen: view.length,
            slice: src.slice(1, 3).toString(),
            sub: src.subarray(1, 3).toString(),
            toJSON: JSON.stringify(copy.toJSON()) };
        })()
      '''), {
        'src': 'abcd',
        // Buffer.from(ab) is a VIEW: writing through it mutates the source
        'rawB1': 9,
        'viewLen': 4,
        'slice': 'bc',
        'sub': 'bc',
        'toJSON': '{"type":"Buffer","data":[88,98,99,100]}',
      });
    });

    test('require("buffer") works like the Node module', () {
      expect(js('require("buffer").Buffer.from("ok").toString()'), 'ok');
    });
  });

  group('URL', () {
    test('special schemes: default ports, empty path, origin', () {
      expect(js('''
        (function () {
          var u = new URL('http://Example.COM');
          var s = new URL('https://a.b:443/x');
          var p = new URL('https://a.b:8443/x');
          return {
            href: u.href,
            host: u.host,
            hostname: u.hostname,
            pathname: u.pathname,
            origin: u.origin,
            sHref: s.href,
            pOrigin: p.origin,
            pPort: p.port
          };
        })()
      '''), {
        'href': 'http://example.com/',
        'host': 'example.com',
        'hostname': 'example.com',
        'pathname': '/',
        'origin': 'http://example.com',
        'sHref': 'https://a.b/x',
        'pOrigin': 'https://a.b:8443',
        'pPort': '8443',
      });
    });

    test('accessors round-trip like Node', () {
      expect(js('''
        (function () {
          var u = new URL('http://user:pw@h:99/p?q=1#f');
          var r = {
            proto: u.protocol, user: u.username, pw: u.password,
            search: u.search, hash: u.hash, href: u.href
          };
          u.port = 8080;
          r.portSet = u.href;
          u.search = 'a=2';
          r.searchSet = u.href;
          u.hash = '';
          r.hashSet = u.href;
          u.protocol = 'https:';
          r.protoSet = u.href;
          return r;
        })()
      '''), {
        'proto': 'http:',
        'user': 'user',
        'pw': 'pw',
        'search': '?q=1',
        'hash': '#f',
        'href': 'http://user:pw@h:99/p?q=1#f',
        'portSet': 'http://user:pw@h:8080/p?q=1#f',
        'searchSet': 'http://user:pw@h:8080/p?a=2#f',
        'hashSet': 'http://user:pw@h:8080/p?a=2',
        'protoSet': 'https://user:pw@h:8080/p?a=2',
      });
    });

    test('relative resolution against base', () {
      expect(js('''
        (function () {
          var b = 'http://h/a/b/c?q=1#z';
          return {
            abs: new URL('/x', b).href,
            rel: new URL('d', b).href,
            dot: new URL('../d', b).href,
            scheme: new URL('//other/x', b).href,
            q: new URL('?a=2', b).href,
            h: new URL('#w', b).href,
            empty: new URL('', b).href
          };
        })()
      '''), {
        'abs': 'http://h/x',
        'rel': 'http://h/a/b/d',
        'dot': 'http://h/a/d',
        'scheme': 'http://other/x',
        'q': 'http://h/a/b/c?a=2',
        'h': 'http://h/a/b/c?q=1#w',
        'empty': 'http://h/a/b/c?q=1#z',
      });
    });

    test('URLSearchParams: codec and live binding', () {
      expect(js('''
        (function () {
          var u = new URL('http://h/p?x=1&x=2&y=a%20b');
          var r = {
            get: u.searchParams.get('x'),
            all: u.searchParams.getAll('x'),
            has: u.searchParams.has('y'),
            y: u.searchParams.get('y')
          };
          u.searchParams.append('z', 'c d');
          r.afterAppend = u.href;
          u.searchParams.delete('x');
          r.afterDelete = u.search;
          var sp = new URLSearchParams('a=1&b=two words');
          r.spString = sp.toString();
          r.spGet = sp.get('b');
          r.spSize = sp.size;
          sp.set('a', '9');
          r.spSet = sp.toString();
          sp.sort();
          var keys = [];
          sp.forEach(function (v, k) { keys.push(k + '=' + v); });
          r.spEach = keys.join(',');
          return r;
        })()
      '''), {
        'get': '1',
        'all': ['1', '2'],
        'has': true,
        'y': 'a b',
        'afterAppend': 'http://h/p?x=1&x=2&y=a+b&z=c+d',
        'afterDelete': '?y=a+b&z=c+d',
        'spString': 'a=1&b=two+words',
        'spGet': 'two words',
        'spSize': 2,
        'spSet': 'a=9&b=two+words',
        'spEach': 'a=9,b=two words',
      });
    });

    test('non-special schemes and file URLs', () {
      expect(js('''
        (function () {
          var o = new URL('foo://host');
          var f = new URL('file:///a/b.txt');
          return {
            oHref: o.href,
            oPath: o.pathname,
            oOrigin: o.origin,
            fHref: f.href,
            fOrigin: f.origin,
            fPath: f.pathname
          };
        })()
      '''), {
        'oHref': 'foo://host',
        'oPath': '',
        'oOrigin': 'null',
        'fHref': 'file:///a/b.txt',
        'fOrigin': 'null',
        'fPath': '/a/b.txt',
      });
    });

    test('canParse/parse, invalid throws TypeError', () {
      expect(js('''
        (function () {
          var thrown = null;
          try { new URL('not a url'); } catch (e) { thrown = e.name; }
          return {
            ok: URL.canParse('http://h/x'),
            bad: URL.canParse('nope'),
            base: URL.canParse('x', 'http://h/'),
            parsed: URL.parse('http://h/x') !== null,
            parsedBad: URL.parse('nope'),
            thrown: thrown
          };
        })()
      '''), {
        'ok': true,
        'bad': false,
        'base': true,
        'parsed': true,
        'parsedBad': null,
        'thrown': 'TypeError',
      });
    });

    test('require("url") module', () {
      expect(js('''
        (function () {
          var url = require('url');
          return {
            pathToFile: url.pathToFileURL('/a b/c.txt').href,
            fileToPath: url.fileURLToPath('file:///x/y.txt')
          };
        })()
      '''), {'pathToFile': 'file:///a%20b/c.txt', 'fileToPath': '/x/y.txt'});
    });
  });

  group('console', () {
    test('time/timeEnd formats like Node', () {
      js("console.time('x');");
      expect(js("console.timeEnd('x'); console.timeEnd('x');"), isNull);
      expect(logs.length, 2);
      expect(RegExp(r'^log\|x: [\d.]+ms$').hasMatch(logs[0]), isTrue);
      expect(logs[1], "warn|Timer 'x' does not exist");
    });

    test('count/countReset, group indentation, dir, table', () {
      js('''
        console.count('hit');
        console.count('hit');
        console.countReset('hit');
        console.count('hit');
        console.group('grp');
        console.log('inner');
        console.groupEnd();
        console.log('outer');
        console.dir({a: 1});
        console.table([{n: 1}, {n: 2}]);
      ''');
      expect(logs, contains('log|hit: 1'));
      expect(logs, contains('log|hit: 1'));
      expect(logs.where((l) => l == 'log|hit: 1').length, 2);
      expect(logs, contains('log|  inner'));
      expect(logs, contains('log|outer'));
      final dirLine = logs.firstWhere((l) => l.startsWith('log|{ a:'));
      expect(dirLine, 'log|{ a: 1 }');
      final table = logs.firstWhere((l) => l.contains('│ n'));
      expect(table, contains('│ 1 │'));
    });

    test('util.inspect is deep and readable (Node style)', () {
      expect(js("util.inspect({a: [1, 'x'], b: {c: null}})"),
          "{ a: [ 1, 'x' ], b: { c: null } }");
      expect(js("util.inspect(function named() {})"), '[Function: named]');
    });
  });

  group('os + process', () {
    test('require("os") node module', () {
      expect(js('''
        (function () {
          var os = require('os');
          return {
            eol: os.EOL,
            platform: os.platform(),
            type: os.type(),
            cpus: os.cpus().length,
            tmp: os.tmpdir(),
            home: os.homedir(),
            hostname: os.hostname(),
            loadavg: os.loadavg().length
          };
        })()
      '''), {
        'eol': '\n',
        'platform': 'linux',
        'type': 'Linux',
        'cpus': 1,
        'tmp': '/tmp',
        'home': '/home/dev',
        'hostname': 'localhost',
        'loadavg': 3,
      });
    });

    test('process.argv/pid/execPath/stdout.write', () {
      expect(js('''
        (function () {
          var ok = process.stdout.write('to-out');
          var ok2 = process.stderr.write('to-err');
          return { argv: process.argv, pid: process.pid > 0,
            exec: typeof process.execPath, ok: ok, ok2: ok2 };
        })()
      '''), {
        'argv': ['<runtime>', '/proj/scripts/main.js'],
        'pid': true,
        'exec': 'string',
        'ok': true,
        'ok2': true,
      });
      expect(logs, contains('log|to-out'));
      expect(logs, contains('error|to-err'));
    });

    test('hrtime tuple + bigint, uptime', () {
      expect(js('''
        (function () {
          var t = process.hrtime();
          var d = process.hrtime(t);
          var ns = process.hrtime.bigint();
          return { tuple: t.length, dLen: d.length,
            dTotal: d[0] * 1e9 + d[1] >= 0,
            nsType: typeof ns, up: process.uptime() >= 0 };
        })()
      '''), {
        'tuple': 2,
        'dLen': 2,
        'dTotal': true,
        'nsType': 'bigint',
        'up': true,
      });
    });

    test('process.on("exit") fires on exit()', () {
      js('''
        globalThis.__sawExit = 0;
        process.on('exit', function (code) { globalThis.__sawExit += 1; });
        try { process.exit(3); } catch (e) { globalThis.__exitErr = e.message; }
      ''');
      expect(js('({saw: __sawExit, err: __exitErr, code: process.exitCode})'), {
        'saw': 1,
        'err': 'ProcessExit: 3',
        'code': 0,
      });
    });

    test('__dirname/__filename follow scriptPath', () {
      expect(js('({f: __filename, d: __dirname})'),
          {'f': '/proj/scripts/main.js', 'd': '/proj/scripts'});
    });
  });

  group('Intl', () {
    test('typeof-safe constructors, call-time message', () {
      expect(js('''
        (function () {
          var msg = null;
          try { new Intl.NumberFormat('en-US').format(1); } catch (e) {
            msg = e.message;
          }
          return { t: typeof Intl, nf: typeof Intl.NumberFormat,
            canon: Intl.getCanonicalLocales('de-DE'),
            msg: msg !== null && msg.indexOf('Intl.NumberFormat') === 0 };
        })()
      '''), {
        't': 'object',
        'nf': 'function',
        'canon': ['de-DE'],
        'msg': true,
      });
    });
  });
}
