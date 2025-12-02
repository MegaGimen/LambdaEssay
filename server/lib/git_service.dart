import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'models.dart';

final Map<String, GraphResponse> _graphCache = <String, GraphResponse>{};

void clearCache() {
  _graphCache.clear();
}

Future<List<String>> _runGit(List<String> args, String repoPath) async {
  final fullArgs = [
    '-c',
    'i18n.logOutputEncoding=UTF-8',
    '-c',
    'core.quotepath=false',
    '-C',
    repoPath,
    ...args,
  ];
  try {
    final res = await Process.run(
      'git',
      fullArgs,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (res.exitCode != 0) {
      throw Exception(res.stderr is String ? res.stderr : 'git error');
    }
    final out =
        res.stdout is String ? res.stdout as String : utf8.decode(res.stdout);
    return LineSplitter.split(out).toList();
  } on FormatException {
    // Fallback for non-UTF8 output (e.g. windows system locale)
    final res = await Process.run(
      'git',
      fullArgs,
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    if (res.exitCode != 0) {
      throw Exception(res.stderr is String ? res.stderr : 'git error');
    }
    final out = res.stdout as String;
    return LineSplitter.split(out).toList();
  }
}

Future<List<Branch>> getBranches(String repoPath) async {
  final lines = await _runGit([
    'for-each-ref',
    '--format=%(refname:short)|%(objectname)',
    'refs/heads',
  ], repoPath);
  final result = <Branch>[];
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    final parts = l.split('|');
    if (parts.length >= 2) {
      result.add(Branch(name: parts[0], head: parts[1]));
    }
  }
  return result;
}

Future<String?> getCurrentBranch(String repoPath) async {
  try {
    final lines = await _runGit(['branch', '--show-current'], repoPath);
    if (lines.isEmpty) return null;
    return lines.first.trim();
  } catch (_) {
    return null;
  }
}

Future<GraphResponse> getGraph(String repoPath, {int? limit}) async {
  final key = '${repoPath}|${limit ?? 0}';
  // We skip cache if we want fresh branch status, or we include branch in cache key?
  // For now, let's just clear cache on write ops, so read ops can cache.
  // But currentBranch might change outside?
  // Let's fetch currentBranch every time and just cache the heavy log part?
  // Simplify: disable cache for now or just accept it.
  // Actually, let's just fetch branch separately?
  // No, putting it in GraphResponse is cleaner.
  // Let's invalidate cache on any write.

  final cached = _graphCache[key];
  if (cached != null) {
    return cached;
  }
  final branches = await getBranches(repoPath);
  final chains = await getBranchChains(repoPath, branches, limit: limit);
  final current = await getCurrentBranch(repoPath);

  final logArgs = [
    'log',
    '--all',
    '--date=iso',
    '--encoding=UTF-8',
    '--pretty=format:%H|%P|%d|%s|%an|%ad',
    '--topo-order',
  ];
  if (limit != null && limit > 0) {
    logArgs.add('--max-count=$limit');
  }
  final lines = await _runGit(logArgs, repoPath);
  final commits = <CommitNode>[];
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    final parts = l.split('|');
    if (parts.length < 6) continue;
    final id = parts[0];
    final parents = parts[1].trim().isEmpty
        ? <String>[]
        : parts[1].trim().split(RegExp(r'\s+'));
    final dec = parts[2];
    final refs = _parseRefs(dec);
    final subject = parts[3];
    final author = parts[4];
    final date = parts[5];
    commits.add(
      CommitNode(
        id: id,
        parents: parents,
        refs: refs,
        author: author,
        date: date,
        subject: subject,
      ),
    );
  }
  final resp = GraphResponse(
      commits: commits,
      branches: branches,
      chains: chains,
      currentBranch: current);
  _graphCache[key] = resp;
  return resp;
}

Future<void> commitChanges(
    String repoPath, String author, String message) async {
  await _runGit(['add', '*.docx'], repoPath);
  // Ensure author format "Name <email>"
  final safeAuthor = author.trim().isEmpty ? 'Unknown' : author.trim();
  final authorArg = '$safeAuthor <$safeAuthor@gitdocx.local>';
  await _runGit(['commit', '--author=$authorArg', '-m', message], repoPath);
  clearCache();
}

Future<void> createBranch(String repoPath, String branchName) async {
  await _runGit(['checkout', '-b', branchName], repoPath);
  clearCache();
}

Future<void> switchBranch(String projectName, String branchName) async {
  final repoPath = _projectDir(projectName);
  // Force checkout to overwrite local repo changes.
  // User requested to keep external files intact ("not replace files"),
  // so we DO NOT sync back from repo to external docx here.
  // The subsequent 'Update Repo' action will handle the sync (External -> Repo).
  await _runGit(['checkout', '-f', branchName], repoPath);

  clearCache();
}

Future<Uint8List> compareWorking(String repoPath) async {
  final docxAbs = _findRepoDocx(repoPath);
  if (docxAbs == null) {
    throw Exception('No .docx file found in repository');
  }
  final docxRel = p.relative(docxAbs, from: repoPath);

  final tmpDir = await Directory.systemTemp.createTemp('gitdocx_cmp_work_');
  try {
    final p1 = p.join(tmpDir.path, 'HEAD.docx');
    final p2 = docxAbs; // The working copy directly
    final pdf = p.join(tmpDir.path, 'diff.pdf');

    await _runGitToFile(['show', 'HEAD:$docxRel'], repoPath, p1);
    // p2 is already there on disk.

    final scriptPath = p.fromUri(Platform.script);
    final repoRoot = p.dirname(p.dirname(p.dirname(scriptPath)));
    final ps1Path = p.join(repoRoot, 'frontend', 'lib', 'doccmp.ps1');

    if (!File(ps1Path).existsSync()) {
      throw Exception('doccmp.ps1 not found at $ps1Path');
    }

    final res = await Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      ps1Path,
      '-OriginalPath',
      p1,
      '-RevisedPath',
      p2,
      '-PdfPath',
      pdf
    ]);

    if (res.exitCode != 0 || !File(pdf).existsSync()) {
      throw Exception('Compare failed: ${res.stdout}\n${res.stderr}');
    }

    return await File(pdf).readAsBytes();
  } finally {
    try {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}

List<String> _parseRefs(String decoration) {
  final s = decoration.trim();
  if (s.isEmpty) return <String>[];
  final start = s.indexOf('(');
  final end = s.lastIndexOf(')');
  if (start < 0 || end < 0 || end <= start) return <String>[];
  final inner = s.substring(start + 1, end);
  final items = inner.split(',');
  final refs = <String>{};
  for (var i in items) {
    final t = i.trim();
    if (t.isEmpty) continue;
    final cleaned = t
        .replaceAll(RegExp(r'^HEAD ->\s*'), '')
        .replaceAll(RegExp(r'^tag:\s*'), '')
        .replaceAll(RegExp(r'^origin/'), '');
    refs.add(cleaned);
  }
  return refs.toList();
}

Future<Map<String, List<String>>> getBranchChains(
    String repoPath, List<Branch> branches,
    {int? limit}) async {
  final result = <String, List<String>>{};
  for (final b in branches) {
    final args = [
      'log',
      '--topo-order',
      '--date=iso',
      '--encoding=UTF-8',
      '--pretty=format:%H',
      b.name,
    ];
    if (limit != null && limit > 0) {
      args.add('--max-count=$limit');
    }
    final lines = await _runGit(args, repoPath);
    final ids = <String>[];
    for (final l in lines) {
      final s = l.trim();
      if (s.isEmpty) continue;
      ids.add(s);
    }
    result[b.name] = ids;
  }
  return result;
}

String _baseDir() {
  final app = Platform.environment['APPDATA'];
  if (app != null && app.isNotEmpty) return p.join(app, 'gitdocx');
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) return p.join(home, '.gitdocx');
  return p.join(Directory.systemTemp.path, 'gitdocx');
}

File _trackingFile(String name) {
  final dir = p.join(_baseDir(), '.configs');
  return File(p.join(dir, '$name.json'));
}

Future<Map<String, dynamic>> _readTracking(String name) async {
  final f = _trackingFile(name);
  if (f.existsSync()) {
    try {
      final s = await f.readAsString();
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }
  // Migration: Check old location inside repo
  final oldPath = p.join(_projectDir(name), 'tracking.json');
  final oldFile = File(oldPath);
  if (oldFile.existsSync()) {
    try {
      final s = await oldFile.readAsString();
      final data = jsonDecode(s) as Map<String, dynamic>;
      // Migrate to new location
      await _writeTracking(name, data);
      return data;
    } catch (_) {
      return <String, dynamic>{};
    }
  }
  return <String, dynamic>{};
}

Future<void> _writeTracking(String name, Map<String, dynamic> data) async {
  final dir = Directory(p.dirname(_trackingFile(name).path));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final f = _trackingFile(name);
  await f.writeAsString(jsonEncode(data));
}

String _projectDir(String name) {
  return p.normalize(p.join(_baseDir(), name));
}

String? _findRepoDocx(String projDir) {
  final d = Directory(projDir);
  if (!d.existsSync()) return null;
  final ents = d.listSync(recursive: false);
  for (final e in ents) {
    if (e is File && e.path.toLowerCase().endsWith('.docx')) {
      return p.normalize(e.path);
    }
  }
  return null;
}

final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};

Future<Uint8List> compareCommits(
    String repoPath, String commit1, String commit2) async {
  // 1. Check cache
  final cacheDir = Directory(p.join(_baseDir(), 'cache'));
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }
  final cacheName = '${commit1}cmp${commit2}.pdf';
  final cachePath = p.join(cacheDir.path, cacheName);
  final cacheFile = File(cachePath);
  if (cacheFile.existsSync()) {
    return await cacheFile.readAsBytes();
  }

  // 2. Generate if not cached
  final docxAbs = _findRepoDocx(repoPath);
  if (docxAbs == null) {
    throw Exception('No .docx file found in repository');
  }
  final docxRel = p.relative(docxAbs, from: repoPath);

  final tmpDir = await Directory.systemTemp.createTemp('gitdocx_cmp_');
  try {
    final p1 = p.join(tmpDir.path, 'old.docx');
    final p2 = p.join(tmpDir.path, 'new.docx');
    final pdf = p.join(tmpDir.path, 'diff.pdf');

    await _runGitToFile(['show', '$commit1:$docxRel'], repoPath, p1);
    await _runGitToFile(['show', '$commit2:$docxRel'], repoPath, p2);

    final scriptPath = p.fromUri(Platform.script);
    // script -> bin -> server -> root
    final repoRoot = p.dirname(p.dirname(p.dirname(scriptPath)));
    final ps1Path = p.join(repoRoot, 'frontend', 'lib', 'doccmp.ps1');

    if (!File(ps1Path).existsSync()) {
      throw Exception('doccmp.ps1 not found at $ps1Path');
    }

    final res = await Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      ps1Path,
      '-OriginalPath',
      p1,
      '-RevisedPath',
      p2,
      '-PdfPath',
      pdf
    ]);

    if (res.exitCode != 0 || !File(pdf).existsSync()) {
      throw Exception('Compare failed: ${res.stdout}\n${res.stderr}');
    }

    // 3. Save to cache
    await File(pdf).copy(cachePath);

    return await File(pdf).readAsBytes();
  } finally {
    try {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}

Future<void> _runGitToFile(
    List<String> args, String repoPath, String outFile) async {
  final fullArgs = [
    '-c',
    'core.quotepath=false',
    '-C',
    repoPath,
    ...args,
  ];
  final res = await Process.run('git', fullArgs, stdoutEncoding: null);
  if (res.exitCode != 0) {
    final err = res.stderr is String
        ? res.stderr
        : utf8.decode(res.stderr as List<int>);
    throw Exception('git error: $err');
  }
  await File(outFile).writeAsBytes(res.stdout as List<int>);
}

Future<Map<String, dynamic>> createTrackingProject(
    String name, String? docxPath) async {
  final projDir = _projectDir(name);
  final dir = Directory(projDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final gitDir = Directory(p.join(projDir, '.git'));
  if (!gitDir.existsSync()) {
    await _runGit(['init'], projDir);
    final gitignore = File(p.join(projDir, '.gitignore'));
    await gitignore.writeAsString('tracking.json\n');
  }
  String? repoDocxPath;
  if (docxPath != null && docxPath.trim().isNotEmpty) {
    final src = File(docxPath);
    if (src.existsSync()) {
      final uuid = const Uuid().v4();
      repoDocxPath = p.normalize(p.join(projDir, '$uuid.docx'));
      await File(repoDocxPath).writeAsBytes(await src.readAsBytes());
    }
  }
  final tracking = await _readTracking(name);
  tracking['name'] = name;
  if (docxPath != null && docxPath.trim().isNotEmpty) {
    tracking['docxPath'] = _sanitizeFsPath(docxPath);
  }
  if (repoDocxPath != null) {
    tracking['repoDocxPath'] = repoDocxPath;
  }
  await _writeTracking(name, tracking);
  await _startWatcher(name);
  return {
    'name': name,
    'repoPath': projDir,
  };
}

Future<Map<String, dynamic>> openTrackingProject(String name) async {
  final projDir = _projectDir(name);
  final dir = Directory(projDir);
  if (!dir.existsSync()) {
    throw Exception('project not found');
  }
  final tracking = await _readTracking(name);
  await _startWatcher(name);
  return {
    'name': name,
    'repoPath': projDir,
    'docxPath': tracking['docxPath'],
  };
}

Future<Map<String, dynamic>?> getTrackingInfo(String repoPath) async {
  final base = Directory(_baseDir());
  if (!base.existsSync()) return null;
  // ... existing code ...
  // Since I can't easily see the end of the function in the previous read,
  // I will append the new functions at the end of the file.
  // But SearchReplace needs context.
  // Let me read the end of the file first.
  final normalized = p.normalize(repoPath);

  // Check if repoPath is directly a project dir in baseDir
  // iterate subdirs
  try {
    final ents = base.listSync().whereType<Directory>();
    for (final d in ents) {
      final name = p.basename(d.path);
      if (name.startsWith('.')) continue;
      if (p.normalize(d.path) == normalized) {
        final tracking = await _readTracking(name);
        return {
          'name': name,
          'docxPath': tracking['docxPath'],
          'repoDocxPath': tracking['repoDocxPath']
        };
      }
    }
  } catch (_) {}
  return null;
}

Future<Map<String, dynamic>> updateTrackingProject(String name,
    {String? newDocxPath}) async {
  final projDir = _projectDir(name);
  final dir = Directory(projDir);
  if (!dir.existsSync()) {
    throw Exception('project not found');
  }
  var tracking = await _readTracking(name);
  String? sourcePath = tracking['docxPath'] as String?;
  if (newDocxPath != null && newDocxPath.trim().isNotEmpty) {
    sourcePath = _sanitizeFsPath(newDocxPath);
    tracking['docxPath'] = sourcePath;
  }
  if (sourcePath == null ||
      sourcePath.trim().isEmpty ||
      !File(sourcePath).existsSync()) {
    return {'needDocx': true, 'repoPath': projDir};
  }
  String? repoDocxPath = tracking['repoDocxPath'] as String?;
  if (repoDocxPath == null || repoDocxPath.trim().isEmpty) {
    repoDocxPath = _findRepoDocx(projDir);
    if (repoDocxPath == null) {
      final uuid = const Uuid().v4();
      repoDocxPath = p.join(projDir, '$uuid.docx');
    }
    tracking['repoDocxPath'] = repoDocxPath;
  }
  await _writeTracking(name, tracking);
  final src = File(sourcePath);
  if (!src.existsSync()) {
    return {'needDocx': true, 'repoPath': projDir};
  }

  // Try to compare Source vs HEAD to decide whether to Restore or Copy
  bool restored = false;
  final relPath = p.relative(repoDocxPath, from: projDir);
  // Git expects forward slashes for 'HEAD:path'
  final gitRelPath = relPath.replaceAll(r'\', '/');

  final tmpDir = await Directory.systemTemp.createTemp('git_head_check_');
  try {
    final headFile = p.join(tmpDir.path, 'HEAD.docx');
    bool hasHead = false;
    try {
      await _runGitToFile(['show', 'HEAD:$gitRelPath'], projDir, headFile);
      hasHead = true;
    } catch (_) {
      // File might not exist in HEAD
    }

    if (hasHead) {
      // Compare Source vs HEAD
      final isIdenticalToHead = await _checkDocxIdentical(sourcePath, headFile);
      if (isIdenticalToHead) {
        // If Source is semantically identical to HEAD, we restore the working copy
        // to ensure git status is clean (undoing any metadata-only changes).
        await _runGit(['checkout', 'HEAD', '--', relPath], projDir);
        restored = true;
      }
    }
  } finally {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  if (!restored) {
    // If we didn't restore (either different from HEAD, or new file), we update the working copy
    await File(repoDocxPath).writeAsBytes(await src.readAsBytes());
  }

  final diff = await _runGit(
      ['diff', '--name-only', '--', p.basename(repoDocxPath)], projDir);
  final head = await getHead(projDir);
  final changed = diff.any((l) => l.trim().isNotEmpty);
  return {
    'workingChanged': changed,
    'repoPath': projDir,
    'head': head,
  };
}

Future<bool> _checkDocxIdentical(String path1, String path2) async {
  try {
    final f1 = File(path1);
    final f2 = File(path2);
    if (!f1.existsSync() || !f2.existsSync()) return false;

    final client = HttpClient();
    final req = await client.post('localhost', 5000, '/compare');
    final boundary =
        '---gitbin-boundary-${DateTime.now().millisecondsSinceEpoch}';
    req.headers.contentType = ContentType('multipart', 'form-data',
        parameters: {'boundary': boundary});

    void writePart(String fieldName, String filename, List<int> content) {
      req.write('--$boundary\r\n');
      req.write(
          'Content-Disposition: form-data; name="$fieldName"; filename="$filename"\r\n');
      req.write(
          'Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n\r\n');
      req.add(content);
      req.write('\r\n');
    }

    writePart('file1', p.basename(path1), await f1.readAsBytes());
    writePart('file2', p.basename(path2), await f2.readAsBytes());
    req.write('--$boundary--\r\n');

    final resp = await req.close();
    if (resp.statusCode != 200) {
      return false;
    }
    final bodyStr = await utf8.decodeStream(resp);
    final body = jsonDecode(bodyStr) as Map<String, dynamic>;
    return body['identical'] == true;
  } catch (e) {
    // Service might be down or error, fallback to safe "not identical" -> triggering copy & git diff
    return false;
  }
}

Future<Uint8List> previewVersion(String repoPath, String commitId) async {
  // 1. Check cache
  final cacheDir = Directory(p.join(_baseDir(), 'cache'));
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }
  final cacheName = '$commitId.pdf';
  final cachePath = p.join(cacheDir.path, cacheName);
  final cacheFile = File(cachePath);
  if (cacheFile.existsSync()) {
    return await cacheFile.readAsBytes();
  }

  // 2. Generate if not cached
  final docxAbs = _findRepoDocx(repoPath);
  if (docxAbs == null) {
    throw Exception('No .docx file found in repository');
  }
  final docxRel = p.relative(docxAbs, from: repoPath);

  final tmpDir = await Directory.systemTemp.createTemp('gitdocx_prev_');
  try {
    final p1 = p.join(tmpDir.path, 'preview.docx');
    final pdf = p.join(tmpDir.path, 'preview.pdf');

    await _runGitToFile(['show', '$commitId:$docxRel'], repoPath, p1);

    final scriptPath = p.fromUri(Platform.script);
    final repoRoot = p.dirname(p.dirname(p.dirname(scriptPath)));
    final ps1Path = p.join(repoRoot, 'frontend', 'lib', 'docx2pdf.ps1');

    if (!File(ps1Path).existsSync()) {
      throw Exception('docx2pdf.ps1 not found at $ps1Path');
    }

    final res = await Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      ps1Path,
      '-InputPath',
      p1,
      '-OutputPath',
      pdf
    ]);

    if (res.exitCode != 0 || !File(pdf).existsSync()) {
      throw Exception(
          'Preview generation failed: ${res.stdout}\n${res.stderr}');
    }

    // 3. Save to cache
    await File(pdf).copy(cachePath);

    return await File(pdf).readAsBytes();
  } finally {
    try {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}

Future<void> resetBranch(String projectName, String commitId) async {
  final repoPath = _projectDir(projectName);
  final docxAbs = _findRepoDocx(repoPath);

  // Reset HEAD to commitId, discarding all changes after it
  await _runGit(['reset', '--hard', commitId], repoPath);

  // Sync to external
  final tracking = await _readTracking(projectName);
  final docxPath = tracking['docxPath'] as String?;

  if (docxPath != null && docxAbs != null) {
    final src = File(docxAbs);
    final dst = File(docxPath);
    if (src.existsSync()) {
      try {
        await dst.writeAsBytes(await src.readAsBytes());
      } catch (e) {
        throw Exception(
            'Reset successful in repo, but failed to update external file: $e');
      }
    }
  }
  clearCache();
}

Future<void> rollbackVersion(String projectName, String commitId) async {
  final repoPath = _projectDir(projectName);
  final docxAbs = _findRepoDocx(repoPath);
  if (docxAbs == null) {
    throw Exception('No .docx file found in repository');
  }
  final docxRel = p.relative(docxAbs, from: repoPath);

  // Checkout the file from the specific commit
  await _runGit(['checkout', commitId, '--', docxRel], repoPath);

  // Sync to external
  final tracking = await _readTracking(projectName);
  final docxPath = tracking['docxPath'] as String?;

  if (docxPath != null) {
    final src = File(docxAbs);
    final dst = File(docxPath);
    try {
      await dst.writeAsBytes(await src.readAsBytes());
    } catch (e) {
      throw Exception(
          'Rollback successful in repo, but failed to update external file (is Word open?): $e');
    }
  }
  clearCache();
}

Future<String?> getHead(String repoPath) async {
  try {
    final lines = await _runGit(['rev-parse', 'HEAD'], repoPath);
    if (lines.isEmpty) return null;
    final id = lines.first.trim();
    return id.isEmpty ? null : id;
  } catch (_) {
    return null;
  }
}

String _sanitizeFsPath(String raw) {
  var t = raw.trim();
  if ((t.startsWith('"') && t.endsWith('"')) ||
      (t.startsWith('\'') && t.endsWith('\''))) {
    t = t.substring(1, t.length - 1);
  }
  if (t.startsWith('file://')) {
    try {
      final uri = Uri.parse(t);
      t = uri.toFilePath(windows: true);
    } catch (_) {}
  }
  return p.normalize(t);
}

Future<void> _startWatcher(String name) async {
  final tracking = await _readTracking(name);
  final docx = tracking['docxPath'] as String?;
  if (docx == null || docx.trim().isEmpty) return;
  final f = File(docx);
  if (!f.existsSync()) return;
  final sub = _watchers[name];
  if (sub != null) return;
  final s = f.watch(events: FileSystemEvent.modify);
  final subscription = s.listen((_) async {
    try {
      await updateTrackingProject(name);
    } catch (_) {}
  });
  _watchers[name] = subscription;
}

Future<void> initTrackingService() async {
  final base = Directory(_baseDir());
  if (!base.existsSync()) return;
  final ents = base.listSync().whereType<Directory>().toList();
  for (final d in ents) {
    final name = p.basename(d.path);
    if (name.startsWith('.')) continue;
    await _startWatcher(name);
  }
}

Future<void> ensureRemoteRepoExists(String repoName, String token) async {
  print("Ensuriing exist");
  final url = Uri.parse('http://47.242.109.145:3000/api/v1/user/repos');
  try {
    final resp = await http.post(
      url,
      headers: {
        'Authorization': 'token $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'name': repoName,
        'private': true,
      }),
    );
    if (resp.statusCode == 201) {
      // Created
    } else if (resp.statusCode == 409) {
      // Already exists
    } else {
      throw Exception(
          'Failed to create remote repo: ${resp.statusCode} ${resp.body}');
    }
  } catch (e) {
    throw Exception('Failed to connect to remote: $e');
  }
}

Future<void> pushToRemote(String repoPath, String username, String token,
    {bool force = false}) async {
  print("pussying");
  final repoName = p.basename(repoPath);
  await ensureRemoteRepoExists(repoName, token);

  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$username/$repoName.git';

  final args = ['push'];
  if (force) args.add('--force');
  args.addAll(['--all', remoteUrl]);

  await _runGit(args, repoPath);
}

Future<Map<String, dynamic>> pullFromRemote(
    String repoName, String username, String token) async {
  final projDir = _projectDir(repoName);
  final dir = Directory(projDir);
  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$username/$repoName.git';

  Map<String, dynamic>? savedTracking;
  bool isFresh = !dir.existsSync();

  if (!isFresh) {
    // Check safety before destroying
    // 1. Check uncommitted changes
    try {
      final statusLines = await _runGit(['status', '--porcelain'], projDir);
      if (statusLines.isNotEmpty) {
        return {
          'status': 'error',
          'errorType': 'uncommitted',
          'path': projDir,
          'message':
              'Local repository has uncommitted changes. Please commit or discard them before pulling.'
        };
      }
    } catch (e) {
      // If repo is broken, maybe allow overwrite?
    }

    // 2. Check if local is newer than remote
    try {
      // Fetch remote head to FETCH_HEAD
      // We use the remoteUrl directly to be sure
      await _runGit(['fetch', remoteUrl, 'HEAD'], projDir);

      // Check if HEAD is ancestor of FETCH_HEAD
      // If HEAD is ancestor of FETCH_HEAD (remote), it means we are behind (safe to fast-forward/reset).
      // If HEAD is NOT ancestor, it means we have local commits not in remote (ahead or diverged).
      final mergeBaseRes = await Process.run(
        'git',
        ['merge-base', '--is-ancestor', 'HEAD', 'FETCH_HEAD'],
        workingDirectory: projDir,
        runInShell: true,
      );

      // exitCode 0 means true (is ancestor)
      // exitCode 1 means false (not ancestor)
      if (mergeBaseRes.exitCode != 0) {
        return {
          'status': 'error',
          'errorType': 'ahead',
          'path': projDir,
          'message':
              'Local branch is ahead of remote or diverged. Please push your changes first to avoid losing work.'
        };
      }
    } catch (e) {
      // If fetch fails, ignore here, will likely fail at clone step if network issue
    }

    // Preserve tracking info
    savedTracking = await _readTracking(repoName);
    // Delete existing directory for a "thorough" clean pull
    try {
      dir.deleteSync(recursive: true);
    } catch (e) {
      throw Exception('Failed to clean existing directory: $e');
    }
  }

  // Clone
  final base = Directory(_baseDir());
  if (!base.existsSync()) {
    base.createSync(recursive: true);
  }
  // git clone <url> <dir>
  final res = await Process.run(
    'git',
    ['clone', remoteUrl, projDir],
    runInShell: true,
  );
  if (res.exitCode != 0) {
    throw Exception('Clone failed: ${res.stderr}');
  }

  // Fetch all remote branches and create local tracking branches
  try {
    // Get list of remote branches
    final branchesRes = await Process.run(
      'git',
      ['branch', '-r'],
      workingDirectory: projDir,
      runInShell: true,
    );
    if (branchesRes.exitCode == 0) {
      final lines = (branchesRes.stdout as String).split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.contains('->')) continue; // Skip HEAD -> origin/master

        // trimmed is like "origin/feature-a"
        final parts = trimmed.split('/');
        if (parts.length < 2) continue;

        // Assuming remote name is always the first part (origin)
        // branch name is the rest
        final branchName = parts.sublist(1).join('/');

        // Check if local branch already exists (e.g. master)
        final localCheck = await Process.run(
          'git',
          ['rev-parse', '--verify', branchName],
          workingDirectory: projDir,
          runInShell: true,
        );

        if (localCheck.exitCode != 0) {
          // Local branch does not exist, create it tracking the remote
          // git branch --track <name> <remote>/<name>
          await Process.run(
            'git',
            ['branch', '--track', branchName, trimmed],
            workingDirectory: projDir,
            runInShell: true,
          );
        }
      }
    }
  } catch (e) {
    print('Warning: Failed to restore remote branches: $e');
    // Non-fatal, we at least have the clone
  }

  // Post-pull cleanup & sync
  // 1. If tracking.json exists in repo (from remote), delete it to avoid confusion
  final legacyTracking = File(p.join(projDir, 'tracking.json'));
  if (legacyTracking.existsSync()) {
    try {
      legacyTracking.deleteSync();
    } catch (_) {}
  }

  if (!isFresh && savedTracking != null && savedTracking.isNotEmpty) {
    // Sync Repo Docx -> External Docx
    final repoDocxPath = savedTracking['repoDocxPath'] as String?;
    final docxPath = savedTracking['docxPath'] as String?;

    if (repoDocxPath != null && docxPath != null) {
      final repoFile = File(repoDocxPath);
      final extFile = File(docxPath);
      if (repoFile.existsSync()) {
        try {
          await extFile.writeAsBytes(await repoFile.readAsBytes());
        } catch (e) {
          print('Warning: Failed to sync external docx: $e');
        }
      }
    }
  }

  await _startWatcher(repoName);
  clearCache();
  return {
    'status': 'success',
    'path': projDir,
    'isFresh': isFresh,
  };
}

Future<List<String>> listProjects() async {
  final base = Directory(_baseDir());
  if (!base.existsSync()) return [];
  final projects = <String>[];
  try {
    final ents = base.listSync().whereType<Directory>();
    for (final d in ents) {
      final name = p.basename(d.path);
      if (name.startsWith('.') || name.toLowerCase() == 'cache') continue;
      projects.add(name);
    }
  } catch (_) {}
  return projects;
}
