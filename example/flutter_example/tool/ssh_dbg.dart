import 'dart:io';
import 'package:flutter_agent_example/git_smart_http.dart';

void main() async {
  final pem = File('/tmp/fah_ssh_test_key').readAsStringSync();
  final tmp = Directory('/tmp/fah_ssh_dbg2');
  if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  tmp.createSync(recursive: true);
  final transport = SshGitTransport(
    host: 'github.com',
    username: 'git',
    repoPath: '/IstiN/fah-git-test.git',
    privateKeyPem: pem,
  );
  try {
    final branch = await GitSmartHttp(transport: transport).cloneInto(
      url: 'git@github.com:IstiN/fah-git-test.git',
      hostDir: tmp.path,
    );
    print('OK branch=$branch entries=${tmp.listSync().length}');
  } catch (e, st) {
    print('FAILED: $e');
    print(st.toString().split('\n').take(10).join('\n'));
  }
}
