// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'paths.dart';

/// The error/exit pair a utility driver turns into a `_StageResult`.
typedef CommandError = ({String message, int exitCode});

/// The parsed `tar` command line: operation flags, archive, members.
typedef TarInvocation = ({
  bool create,
  bool extract,
  bool compressed,
  String? archiveArg,
  List<String> members,
  String? changeDir,
  CommandError? error,
});

/// Parses the `tar` argument list (pure): old-style `cf` bundling, `-f`,
/// `-C`, and members.
TarInvocation parseTarArgs(List<String> args) {
  if (args.isEmpty) {
    return _tarError('tar: no operation specified\n');
  }
  var index = 0;
  var flags = '';
  final first = args.first;
  if (first.startsWith('-')) {
    flags = first.substring(1);
    index = 1;
  } else if (RegExp(r'^[a-zA-Z]+$').hasMatch(first) &&
      first.contains(RegExp(r'[ctx]'))) {
    // Old-style `tar cf ...` without a dash.
    flags = first;
    index = 1;
  }
  final create = flags.contains('c');
  final extract = flags.contains('x');
  final compressed = flags.contains('z');
  if (create == extract) {
    return _tarError('tar: specify exactly one of -c or -x\n');
  }

  String? archiveArg;
  if (flags.contains('f')) {
    if (index >= args.length) {
      return _tarError('tar: option requires an argument -- f\n');
    }
    archiveArg = args[index++];
  }
  String? changeDir;
  final members = <String>[];
  for (; index < args.length; index++) {
    final arg = args[index];
    if (arg == '-C' && index + 1 < args.length) {
      changeDir = args[++index];
    } else {
      members.add(arg);
    }
  }
  if (archiveArg == null) {
    return _tarError('tar: no archive file specified (use -f)\n');
  }
  return (
    create: create,
    extract: extract,
    compressed: compressed,
    archiveArg: archiveArg,
    members: members,
    changeDir: changeDir,
    error: null,
  );
}

TarInvocation _tarError(String message) => (
  create: false,
  extract: false,
  compressed: false,
  archiveArg: null,
  members: const [],
  changeDir: null,
  error: (message: message, exitCode: 2),
);

/// Adds [resolved] (and its children when it is a directory) to [archive],
/// stripping the leading `/` from member names like GNU tar does.
Future<void> addArchiveEntry(
  MemoryFileSystem fs,
  Archive archive,
  String resolved,
  FileInfo info,
) async {
  final name = resolved.startsWith('/') ? resolved.substring(1) : resolved;
  if (info.kind == FileKind.directory) {
    archive.addFile(ArchiveFile('$name/', 0, const <int>[])..isFile = false);
    final entries = await fs.listDir(resolved);
    for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
      await addArchiveEntry(fs, archive, '$resolved/${entry.name}', entry);
    }
    return;
  }
  final data = await fs.readBinaryFile(resolved);
  if (data.isErr) return;
  final bytes = data.valueOrNull!;
  archive.addFile(ArchiveFile(name, bytes.length, bytes));
}

/// Creates the archive at `parsed.archiveArg` from `parsed.members`
/// (`tar c`, optionally gzip-compressed).
Future<CommandError?> createTarArchive(
  MemoryFileSystem fs,
  String cwd,
  TarInvocation parsed,
) async {
  final members = parsed.members;
  if (members.isEmpty) {
    return (
      message: 'tar: Cowardly refusing to create an empty archive\n',
      exitCode: 2,
    );
  }
  final archive = Archive();
  for (final member in members) {
    final resolved = resolveSandboxPath(member, cwd);
    final info = await fs.fileInfo(resolved);
    if (info.isErr) {
      return (
        message: 'tar: $member: Cannot stat: No such file or directory\n',
        exitCode: 1,
      );
    }
    await addArchiveEntry(fs, archive, resolved, info.valueOrNull!);
  }
  var bytes = TarEncoder().encode(archive);
  if (parsed.compressed) bytes = GZipEncoder().encode(bytes);
  await fs.writeBinaryFile(
    resolveSandboxPath(parsed.archiveArg!, cwd),
    Uint8List.fromList(bytes),
  );
  return null;
}

/// Extracts `parsed.archiveArg` into the sandbox (`tar x`, optionally
/// gzip-compressed, honoring `-C`).
Future<CommandError?> extractTarArchive(
  MemoryFileSystem fs,
  String cwd,
  TarInvocation parsed,
) async {
  final archivePath = resolveSandboxPath(parsed.archiveArg!, cwd);
  final read = await fs.readBinaryFile(archivePath);
  if (read.isErr) {
    return (
      message:
          'tar: ${parsed.archiveArg}: Cannot open: No such file or directory\n',
      exitCode: 1,
    );
  }
  var bytes = read.valueOrNull!;
  if (parsed.compressed) {
    try {
      bytes = Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
    } on Object {
      return (
        message: 'tar: ${parsed.archiveArg}: not in gzip format\n',
        exitCode: 1,
      );
    }
  }
  final Archive archive;
  try {
    archive = TarDecoder().decodeBytes(bytes);
  } on Object {
    return (
      message: 'tar: ${parsed.archiveArg}: not in tar format\n',
      exitCode: 1,
    );
  }
  final root = parsed.changeDir != null
      ? resolveSandboxPath(parsed.changeDir!, cwd)
      : resolveSandboxPath('.', cwd);
  for (final file in archive.files) {
    final name = file.name.startsWith('/') ? file.name.substring(1) : file.name;
    if (!file.isFile) {
      await fs.createDir('$root/$name');
      continue;
    }
    await fs.writeBinaryFile('$root/$name', file.content);
  }
  return null;
}

/// The parsed `gzip`/`gunzip` command line.
typedef GzipInvocation = ({
  bool unpack,
  bool keep,
  List<String> files,
  CommandError? error,
});

/// Parses the `gzip`/`gunzip` argument list (pure).
GzipInvocation parseGzipArgs(List<String> args, {required bool decompress}) {
  var unpack = decompress;
  var keep = false;
  final files = <String>[];
  for (final arg in args) {
    if (arg == '-d' || arg == '--decompress' || arg == '--uncompress') {
      unpack = true;
    } else if (arg == '-k' || arg == '--keep') {
      keep = true;
    } else if (RegExp(r'^-[1-9]$').hasMatch(arg)) {
      // Compression level; irrelevant for the in-memory subset.
    } else if (arg.startsWith('-') && arg != '-') {
      return (
        unpack: unpack,
        keep: keep,
        files: files,
        error: (message: 'gzip: unsupported option $arg\n', exitCode: 1),
      );
    } else {
      files.add(arg);
    }
  }
  return (unpack: unpack, keep: keep, files: files, error: null);
}

/// Compresses/decompresses `parsed.files` in place in the sandbox.
Future<CommandError?> runGzip(
  MemoryFileSystem fs,
  String cwd,
  GzipInvocation parsed,
) async {
  final name = parsed.unpack ? 'gunzip' : 'gzip';
  if (parsed.files.isEmpty) {
    return (message: '$name: missing operand\n', exitCode: 1);
  }
  for (final arg in parsed.files) {
    final resolved = resolveSandboxPath(arg, cwd);
    final read = await fs.readBinaryFile(resolved);
    if (read.isErr) {
      return (message: '$name: $arg: No such file or directory\n', exitCode: 1);
    }
    if (!parsed.unpack) {
      final encoded = GZipEncoder().encode(read.valueOrNull!);
      await fs.writeBinaryFile('$resolved.gz', Uint8List.fromList(encoded));
      if (!parsed.keep) await fs.remove(resolved);
      continue;
    }
    if (!resolved.endsWith('.gz')) {
      return (message: 'gzip: $arg: unknown suffix -- ignored\n', exitCode: 1);
    }
    final List<int> decoded;
    try {
      decoded = GZipDecoder().decodeBytes(read.valueOrNull!);
    } on Object {
      return (message: 'gzip: $arg: not in gzip format\n', exitCode: 1);
    }
    final dest = resolved.substring(0, resolved.length - 3);
    await fs.writeBinaryFile(dest, Uint8List.fromList(decoded));
    if (!parsed.keep) await fs.remove(resolved);
  }
  return null;
}

/// The parsed `zip` command line.
typedef ZipInvocation = ({
  bool recursive,
  List<String> positionals,
  CommandError? error,
});

/// Parses the `zip` argument list (pure).
ZipInvocation parseZipArgs(List<String> args) {
  var recursive = false;
  final positionals = <String>[];
  for (final arg in args) {
    if (arg.startsWith('-') && arg != '-') {
      if (arg.contains('r') || arg.contains('R')) recursive = true;
      // Other flags (quiet, compression level, ...) are accepted and
      // ignored by this subset.
    } else {
      positionals.add(arg);
    }
  }
  if (positionals.length < 2) {
    return (
      recursive: recursive,
      positionals: positionals,
      error: (
        message:
            'zip error: Nothing to do! (usage: zip [-r] archive.zip file...)\n',
        exitCode: 1,
      ),
    );
  }
  return (recursive: recursive, positionals: positionals, error: null);
}

/// Zips `positionals[1..]` into the archive `positionals[0]`.
Future<CommandError?> runZip(
  MemoryFileSystem fs,
  String cwd,
  ZipInvocation parsed,
) async {
  final archivePath = resolveSandboxPath(parsed.positionals.first, cwd);
  final archive = Archive();
  for (final member in parsed.positionals.sublist(1)) {
    final resolved = resolveSandboxPath(member, cwd);
    final info = await fs.fileInfo(resolved);
    if (info.isErr) {
      return (
        message:
            'zip error: Nothing to do! ($member: No such file or directory)\n',
        exitCode: 1,
      );
    }
    final fileInfo = info.valueOrNull!;
    if (fileInfo.kind == FileKind.directory && !parsed.recursive) {
      return (
        message: 'zip error: Nothing to do! ($member is a directory; use -r)\n',
        exitCode: 1,
      );
    }
    await addArchiveEntry(fs, archive, resolved, fileInfo);
  }
  final bytes = ZipEncoder().encode(archive);
  await fs.writeBinaryFile(archivePath, Uint8List.fromList(bytes));
  return null;
}
