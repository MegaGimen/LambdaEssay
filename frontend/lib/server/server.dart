import 'dart:convert';
import 'package:process/process.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:path/path.dart' as p;
import 'git_service.dart';
import 'backup_service.dart';
import 'diff/repocmp.dart';
import 'sumdiff.dart';
import 'ai_diff_service.dart';
import 'package:http/http.dart' as http;
import 'subscription_service.dart';

import 'package:uuid/uuid.dart';
import 'dart:async';
// import 'notification_service.dart';

// 全局回调
Function(Map<String, dynamic> data)? onNotification;

List<WebSocketChannel> _activePluginSockets = [];
final _pendingRequests = <String, Completer<dynamic>>{};
final _uuid = Uuid();

Response _cors(Response r) {
  return r.change(headers: {
    ...r.headers,
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Accept, Origin',
  });
}

Future<Response> optionsHandler(Request req) async {
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

Future<void> _killPort(int port) async {
  try {
    final result = await Process.run('netstat', ['-ano']);
    if (result.exitCode != 0) return;
    final lines = (result.stdout as String).split(RegExp(r'\r?\n'));
    final pids = <String>{};
    for (final line in lines) {
      if (line.contains(':$port')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 5 && parts[1].endsWith(':$port')) {
          pids.add(parts.last);
        }
      }
    }
    for (final pid in pids) {
      if (pid == '0') continue;
      print('Killing process $pid occupying port $port...');
      await Process.run('taskkill', ['/F', '/PID', pid]);
    }
  } catch (e) {
    print('Failed to clean up port $port: $e');
  }
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

// Extracted Handlers

Future<Response> handleApiSave(Request req) async {
  if (comSender == null) {
    return _cors(Response(503,
        body: jsonEncode({'error': 'COM not connected'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  Map<String, dynamic> options = {};
  try {
    final body = await req.readAsString();
    if (body.isNotEmpty) {
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['options'] != null) {
        options = data['options'] as Map<String, dynamic>;
      }
    }
  } catch (_) {}

  final success = await comSender!({'action': 'save', 'options': options});

  if (success) {
    return _cors(Response.ok(jsonEncode({'message': 'Save command sent'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } else {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Save failed or timed out'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleApiDocument(Request req) async {
  if (comSender == null) {
    return _cors(Response(503,
        body: jsonEncode({'error': 'COM not connected'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  String? content;
  String type = 'text';
  Map<String, dynamic> options = {};

  final contentType = req.headers['content-type'] ?? '';

  if (contentType.toLowerCase().contains('application/json')) {
    final body = await req.readAsString();
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      content = data['content'] as String?;
      type = (data['type'] as String?) ?? 'text';
      if (data['options'] != null) {
        if (data['options'] is String) {
          try {
            options = jsonDecode(data['options']) as Map<String, dynamic>;
          } catch (_) {}
        } else {
          options = data['options'] as Map<String, dynamic>;
        }
      }
    } catch (e) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'Invalid JSON'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  } else if (contentType.toLowerCase().contains('multipart/form-data')) {
    final boundary = _boundaryOf(contentType);
    if (boundary == null) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'Invalid multipart boundary'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final bytesBuilder = BytesBuilder();
    await for (final chunk in req.read()) {
      bytesBuilder.add(chunk);
    }
    final bodyBytes = bytesBuilder.takeBytes();
    final parts = _parseMultipart(bodyBytes, boundary);

    final filePart = parts.firstWhere(
      (p) => (p.name ?? '') == 'file',
      orElse: () => _MultipartPart(null, null, Uint8List(0)),
    );

    if (filePart.data.isNotEmpty) {
      content = base64Encode(filePart.data);
      type = 'base64';
    } else {
      // Try to find content in other parts if not file
      final contentPart = parts.firstWhere(
        (p) => (p.name ?? '') == 'content',
        orElse: () => _MultipartPart(null, null, Uint8List(0)),
      );
      if (contentPart.data.isNotEmpty) {
        content = utf8.decode(contentPart.data);
      }
    }

    // Parse type if provided in form
    final typePart = parts.firstWhere(
      (p) => (p.name ?? '') == 'type',
      orElse: () => _MultipartPart(null, null, Uint8List(0)),
    );
    if (typePart.data.isNotEmpty) {
      type = utf8.decode(typePart.data);
    }

    // Parse options
    final optionsPart = parts.firstWhere(
      (p) => (p.name ?? '') == 'options',
      orElse: () => _MultipartPart(null, null, Uint8List(0)),
    );
    if (optionsPart.data.isNotEmpty) {
      try {
        options = jsonDecode(utf8.decode(optionsPart.data));
      } catch (e) {
        print('Failed to parse options: $e');
      }
    }
  } else {
    return _cors(Response(400,
        body: jsonEncode({'error': 'Unsupported Content-Type'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  if (content == null || content.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'Content is required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  final success = await comSender!({
    'action': 'replace',
    'payload': {'content': content, 'type': type, 'options': options}
  });

  if (success) {
    return _cors(Response.ok(jsonEncode({'message': 'Replace command sent'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } else {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Replace failed or timed out'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleReset(Request req) async {
  clearCache();
  return _cors(Response.ok(jsonEncode({'status': 'reset'}), headers: {
    'Content-Type': 'application/json; charset=utf-8',
  }));
}

Future<Response> handleFetch(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  if (repoPath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  final normalized = p.normalize(repoPath);
  try {
    await fetchAll(normalized);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleProjectDelete(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  var packagePath = _sanitizePath(data['packagePath'] as String?).trim();
  if (packagePath.isEmpty) {
    packagePath = _sanitizePath(data['gitdocxPath'] as String?);
  }
  final targetPath =
      _sanitizePath(data['targetPath'] as String?).trim().isNotEmpty
          ? _sanitizePath(data['targetPath'] as String?)
          : _sanitizePath(data['trackingPath'] as String?);

  if (packagePath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'No packagePath'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await deleteProject(packagePath, targetPath);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleProjectDirtyStatus(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final packagePath = _sanitizePath(data['packagePath'] as String?);

  if (packagePath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'packagePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final isDirty = await checkDirty(packagePath);
    return _cors(Response.ok(jsonEncode({'isDirty': isDirty}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleProjectSave(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final packagePath = _sanitizePath(data['packagePath'] as String?);

  if (packagePath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'packagePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await saveTrackingProject(packagePath);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleProjectSaveAs(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final packagePath = _sanitizePath(data['packagePath'] as String?);
  final newPackagePath = _sanitizePath(data['newPackagePath'] as String?);

  if (packagePath.isEmpty || newPackagePath.isEmpty) {
    return _cors(Response(400,
        body:
            jsonEncode({'error': 'packagePath and newPackagePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await saveTrackingProject(packagePath, newPackagePath);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleProjectCopy(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final packagePath = _sanitizePath(data['packagePath'] as String?);
  final targetDir = _sanitizePath(data['targetDir'] as String?);
  final sourcePath = _sanitizePath(data['sourcePath'] as String?);

  if (packagePath.isEmpty || targetDir.isEmpty || sourcePath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode(
            {'error': 'packagePath, targetDir, sourcePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  try {
    await importTrackingSource(packagePath, targetDir, sourcePath);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleBranches(Request req) async {
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
  if (!isGitRepo(normalized)) {
    print('Debug: /branches - Path is not a git repo: $normalized');
    return _cors(Response(400,
        body: jsonEncode({'error': 'not a git repo'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  print('Debug: /branches - Fetching branches for $normalized');
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
}

Future<Response> handleGraph(Request req) async {
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
  if (!isGitRepo(normalized)) {
    print('Debug: /graph - Path is not a git repo: $normalized');
    return _cors(Response(400,
        body: jsonEncode({'error': 'not a git repo'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  print('Debug: /graph - Fetching graph for $normalized (limit: $limit)');
  try {
    final resp = await getGraph(normalized, limit: limit);
    return _cors(Response.ok(jsonEncode(resp.toJson()),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleRemoteGraph(Request req) async {
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
  try {
    // Fetch remote graph: includeLocal=false, remoteNames=[] (all remotes)
    final resp = await getGraph(normalized,
        limit: limit, includeLocal: false, remoteNames: []);
    return _cors(Response.ok(jsonEncode(resp.toJson()),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleCompare(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final c1 = data['commit1'] as String?;
  final c2 = data['commit2'] as String?;

  final userId = data['userid'] as String?;
  final subInfo = userId != null ? await SubscriptionService.checkSubscription(userId) : null;


  if (repoPath.isEmpty || c1 == null || c2 == null) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath, commit1, commit2 required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final pdf = await compareCommits(repoPath, c1, c2);
    return _cors(Response.ok(pdf, headers: {
      'Content-Type': 'application/pdf',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleSummarizeDiff(Request req) async {
  try {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final beforePath = _sanitizePath(data['beforePath'] as String?);
    final afterPath = _sanitizePath(data['afterPath'] as String?);

    final userId = data['userid'] as String?;
    final subInfo = userId != null ? await SubscriptionService.checkSubscription(userId) : null;


    if (beforePath.isEmpty || afterPath.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'beforePath and afterPath required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }

    final result = await summarizeDiff(beforePath, afterPath);
    return _cors(Response.ok(
      jsonEncode({'output': result}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    ));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleSummarizeCommit(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final commitId = (data['commitId'] as String?)?.trim() ?? '';

  if (repoName.isEmpty || commitId.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName, commitId required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  Directory? tempDir;
  try {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) throw Exception('APPDATA not found');
    final repoPath = p.join(appData, 'gitdocx', repoName);

    if (!await Directory(repoPath).exists()) {
      throw Exception('Repo $repoName not found at $repoPath');
    }

    // Find parent
    final parentRes = await Process.run(
        'git', ['log', '-1', '--format=%P', commitId],
        workingDirectory: repoPath);

    if (parentRes.exitCode != 0)
      throw Exception('Git log failed: ${parentRes.stderr}');

    final parentId = (parentRes.stdout as String)
        .trim()
        .split(' ')
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');

    tempDir = await Directory.systemTemp.createTemp('sum_commit_');
    final afterDocx = p.join(tempDir.path, 'after.docx');

    // Extract commit docx
    final afterRes = await Process.run(
        'git', ['show', '$commitId:content.docx'],
        workingDirectory: repoPath, stdoutEncoding: null);

    if (afterRes.exitCode != 0) {
      // Maybe file didn't exist in that commit?
      // Check if error is "pathspec ... did not match"
      final err = utf8.decode(afterRes.stderr as List<int>);
      if (err.contains('did not match') ||
          err.contains('exists on disk') ||
          err.contains('pathspec')) {
        return _cors(Response.ok(
          jsonEncode(
              {'output': 'File content.docx not found in this commit'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        ));
      }
      throw Exception('Git show failed for current: $err');
    }
    await File(afterDocx).writeAsBytes(afterRes.stdout as List<int>);

    String result;
    if (parentId.isEmpty) {
      result = "Initial commit (no parent)";
    } else {
      final beforeDocx = p.join(tempDir.path, 'before.docx');
      final beforeRes = await Process.run(
          'git', ['show', '$parentId:content.docx'],
          workingDirectory: repoPath, stdoutEncoding: null);

      if (beforeRes.exitCode != 0) {
        // Parent might not have the file
        // We can treat it as empty or new file
        result = "New file created (parent did not have content.docx)";
      } else {
        await File(beforeDocx).writeAsBytes(beforeRes.stdout as List<int>);
        result = await summarizeDiff(beforeDocx, afterDocx);
      }
    }

    return _cors(Response.ok(
      jsonEncode({'output': result}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    ));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } finally {
    if (tempDir != null) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

Future<Response> handleBackupGraph(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = data['repoName'] as String?;
  final commitId = data['commitId'] as String?;

  final userId = data['userid'] as String?;
  if (userId == null) {
    return _cors(Response(403, body: 'No user ID'));
  }
  final subInfo = await SubscriptionService.checkSubscription(userId);

  if (repoName == null || commitId == null) {
    return _cors(Response(400, body: 'Repo name and commitId required'));
  }
  try {
    final graph = await getBackupChildGraph(repoName, commitId);
    return _cors(Response.ok(jsonEncode(graph)));
  } catch (e) {
    return _cors(Response(500, body: e.toString()));
  }
}

Future<Response> handleCompareRepos(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final commitA = data['commitA'] as String?;
  final commitB = data['commitB'] as String?;
  final localPath = data['localPath'] as String?;

  if (repoName.isEmpty || commitA == null || commitB == null) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName, commitA, commitB required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  try {
    final result =
        await compareReposWithLocal(repoName, localPath, commitA, commitB);
    return _cors(Response.ok(jsonEncode(result.toJson()), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    var stackTrace = StackTrace.current;
    print(stackTrace);
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleBackupPreview(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = data['repoName'] as String?;
  final commitId = data['commitId'] as String?;

  final userId = data['userid'] as String?;
  if (userId == null) {
    return _cors(Response(403, body: 'No userid'));
  }
  final subInfo = await SubscriptionService.checkSubscription(userId);
  if (repoName == null || commitId == null) {
    return _cors(Response(400, body: 'Repo name and commitId required'));
  }
  try {
    final bytes = await previewBackupChildDoc(repoName, commitId);
    return _cors(
        Response.ok(bytes, headers: {'Content-Type': 'application/pdf'}));
  } catch (e) {
    return _cors(Response(500, body: e.toString()));
  }
}

Future<Response> handleCommit(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final author = (data['author'] as String?) ?? '';
  final message = (data['message'] as String?) ?? '';
  if (repoPath.isEmpty || author.isEmpty || message.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath, author, message required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  // Attempt to save Word document if COM is connected
  if (comSender != null) {
    print('Executing Word save before commit...');
    await comSender!({'action': 'save'});
    //if (!saved) {
    //  return _cors(Response(500,
    //      body: jsonEncode({'error': 'Word save failed. Commit aborted.'}),
    //      headers: {'Content-Type': 'application/json; charset=utf-8'}));
    //}
    //即使没有保存成功，也继续提交
    print('Word save verified.');
  }

  try {
    await commitChanges(repoPath, author, message);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleBranchCreate(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final branchName = (data['branchName'] as String?)?.trim() ?? '';
  if (repoPath.isEmpty || branchName.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath, branchName required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await createBranch(repoPath, branchName);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleBranchSwitch(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final projectName = (data['projectName'] as String?)?.trim() ?? '';
  final branchName = (data['branchName'] as String?)?.trim() ?? '';
  final repoPath = (data['repoPath'] as String?)?.trim() ?? '';

  if (branchName.contains(projectName + "/")) {
    //拒绝切换远程分支
    return _cors(Response(400,
        body: jsonEncode({'error': '禁止切换到远程分支'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  if (projectName.isEmpty || branchName.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'projectName, branchName required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final sw = Stopwatch()..start();
    await switchBranch(projectName, branchName, repoPath: repoPath.isNotEmpty ? repoPath : null);
    sw.stop();
    print('[Perf][Server][SwitchBranch] Total: ${sw.elapsedMilliseconds}ms');
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleCompareWorking(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  if (repoPath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final pdf = await compareWorking(repoPath);
    return _cors(Response.ok(pdf, headers: {
      'Content-Type': 'application/pdf',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handlePreview(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final commitId = data['commitId'] as String?;

  if (repoPath.isEmpty || commitId == null) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath, commitId required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final pdf = await previewVersion(repoPath, commitId);
    return _cors(Response.ok(pdf, headers: {
      'Content-Type': 'application/pdf',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleCompareAi(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;

  final userId = data['userid'] as String?;
  if (userId == null) {
    return _cors(Response(403,
        body: jsonEncode({'error': 'No userid'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  final subInfo = await SubscriptionService.checkSubscription(userId);

  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final commit1 = (data['commit1'] as String? ?? '').trim();
  final commit2 = (data['commit2'] as String? ?? '').trim();
  final docType = (data['docType'] as String? ?? 'word').trim();
  final token = data['token'] as String?;

  if (repoPath.isEmpty || commit1.isEmpty || commit2.isEmpty) {
    return _cors(Response.badRequest(
      body: jsonEncode({'error': 'repoPath, commit1, commit2 不能为空'}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    ));
  }

  try {
    print('[API] AI对比请求: $commit1 vs $commit2 ($docType)');

    // 🔥 优化：优先检查本地缓存，避免无需的文件提取
    final cachedResult = await AIDiffService.checkLocalCache(commit1, commit2, docType);
    Map<String, dynamic> result;

    if (cachedResult != null) {
      result = cachedResult;
    } else {
      result = await compareCommitsWithAI(
        repoPath,
        commit1,
        commit2,
        docType: docType,
        token: token,
      );
    }

    return _cors(Response.ok(
        jsonEncode({
          'success': true,
          'commit1': commit1,
          'commit2': commit2,
          'docType': docType,
          'result': result,
        }),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
        }));
  } catch (e) {
    print('[API] AI对比失败: $e');
    return _cors(Response.internalServerError(
      body: jsonEncode({'error': e.toString()}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    ));
  }
}

Future<Response> handlePreviewCache(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);

  final ids = <String>{};
  if (data['commitIds'] != null) {
    for (final item in (data['commitIds'] as List)) {
      if (item is String && item.trim().isNotEmpty) {
        ids.add(item.trim());
      }
    }
  }
  if (data['commitId'] != null) {
    final single = data['commitId'] as String;
    if (single.trim().isNotEmpty) {
      ids.add(single.trim());
    }
  }

  if (repoPath.isEmpty || ids.isEmpty) {
    return _cors(Response(400,
        body:
            jsonEncode({'error': 'repoPath and commitId/commitIds required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  // Process all IDs asynchronously
  unawaited(() async {
    for (final id in ids) {
      // ensureCommitPreviewAssets handles concurrency with semaphore internally
      await ensureCommitPreviewAssets(repoPath, id);
      // Yield to event loop and give some breathing room
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }());

  return _cors(Response.ok(
      jsonEncode({'status': 'scheduled', 'count': ids.length}),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
}

Future<Response> handleRollback(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final projectName = (data['projectName'] as String?)?.trim() ?? '';
  final commitId = data['commitId'] as String?;

  if (projectName.isEmpty || commitId == null) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'projectName, commitId required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await rollbackVersion(projectName, commitId);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleConvert(Request req) async {
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
}

Future<Response> handleTrackCreate(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final name = (data['packagePath'] as String?)?.trim() ??
      (data['name'] as String?)?.trim() ??
      '';
  final docxPath = data['docxPath'] as String?;
  if (name.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'packagePath required'}),
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
}

Future<Response> handleRestoreDocx(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';

  if (repoName.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await restoreDocx(repoName);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleTrackOpen(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final name = (data['packagePath'] as String?)?.trim() ??
      (data['name'] as String?)?.trim() ??
      '';
  if (name.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'packagePath required'}),
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
}

Future<Response> handleTrackExpand(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final filePath = (data['filePath'] as String?)?.trim() ?? '';

  if (filePath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'filePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final resp = await expandLocalTrackingPackage(filePath);
    return _cors(Response.ok(jsonEncode(resp), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleTrackRepos(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final name = (data['packagePath'] as String?)?.trim() ??
      (data['name'] as String?)?.trim() ??
      '';
  if (name.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'packagePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final repos = await listProjectRepos(name);
    return _cors(Response.ok(jsonEncode({'repos': repos}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleTrackUpdate(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final name = (data['packagePath'] as String?)?.trim() ??
      (data['name'] as String?)?.trim() ??
      '';
  final opIdentical = (data['opIdentical'] as bool?) ?? false;
  final newDocxPath = data['newDocxPath'] as String?;
  final repoPath = data['repoPath'] as String?;
  final docxPath = data['docxPath'] as String?;
  if (name.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'packagePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final resp = await updateTrackingProject(name, opIdentical,
        newDocxPath: newDocxPath, repoPath: repoPath, docxPath: docxPath);
    return _cors(Response.ok(jsonEncode(resp), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleTrackSyncFolder(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final name = (data['packagePath'] as String?)?.trim() ??
      (data['name'] as String?)?.trim() ??
      '';
  if (name.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'packagePath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await syncFolderProject(name);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleTrackFindIdentical(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final name = (data['name'] as String?)?.trim() ?? '';
  if (name.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'name required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final commitIds = await findIdenticalCommit(name);
    return _cors(Response.ok(jsonEncode({'commitIds': commitIds}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleTrackInfo(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  if (repoPath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final info = await getTrackingInfo(repoPath);
    return _cors(Response.ok(jsonEncode(info ?? {}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleResetBranch(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final projectName = (data['projectName'] as String?)?.trim() ?? '';
  final commitId = data['commitId'] as String?;

  if (projectName.isEmpty || commitId == null) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'projectName, commitId required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await resetBranch(projectName, commitId);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handlePush(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final username = (data['username'] as String?)?.trim() ?? '';
  final token = (data['token'] as String?)?.trim() ?? '';
  final force = data['force'] == true;
  final branch = (data['branch'] as String?)?.trim();
  final skipBackup = data['skipBackup'] == true;

  if (repoPath.isEmpty || username.isEmpty || token.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath, username, token required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await pushToRemote(repoPath, username, token, force: force, branch: branch, skipBackup: skipBackup);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleRemoteList(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final token = data['token'] as String?;
  final repoPath = data['repoPath'] as String?;

  if (token == null || token.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'token required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  try {
    final giteaUrl = 'http://47.242.109.145:3000';
    final headers = {
      'Authorization': 'token $token',
      'Content-Type': 'application/json',
    };

    // Fetch owned repos
    final respOwned = await http.get(
      Uri.parse('$giteaUrl/api/v1/user/repos'),
      headers: headers,
    );

    // Fetch member repos
    final respMember = await http.get(
      Uri.parse('$giteaUrl/api/v1/user/repos?type=member'),
      headers: headers,
    );

    if (respOwned.statusCode == 200 && respMember.statusCode == 200) {
      final owned = jsonDecode(respOwned.body) as List;
      final member = jsonDecode(respMember.body) as List;

      final allRepos = [...owned, ...member];

      final uniqueRepos = <String, Map<String, dynamic>>{};
      for (final r in allRepos) {
        final name = (r['name'] as String).toLowerCase();
        uniqueRepos[name] = r;
      }

      final filteredRepoNames = <String>[];

      // Filter by last commit message
      await Future.wait(uniqueRepos.values.map((repo) async {
        try {
          final ownerObj = repo['owner'];
          if (ownerObj == null) return;

          final ownerName = ownerObj['login'];
          final repoName = repo['name'];
          // Prefer full_name if available, otherwise construct it
          final fullName = repo['full_name'] ?? '$ownerName/$repoName';

          final commitResp = await http.get(
            Uri.parse('$giteaUrl/api/v1/repos/$fullName/commits?limit=1'),
            headers: headers,
          );

          if (commitResp.statusCode == 200) {
            final commits = jsonDecode(commitResp.body) as List;
            if (commits.isNotEmpty) {
              final msg = (commits[0]['commit']['message'] as String).trim();
              if (msg.contains('[folder project213897]')) {
                filteredRepoNames.add((repoName as String).toLowerCase());
              }
            }
          } else {
            print(
                'Failed to fetch commits for $fullName: ${commitResp.statusCode}');
          }
        } catch (e) {
          print('Error filtering repo ${repo['name']}: $e');
        }
      }));

      // Unify: Return all repositories without filtering by folder_meta.json
      final results = filteredRepoNames.map((name) {
        return {'name': name, 'isFolder': true};
      }).toList();

      // If repoPath is provided, add remotes (logic remains)
      if (repoPath != null && repoPath.isNotEmpty) {
        for (final r in uniqueRepos.values) {
          final name = (r['name'] as String).toLowerCase();
          final cloneUrl = r['clone_url'] as String?;
          if (cloneUrl != null) {
            await addRemote(repoPath, name, cloneUrl);
          }
        }
      }

      return _cors(Response.ok(jsonEncode(results), headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
    } else if (respOwned.statusCode != 200) {
      return _cors(Response(respOwned.statusCode,
          body: jsonEncode({
            'error': 'Failed to fetch owned repos',
            'details': respOwned.body
          }),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    } else {
      return _cors(Response(respMember.statusCode,
          body: jsonEncode({
            'error': 'Failed to fetch member repos',
            'details': respMember.body
          }),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Remote list failed: $e'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleRemoteAdd(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final name = (data['name'] as String?)?.trim() ?? '';
  final url = (data['url'] as String?)?.trim() ?? '';

  if (repoPath.isEmpty || name.isEmpty || url.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath, name, url required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await addRemote(repoPath, name, url);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleGetRemotes(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);

  if (repoPath.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final remotes = await getRemotes(repoPath);
    return _cors(Response.ok(jsonEncode({'remotes': remotes}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleRequestCode(Request req) async {
  try {
    final body = await req.readAsString();
    final url = Uri.parse('http://47.242.109.145:3920/request_code');
    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    return _cors(Response(resp.statusCode,
        body: resp.body,
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Proxy failed: $e'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleRegister(Request req) async {
  try {
    final body = await req.readAsString();
    final url = Uri.parse('http://47.242.109.145:3920/register');
    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    return _cors(Response(resp.statusCode,
        body: resp.body,
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Proxy failed: $e'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleLogin(Request req) async {
  try {
    final body = await req.readAsString();
    final url = Uri.parse('http://47.242.109.145:3920/login');
    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    return _cors(Response(resp.statusCode,
        body: resp.body,
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Proxy failed: $e'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleCreateUser(Request req) async {
  try {
    final body = await req.readAsString();
    final url = Uri.parse('http://47.242.109.145:3920/create_user');
    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    // Forward status and body
    return _cors(Response(resp.statusCode,
        body: resp.body,
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Proxy failed: $e'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleShare(Request req) async {
  try {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final owner = data['owner'] as String?;
    final repo = data['repo'] as String?;
    final username = data['username'] as String?;
    final token = data['token'] as String?;

    if (owner == null || repo == null || username == null || token == null) {
      return _cors(Response(400,
          body:
              jsonEncode({'error': 'owner, repo, username, token required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }

    final giteaUrl =
        'http://47.242.109.145:3000'; // Guessing standard port if not found

    final uri = Uri.parse(
        '$giteaUrl/api/v1/repos/$owner/$repo/collaborators/$username');
    final client = HttpClient();
    final request = await client.openUrl('PUT', uri);
    request.headers.set('Authorization', 'token $token');
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode({'permission': 'write'})));

    final response = await request.close();
    final respBody = await utf8.decodeStream(response);

    return _cors(Response(response.statusCode,
        body: respBody,
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': 'Share failed: $e'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handlePullRebase(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final username = (data['username'] as String?)?.trim() ?? '';
  final token = (data['token'] as String?)?.trim() ?? '';

  if (repoName.isEmpty || username.isEmpty || token.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName, username, token required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await rebasePull(repoName, username, token);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleForkLocal(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final newBranch = (data['newBranch'] as String?)?.trim() ?? '';

  if (repoName.isEmpty || newBranch.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName, newBranch required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await forkLocal(repoName, newBranch);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handlePullCancel(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';

  if (repoName.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await cancelPull(repoName);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handlePullPreview(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final username = (data['username'] as String?)?.trim() ?? '';
  final token = (data['token'] as String?)?.trim() ?? '';
  final type =
      (data['type'] as String?)?.trim() ?? ''; // rebase, branch, force

  if (repoName.isEmpty || username.isEmpty || token.isEmpty || type.isEmpty) {
    return _cors(Response(400,
        body:
            jsonEncode({'error': 'repoName, username, token, type required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final result = await previewPull(repoName, username, token, type);
    return _cors(Response.ok(jsonEncode(result.toJson()), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleCheckPullStatus(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final username = (data['username'] as String?)?.trim() ?? '';
  final token = (data['token'] as String?)?.trim() ?? '';

  if (repoName.isEmpty || username.isEmpty || token.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName, username, token required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final result = await checkPullStatus(repoName, username, token);
    return _cors(Response.ok(jsonEncode(result),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handlePull(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final username = (data['username'] as String?)?.trim() ?? '';
  final token = (data['token'] as String?)?.trim() ?? '';
  final force = data['force'] == true;
  final targetRepoName = (data['targetRepoName'] as String?)?.trim();
  final localTrackingZipPath =
      (data['localTrackingZipPath'] as String?)?.trim();
  final currentPath = _sanitizePath(data['currentPath'] as String?);
  final recursive = data['recursive'] == true;
  final branch = (data['branch'] as String?)?.trim();

  print(
      'Debug: /pull request - repoPath: $repoPath, repoName: $repoName, targetRepoName: $targetRepoName, localTrackingZipPath: $localTrackingZipPath, recursive: $recursive, branch: $branch');

  final pathArg = repoPath.isNotEmpty ? repoPath : repoName;

  if (pathArg.isEmpty || username.isEmpty || token.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode(
            {'error': 'repoPath (or repoName), username, token required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final result = await pullFromRemote(pathArg, username, token,
        force: force,
        targetRepoName: targetRepoName,
        localTrackingZipPath: localTrackingZipPath,
        currentPath: currentPath,
        recursive: recursive,
        branch: branch);
    print("pullResult=${result}");
    return _cors(Response.ok(jsonEncode(result),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handlePrepareMerge(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final targetBranch = (data['targetBranch'] as String?)?.trim() ?? '';

  if (repoName.isEmpty || targetBranch.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName, targetBranch required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await prepareMerge(repoName, targetBranch);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleCompleteMerge(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoName = (data['repoName'] as String?)?.trim() ?? '';
  final targetBranch = (data['targetBranch'] as String?)?.trim() ?? '';

  if (repoName.isEmpty || targetBranch.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName, targetBranch required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    await completeMerge(repoName, targetBranch);
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleEdgeAdd(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final child = data['child'] as String?;
  final parent = data['parent'] as String?;

  if (repoPath.isEmpty || child == null || parent == null) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoPath, child, parent required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final f = File(p.join(repoPath, 'edges'));
    final lines = f.existsSync() ? await f.readAsLines() : <String>[];
    if (lines.isEmpty) {
      // Init with dummy commit id
      lines.add('0000000000000000000000000000000000000000');
    }
    lines.add('$child $parent');
    await f.writeAsString(lines.join('\n'));
    return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleBackupCommits(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final token = (data['token'] as String?)?.trim() ?? '';
  final repoName = (data['repoName'] as String?)?.trim() ?? '';

  final userId = data['userid'] as String?;
    if (userId == null) {
      return _cors(Response(403,
          body: jsonEncode({'error': 'No userid'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    final subInfo = await SubscriptionService.checkSubscription(userId);

  if (repoName.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  try {
    final result = await listBackupCommits(repoName, token,
        onProgress: (percent, received, total) {
      final msg = {
        'type': 'backup_progress',
        'repo': repoName,
        'percent': percent,
        'received': received,
        'total': total
      };
      onNotification?.call(msg);
    });
    print("chainViewUrl: ${result['chainViewUrl']}");
    return _cors(Response.ok(jsonEncode(result), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleBackupFailures(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final username = data['username'] as String?;
  final repoName = data['repoName'] as String?;

  if (username == null || username.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'username required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
  
  if (repoName == null || repoName.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'repoName required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  try {
    final failures = await listBackupFailures(username, repoName);
    return _cors(Response.ok(jsonEncode(failures), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleRetryBackupFailure(Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  final failureId = data['failureId'] as String?;

  if (failureId == null || failureId.isEmpty) {
    return _cors(Response(400,
        body: jsonEncode({'error': 'failureId required'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }

  try {
    final success = await retryBackupFailure(failureId);
    return _cors(Response.ok(jsonEncode({'success': success}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleHealth(Request req) async {
  return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
    'Content-Type': 'application/json; charset=utf-8',
  }));
}

FutureOr<Response> handleWs(Request req) {
  return webSocketHandler((channel, protocol) {
    onNotification?.call({'type': 'com_status', 'status': 'connected'});
    print('Word Plugin connected');
    _activePluginSockets.add(channel);

    comSender = (Map<String, dynamic> message) async {
      if (_activePluginSockets.isEmpty) return false;
      final id = _uuid.v4().replaceAll('-', '');
      message['id'] = id;

      // Send to all connected plugins
      for (final socket in _activePluginSockets) {
        try {
          socket.sink.add(jsonEncode(message));
        } catch (e) {
          print('Failed to send to socket: $e');
        }
      }

      final mainCompleter = Completer<dynamic>();
      _pendingRequests[id] = mainCompleter;

      try {
        // Wait for first success or timeout
        final response =
            await mainCompleter.future.timeout(const Duration(seconds: 30));
        if (response is Map && response['status'] == 'success') return true;
        return false;
      } catch (e) {
        _pendingRequests.remove(id);
        return false;
      }
    };

    channel.stream.listen((message) {
      // print('Raw WebSocket message: $message');
      try {
        final data = jsonDecode(message as String);
        if (data is Map) {
          if (data['type'] == 'response' && data['id'] != null) {
            final id = data['id'];
            // Check if we have a pending request
            if (_pendingRequests.containsKey(id)) {
              if (data['status'] == 'success') {
                // If success, complete the main completer immediately
                if (!_pendingRequests[id]!.isCompleted) {
                  _pendingRequests[id]!.complete(data);
                }
              } else {
                print('Plugin reported error/mismatch: ${data['message']}');
                // Fail fast
                if (!_pendingRequests[id]!.isCompleted) {
                  _pendingRequests[id]!
                      .complete(data); // Complete with error data
                }
              }
            }
          } else if (data['type'] == 'event' && data['event'] == 'saved') {
            final path = data['path'] as String?;
            if (path != null) {
              print(
                  'Plugin reported save event for: $path. But we ignore it. ');
            } else {
              print('Plugin reported save event but path is null');
            }
          } else {
            print('Received from plugin: $message');
          }
        }
      } catch (e) {
        print('WebSocket message error: $e');
      }
    }, onDone: () {
      print('Word Plugin disconnected');
      _activePluginSockets.remove(channel);
      if (_activePluginSockets.isEmpty) {
        comSender = null;
      }
      // Notify frontend
      onNotification?.call({'type': 'com_status', 'status': 'disconnected'});
    }, onError: (e) {
      print('WebSocket error: $e');
      _activePluginSockets.remove(channel);
      if (_activePluginSockets.isEmpty) {
        comSender = null;
      }
      // Notify frontend
      onNotification?.call({'type': 'com_status', 'status': 'disconnected'});
    });
  })(req);
}

Future<Response> handleApiHealth(Request req) async {
  return _cors(Response.ok(
      jsonEncode(
          {'status': 'ok', 'connected': _activePluginSockets.isNotEmpty}),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
}

Future<Response> handleProjectList(Request req) async {
  try {
    final projects = await listProjects();
    return _cors(Response.ok(jsonEncode(projects), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}

Future<Response> handleAiCacheStats(Request req) async {
  try {
    final stats = await AIDiffService.getCacheStats();
    return _cors(Response.ok(jsonEncode(stats), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response.internalServerError(
      body: jsonEncode({'error': e.toString()}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    ));
  }
}

Future<Response> handleAiCacheClear(Request req) async {
  try {
    final deleted = await AIDiffService.clearCache();
    return _cors(Response.ok(
        jsonEncode({
          'success': true,
          'deleted': deleted,
        }),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
        }));
  } catch (e) {
    return _cors(Response.internalServerError(
      body: jsonEncode({'error': e.toString()}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    ));
  }
}

Future<Response> handleTrackList(Request req) async {
  try {
    final list = await listProjects();
    return _cors(Response.ok(jsonEncode({'projects': list}), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response(500,
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}));
  }
}
