import 'dart:convert';
import 'package:process/process.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:path/path.dart' as p;
import '../lib/git_service.dart';
import '../lib/backup_service.dart';
import '../lib/diff/repocmp.dart';
import 'package:http/http.dart' as http;

Response _cors(Response r) {
  return r.change(headers: {
    ...r.headers,
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Accept, Origin',
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
final ProcessManager _processManager = const LocalProcessManager();
Future<void> main(List<String> args) async {
  final setGlobal = await Process.run(
      'git', ['config', '--global', 'core.autocrlf', 'false']);
  if (setGlobal.exitCode == 0) {
    print('✓ 已设置全局 core.autocrlf = false');
  } else {
    print('✗ 设置失败: ${setGlobal.stderr}');
  }
  // Start Heidegger service in background
  try {
    final scriptDir = p.dirname(Platform.script.toFilePath());
    final heideggerPath = p.join(scriptDir, 'Heidegger.exe');
    if (File(heideggerPath).existsSync()) {
      await _killPort(5000);
      print('Starting Heidegger service from $heideggerPath...');
      // 使用 PowerShell 启动 Heidegger.exe，完全隐藏窗口
      Process process = await _processManager.start(
        [
          'powershell',
          '-WindowStyle', 'Hidden',
          '-Command', 'Start-Process -FilePath "$heideggerPath" -WindowStyle Hidden'
        ],
        mode: ProcessStartMode.normal,
        runInShell: false
      );
    } else {
      print('Heidegger.exe not found at $heideggerPath');
    }
  } catch (e) {
    print('Failed to start Heidegger: $e');
  }
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

  router.post('/fetch', (Request req) async {
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
  });

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

  router.post('/remote_graph', (Request req) async {
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
      final resp = await getGraph(normalized, limit: limit, includeLocal: false, remoteNames: []);
      return _cors(Response.ok(jsonEncode(resp.toJson()),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  router.post('/compare', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoPath = _sanitizePath(data['repoPath'] as String?);
    final c1 = data['commit1'] as String?;
    final c2 = data['commit2'] as String?;

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
  });

  router.post('/backup/graph', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoName = data['repoName'] as String?;
    final commitId = data['commitId'] as String?;
    if (repoName == null || commitId == null) {
      return _cors(Response(400, body: 'Repo name and commitId required'));
    }
    try {
      final graph = await getBackupChildGraph(repoName, commitId);
      return _cors(Response.ok(jsonEncode(graph)));
    } catch (e) {
      return _cors(Response(500, body: e.toString()));
    }
  });

  router.post('/compare_repos', (Request req) async {
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
  });

  router.post('/backup/preview', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoName = data['repoName'] as String?;
    final commitId = data['commitId'] as String?;
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
  });

  router.post('/commit', (Request req) async {
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
  });

  router.post('/branch/create', (Request req) async {
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
  });

  router.post('/branch/switch', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final projectName = (data['projectName'] as String?)?.trim() ?? '';
    final branchName = (data['branchName'] as String?)?.trim() ?? '';
    if(branchName.contains(projectName+"/")){//拒绝切换远程分支
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
      await switchBranch(projectName, branchName);
      return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  router.post('/compare_working', (Request req) async {
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
  });

  router.post('/preview', (Request req) async {
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
  });

  router.post('/rollback', (Request req) async {
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

  router.post('/restore_docx', (Request req) async {
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

  router.post('/track/find_identical', (Request req) async {
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
  });

  router.post('/track/info', (Request req) async {
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
  });

  router.get('/track/list', (Request req) async {
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
  });

  router.post('/reset_branch', (Request req) async {
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
  });

  router.post('/push', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoPath = _sanitizePath(data['repoPath'] as String?);
    final username = (data['username'] as String?)?.trim() ?? '';
    final token = (data['token'] as String?)?.trim() ?? '';
    final force = data['force'] == true;

    if (repoPath.isEmpty || username.isEmpty || token.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'repoPath, username, token required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      await pushToRemote(repoPath, username, token, force: force);
      return _cors(Response.ok(jsonEncode({'status': 'ok'}), headers: {
        'Content-Type': 'application/json; charset=utf-8',
      }));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  router.post('/remote/list', (Request req) async {
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

        final repoNames = uniqueRepos.keys.toList();

        if (repoPath != null && repoPath.isNotEmpty) {
          for (final r in uniqueRepos.values) {
            final name = (r['name'] as String).toLowerCase();
            final cloneUrl = r['clone_url'] as String?;
            if (cloneUrl != null) {
              await addRemote(repoPath, name, cloneUrl);
            }
          }
        }

        return _cors(Response.ok(jsonEncode(repoNames), headers: {
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
  });

  router.post('/request_code', (Request req) async {
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
  });

  router.post('/register', (Request req) async {
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
  });

  router.post('/login', (Request req) async {
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
  });

  router.post('/create_user', (Request req) async {
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
  });

  router.post('/share', (Request req) async {
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

      // curl -X PUT "https://your-gitea.com/api/v1/repos/{owner}/{repo}/collaborators/{username}"
      // Gitea API: PUT /repos/{owner}/{repo}/collaborators/{collaborator}
      // https://try.gitea.io/api/swagger#/repository/repoAddCollaborator

      // User provided example:
      // https://your-gitea.com/api/v1/repos/{owner}/{repo}/collaborators/{username}
      // But our base URL is http://47.242.109.145:3920 ?
      // The previous endpoints were proxied to http://47.242.109.145:3920/...
      // I assume the Gitea instance is also there?
      // Wait, the user snippet says "https://your-gitea.com/api/v1/...".
      // But the server is at 47.242.109.145:3920 based on previous context.
      // I should check if 47.242.109.145:3920 IS the Gitea instance or just a wrapper?
      // Previous endpoints: /create_user -> http://47.242.109.145:3920/create_user
      // /list_repos -> http://47.242.109.145:3920/list_repos
      // These look like a wrapper service, not direct Gitea API.
      // Gitea API usually starts with /api/v1.
      //
      // However, the user explicitly asked to call:
      // curl -X PUT "https://your-gitea.com/api/v1/repos/{owner}/{repo}/collaborators/{username}" ...
      //
      // If 47.242.109.145:3920 is the custom backend, maybe it DOES NOT expose Gitea API directly?
      // Or maybe I should assume the user wants me to call the Gitea API directly from the server?
      // But I don't know the Gitea URL.
      //
      // Wait, the previous endpoints suggest 47.242.109.145:3920 is a python server (based on the user description in turn 1: "参考这个服务器端的指南...").
      // And it has endpoints like /create_user which creates Gitea user.
      // It probably wraps Gitea.
      //
      // But the instruction now is SPECIFIC about the curl command structure for adding collaborator.
      // It looks like a direct Gitea API call.
      // "https://your-gitea.com" is a placeholder.
      // I need to know the real Gitea URL.
      //
      // From the existing code in `server.dart`, I don't see the Gitea URL configured.
      // I only see `http://47.242.109.145:3920`.
      //
      // Let's assume the Gitea is at `http://47.242.109.145:3000` (standard port) or maybe `http://47.242.109.145:3920` IS the gitea?
      // No, `3920` has `/create_user`, `/register` etc which are not standard Gitea APIs.
      //
      // I'll use `http://47.242.109.145:3000` as a guess for Gitea, OR maybe I should ask?
      // NO, I should not ask if I can deduce or try.
      //
      // Actually, maybe I should look at the `create_user` implementation on the remote server? I can't.
      //
      // Let's look at `git_service.dart` maybe?
      // Or `main.dart`'s `_onPull` logic...
      // `_onPull` calls `http://localhost:8080/pull` -> `pullFromRemote` in `server.dart`.
      //
      // Let's read `lib/git_service.dart` to see how it interacts with remote.
      // It might have the Gitea URL.

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
  });

  router.post('/pull_rebase', (Request req) async {
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
  });

  router.post('/fork_local', (Request req) async {
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
  });

  router.post('/pull/cancel', (Request req) async {
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
  });

  router.post('/pull/preview', (Request req) async {
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
  });

  router.post('/check_pull_status', (Request req) async {
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
  });

  router.post('/pull', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final repoName = (data['repoName'] as String?)?.trim() ?? '';
    final username = (data['username'] as String?)?.trim() ?? '';
    final token = (data['token'] as String?)?.trim() ?? '';
    final force = data['force'] == true;

    if (repoName.isEmpty || username.isEmpty || token.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'repoName, username, token required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      final result =
          await pullFromRemote(repoName, username, token, force: force);
      print("pullResult=${result}");
      return _cors(Response.ok(jsonEncode(result),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    } catch (e) {
      return _cors(Response(500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
  });

  router.post('/prepare_merge', (Request req) async {
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
  });

  router.post('/complete_merge', (Request req) async {
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
  });

  router.post('/edge/add', (Request req) async {
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
  });
  router.post('/backup/commits', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final token = (data['token'] as String?)?.trim() ?? '';
    final repoName = (data['repoName'] as String?)?.trim() ?? '';

    if (repoName.isEmpty) {
      return _cors(Response(400,
          body: jsonEncode({'error': 'repoName required'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'}));
    }
    try {
      final commits = await listBackupCommits(repoName,token);
      return _cors(Response.ok(jsonEncode({'commits': commits}), headers: {
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
