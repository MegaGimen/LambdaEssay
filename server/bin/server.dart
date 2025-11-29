import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:path/path.dart' as p;
import '../lib/git_service.dart';

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

String _sanitizePath(String? raw) {
  var t = (raw ?? '').trim();
  if (t.isEmpty) return '';
  if ((t.startsWith('"') && t.endsWith('"')) ||
      (t.startsWith('\'') && t.endsWith('\''))) {
    t = t.substring(1, t.length - 1);
  }
  t = t.replaceAll(RegExp(r'[>]+$'), '').trim();
  if (t.startsWith('file://')) {
    try {
      final uri = Uri.parse(t);
      t = uri.toFilePath(windows: true);
    } catch (_) {}
  }
  return t;
}

Future<void> main(List<String> args) async {
  await initTrackingService();
  final router = Router();

  router.get('/health', (Request req) async {
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  });

  router.post('/reset', (Request req) async {
    clearCache();
    return _cors(Response.ok(jsonEncode({'status': 'reset'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  });

  router.options('/<ignored|.*>', _optionsHandler);

  router.post('/branches', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoPath = _sanitizePath(data['repoPath'] as String?);
    if (repoPath.isEmpty) {
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
    final repoPath = _sanitizePath(data['repoPath'] as String?);
    final limit = data['limit'] is int ? data['limit'] as int : null;
    if (repoPath.isEmpty) {
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

  router.post('/convert', (Request req) async {
    final ct = req.headers['content-type'] ?? '';
    final b = _boundaryOf(ct);
    if (b == null) {
      return _cors(Response(400,
          body:
              jsonEncode({'error': 'content-type must be multipart/form-data'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final bytesBuilder = BytesBuilder();
    await for (final chunk in req.read()) {
      bytesBuilder.add(chunk);
    }
    final body = bytesBuilder.takeBytes();
    final parts = _parseMultipart(body, b);
    final filePart = parts.firstWhere(
        (p) => (p.name ?? '').toLowerCase() == 'file',
        orElse: () => _MultipartPart(null, null, Uint8List(0)));
    if (filePart.name == null || filePart.data.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'file part missing'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final tmp = await Directory.systemTemp.createTemp('docx_convert_');
    try {
      final uploadName = (filePart.filename?.trim().isNotEmpty == true)
          ? filePart.filename!
          : 'upload.docx';
      final inPath = p.join(tmp.path, uploadName);
      await File(inPath).writeAsBytes(filePart.data, flush: true);
      final scriptPath = p.fromUri(Platform.script);
      final repoRoot = p.dirname(p.dirname(p.dirname(scriptPath)));
      final soffice = p.join(repoRoot, 'frontend', 'LibreOfficePortable', 'App',
          'libreoffice', 'program', 'soffice.exe');
      final outDir = tmp.path;
      final result = await Process.run(soffice,
          ['--headless', '--convert-to', 'pdf', '--outdir', outDir, inPath]);
      final outName = p.setExtension(p.basename(inPath), '.pdf');
      final outPath = p.join(outDir, outName);
      if (result.exitCode != 0 || !File(outPath).existsSync()) {
        return _cors(Response(500,
            body: jsonEncode({
              'error': 'convert failed',
              'code': result.exitCode,
              'stderr': (result.stderr ?? '').toString()
            }),
            headers: {'Content-Type': 'application/json; charset=utf-8'}));
      }
      final pdf = await File(outPath).readAsBytes();
      return _cors(Response.ok(pdf, headers: {
        'Content-Type': 'application/pdf',
      }));
    } finally {
      try {
        if (tmp.existsSync()) {
          tmp.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  });

  router.post('/track/create', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final name = (data['name'] as String?)?.trim() ?? '';
    final docxPath = data['docxPath'] as String?;
    if (name.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'name required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      final resp = await createTrackingProject(name, docxPath);
      return _cors(Response.ok(jsonEncode(resp), headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  router.post('/track/open', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final name = (data['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'name required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      final resp = await openTrackingProject(name);
      return _cors(Response.ok(jsonEncode(resp), headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  router.post('/track/update', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final name = (data['name'] as String?)?.trim() ?? '';
    final newDocxPath = data['newDocxPath'] as String?;
    if (name.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'name required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      final resp = await updateTrackingProject(name, newDocxPath: newDocxPath);
      return _cors(Response.ok(jsonEncode(resp), headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
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

class _MultipartPart {
  final String? name;
  final String? filename;
  final Uint8List data;
  _MultipartPart(this.name, this.filename, this.data);
}

String? _boundaryOf(String contentType) {
  final lower = contentType.toLowerCase();
  if (!lower.startsWith('multipart/form-data')) return null;
  final i = lower.indexOf('boundary=');
  if (i < 0) return null;
  var v = contentType.substring(i + 9).trim();
  if ((v.startsWith('"') && v.endsWith('"')) ||
      (v.startsWith("'") && v.endsWith("'"))) {
    v = v.substring(1, v.length - 1);
  }
  return v;
}

int _indexOf(Uint8List data, Uint8List pattern, int start) {
  for (int i = start; i <= data.length - pattern.length; i++) {
    var ok = true;
    for (int j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

List<_MultipartPart> _parseMultipart(Uint8List body, String boundary) {
  final parts = <_MultipartPart>[];
  final b = Uint8List.fromList(utf8.encode('--$boundary'));
  final crlf = Uint8List.fromList([13, 10]);
  final dbl = Uint8List.fromList([13, 10, 13, 10]);
  var cursor = _indexOf(body, b, 0);
  if (cursor < 0) return parts;
  while (true) {
    final afterB = cursor + b.length;
    final isFinal = afterB + 1 < body.length &&
        body[afterB] == 45 &&
        body[afterB + 1] == 45;
    if (isFinal) break;
    final lineEnd = _indexOf(body, crlf, afterB);
    if (lineEnd < 0) break;
    final headersStart = lineEnd + 2;
    final headersEnd = _indexOf(body, dbl, headersStart);
    if (headersEnd < 0) break;
    final headersBytes = body.sublist(headersStart, headersEnd);
    final headers = latin1.decode(headersBytes).split('\r\n');
    String? name;
    String? filename;
    for (final h in headers) {
      final hl = h.toLowerCase();
      if (hl.startsWith('content-disposition')) {
        final segs = h.split(';');
        for (final s in segs) {
          final t = s.trim();
          if (t.startsWith('name=')) {
            name = _stripQuotes(t.substring(5));
          } else if (t.startsWith('filename=')) {
            filename = _stripQuotes(t.substring(9));
          }
        }
      }
    }
    final dataStart = headersEnd + 4;
    final next = _indexOf(body, b, dataStart);
    if (next < 0) break;
    var dataEnd = next;
    if (dataEnd - 2 >= 0 &&
        body[dataEnd - 2] == 13 &&
        body[dataEnd - 1] == 10) {
      dataEnd -= 2;
    }
    final dataBytes = body.sublist(dataStart, dataEnd);
    parts.add(_MultipartPart(name, filename, Uint8List.fromList(dataBytes)));
    cursor = next;
    final maybeFinal = cursor + b.length + 1 < body.length &&
        body[cursor + b.length] == 45 &&
        body[cursor + b.length + 1] == 45;
    if (maybeFinal) break;
  }
  return parts;
}

String _stripQuotes(String v) {
  var t = v.trim();
  if ((t.startsWith('"') && t.endsWith('"')) ||
      (t.startsWith("'") && t.endsWith("'"))) {
    t = t.substring(1, t.length - 1);
  }
  return t;
}
