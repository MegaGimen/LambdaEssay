import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:path/path.dart' as p;
import '../lib/git_service.dart';
import '../lib/models.dart';

Response _cors(Response r) {
  return r.change(headers: {
    ...r.headers,
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
}

Future<Response> _optionsHandler(Request req) async {
  return _cors(Response.ok(''));
}

Future<void> main(List<String> args) async {
  final router = Router();

  router.get('/health', (Request req) async {
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  });

  router.options('/<ignored|.*>', _optionsHandler);

  router.post('/branches', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoPath = data['repoPath'] as String?;
    if (repoPath == null || repoPath.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'repoPath required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final normalized = p.normalize(repoPath);
    final dir = Directory(normalized);
    if (!dir.existsSync()) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'path not found'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final gitDir = Directory(p.join(normalized, '.git'));
    if (!gitDir.existsSync()) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'not a git repo'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      final branches = await getBranches(normalized);
      return _cors(Response.ok(
          jsonEncode({'branches': branches.map((b) => b.toJson()).toList()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  router.post('/graph', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoPath = data['repoPath'] as String?;
    final limit = data['limit'] is int ? data['limit'] as int : null;
    if (repoPath == null || repoPath.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'repoPath required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final normalized = p.normalize(repoPath);
    final dir = Directory(normalized);
    if (!dir.existsSync()) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'path not found'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final gitDir = Directory(p.join(normalized, '.git'));
    if (!gitDir.existsSync()) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'not a git repo'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      final resp = await getGraph(normalized, limit: limit);
      return _cors(Response.ok(jsonEncode(resp.toJson()),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  final handler =
      const Pipeline().addMiddleware(logRequests()).addHandler(router);
  final server = await serve((req) async => _cors(await handler(req)),
      InternetAddress.loopbackIPv4, 8080);
  stdout.writeln(
      'Server listening on http://${server.address.host}:${server.port}');
}
