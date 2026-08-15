/// `fah serve --a2a` — mounts the pure-Dart [A2aRequestHandler] over HTTP
/// (Phase 5b). localhost-only by default; bearer auth when a token is given.
///
/// IO lives here (bin/) per the repo rule: `lib/` stays pure Dart, the HTTP
/// transport is the adapter the handler expects.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Starts an A2A HTTP server on [port] (localhost only) and blocks until
/// interrupted. [runner] processes each user message through the local agent.
Future<void> runA2aServer({
  required A2aAgentRunner runner,
  required String agentName,
  required String agentDescription,
  int port = 8300,
  String? token,
}) async {
  final handler = A2aRequestHandler(
    runner: runner,
    agentName: agentName,
    agentDescription: agentDescription,
    token: token,
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('a2a server listening on http://127.0.0.1:$port');
  stdout.writeln('agent card: http://127.0.0.1:$port/.well-known/agent.json');
  if (token != null) stdout.writeln('auth: Bearer <token>');
  await for (final request in server) {
    await _handleRequest(request, handler);
  }
}

Future<void> _handleRequest(
  HttpRequest request,
  A2aRequestHandler handler,
) async {
  try {
    if (request.method == 'GET' &&
        request.uri.path == '/.well-known/agent.json') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(handler.agentCardJson());
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/') {
      final body = await utf8.decoder.bind(request).join();
      final authHeader = request.headers.value('authorization');
      final responseBody = await handler.handle(body, authHeader: authHeader);
      request.response
        ..headers.contentType = ContentType.json
        ..write(responseBody);
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.notFound
      ..write('not found');
    await request.response.close();
  } on Object catch (error) {
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write('error: $error');
    await request.response.close();
  }
}
