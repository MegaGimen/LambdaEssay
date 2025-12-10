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

Future<List<List<String>>> _readEdges(String repoPath) async {
  final f = File(p.join(repoPath, 'edges'));
  if (!f.existsSync()) return [];
  try {
    final lines = await f.readAsLines();
    if (lines.isEmpty) return [];
    // First line is commit ID (ignore for now as per user instruction it is just meta)
    final edges = <List<String>>[];
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        edges.add(parts.sublist(0, 2));
      }
    }
    return edges;
  } catch (_) {
    return [];
  }
}

Future<GraphResponse> getGraph(String repoPath, {int? limit}) async {
  final key = '${repoPath}|${limit ?? 0}';
  final cached = _graphCache[key];
  if (cached != null) {
    print('Graph cache hit for $key');
    return cached;
  }
  print('Graph cache miss for $key, fetching...');
  final branches = await getBranches(repoPath);
  final chains = await getBranchChains(repoPath, branches, limit: limit);
  final current = await getCurrentBranch(repoPath);
  final customEdges = await _readEdges(repoPath);

  final logArgs = [
    'log',
    '--branches',
    '--tags',
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
    final rawParents = parts[1].trim().isEmpty
        ? <String>[]
        : parts[1].trim().split(RegExp(r'\s+'));

    final parents = rawParents;

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
      currentBranch: current,
      customEdges: customEdges);
  _graphCache[key] = resp;
  return resp;
}

Future<void> commitChanges(
    String repoPath, String author, String message) async {
  await _runGit(['add', '*.docx'], repoPath);
  if (File(p.join(repoPath, 'edges')).existsSync()) {
    print("edge文件存在！");
    await _runGit(['add', 'edges'], repoPath);
  }
  print("edge文件真存在吗？");
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

Future<void> addRemote(String repoPath, String name, String url) async {
  try {
    final remotes = await _runGit(['remote'], repoPath);
    if (remotes.contains(name)) {
      // Update existing remote
      await _runGit(['remote', 'set-url', name, url], repoPath);
    } else {
      await _runGit(['remote', 'add', name, url], repoPath);
    }
  } catch (e) {
    print('Failed to add/update remote $name: $e');
    // Don't throw, just log
  }
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
    if (t.startsWith('origin/')) continue;
    final cleaned = t
        .replaceAll(RegExp(r'^HEAD ->\s*'), '')
        .replaceAll(RegExp(r'^tag:\s*'), '');
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
      '--first-parent',
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
  // tracking.json is now stored inside the repo directory directly, not in .configs
  final dir = _projectDir(name);
  return File(p.join(dir, 'tracking.json'));
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
  return <String, dynamic>{};
}

Future<void> _writeTracking(String name, Map<String, dynamic> data) async {
  final f = _trackingFile(name);
  // Ensure project dir exists
  final dir = Directory(p.dirname(f.path));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }

  // We want to exclude tracking.json from git if it's not already ignored?
  // The init function adds it to .gitignore.

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
  print("Writting Complete");
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
      print("identical?");
      print(isIdenticalToHead);
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
  print('restored?');
  print(restored);
  if (!restored) {
    // If we didn't restore (either different from HEAD, or new file), we update the working copy
    await File(repoDocxPath).writeAsBytes(await src.readAsBytes());
  }

  final diff = await _runGit(
      ['diff', '--name-only', '--', p.basename(repoDocxPath)], projDir);
  final head = await getHead(projDir);
  //final changed = diff.any((l) => l.trim().isNotEmpty);
  final changed = !restored;
  print("Changed?");
  print({
    'workingChanged': changed,
    'repoPath': projDir,
    'head': head,
  });
  return {
    'workingChanged': changed,
    'repoPath': projDir,
    'head': head,
  };
}

Future<bool> _checkDocxIdentical(String path1, String path2) async {
  print("comparing");
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

  // Reset HEAD to commitId, discarding all changes after it
  // This only changes the git repository state (and working dir inside repo),
  // BUT does NOT sync back to the external docx file.
  await _runGit(['reset', '--hard', commitId], repoPath);

  // We intentionally DO NOT sync to external docx here.
  // The user explicitly requested to keep the external file intact ("not change tracking target").
  // If they want to revert the file content, they should use "Rollback (File Only)".

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

Future<String> _resolveRepoOwner(String repoName, String token) async {
  final giteaUrl = 'http://47.242.109.145:3000';
  final headers = {
    'Authorization': 'token $token',
    'Content-Type': 'application/json',
  };

  String? findOwnerInList(List<dynamic> list) {
    for (final repo in list) {
      print("${repo['name']}");
      if (repo['name'] == repoName) {
        return repo['owner']['login'] as String;
      }
    }
    return null;
  }

  // 1. Check owned repos
  try {
    final resp = await http.get(Uri.parse('$giteaUrl/api/v1/user/repos'),
        headers: headers);
    if (resp.statusCode == 200) {
      final owner = findOwnerInList(jsonDecode(resp.body));
      print('ownerList:$owner');
      if (owner != null) return owner;
    }
  } catch (e) {
    print('Error checking owned repos: $e');
  }

  // 2. Check member repos
  try {
    final resp = await http.get(
        Uri.parse('$giteaUrl/api/v1/user/repos?type=member'),
        headers: headers);
    if (resp.statusCode == 200) {
      final owner = findOwnerInList(jsonDecode(resp.body));
      print('memberList:$owner');
      if (owner != null) return owner;
    }
  } catch (e) {
    print('Error checking member repos: $e');
  }

  throw Exception(
      'Repository $repoName not found in your account access list.');
}

Future<void> pushToRemote(String repoPath, String username, String token,
    {bool force = false}) async {
  print("pussying");
  final repoName = p.basename(repoPath);

  String owner;
  try {
    owner = await _resolveRepoOwner(repoName, token);
  } catch (_) {
    // Not found, create it
    await ensureRemoteRepoExists(repoName, token);
    owner = username;
  }

  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

  final args = ['push'];
  if (force) args.add('--force');
  // Explicitly specify the remote URL and ensure local branches are mapped to remote branches with same name
  args.add(remoteUrl);

  // Get list of all local branches
  final localBranches = <String>[];
  try {
    final lines = await _runGit(
        ['for-each-ref', '--format=%(refname:short)', 'refs/heads'], repoPath);
    for (final l in lines) {
      if (l.trim().isNotEmpty) localBranches.add(l.trim());
    }
  } catch (e) {
    print('Failed to list local branches: $e');
  }

  if (localBranches.isEmpty) {
    // Fallback if no branches (empty repo?)
    args.add('refs/heads/*:refs/heads/*');
  } else {
    // Add refspec for each branch explicitly
    for (final b in localBranches) {
      args.add('refs/heads/$b:refs/heads/$b');
    }
  }

  print('Executing git push with args: $args');
  List<String> output = [];
  try {
    output = await _runGit(args, repoPath);
    print('Git push output: ${output.join('\n')}');
  } catch (e) {
    print('Git push failed with error: $e');
    // If push failed, it might be because of non-fast-forward (rejected).
    // Even if the error message is localized (e.g. Chinese), we should check the repo state.
    if (!force) {
      await _checkIfBehind(repoPath, remoteUrl);
    }
    // If _checkIfBehind didn't throw (meaning not behind), we rethrow the original error.
    rethrow;
  }

  // Force update local remote refs to match reality
  try {
    await _runGit(['fetch', remoteUrl], repoPath);
  } catch (e) {
    print('Fetch after push failed: $e');
  }

  // Check for implicit rejection (Everything up-to-date but local is actually behind/different)
  // If force is true, we don't care, git would have forced update unless it failed with other error.
  if (!force) {
    final outStr = output.join('\n');
    if (outStr.contains('Everything up-to-date')) {
      // Only check if we are behind if git says up-to-date.
      await _checkIfBehind(repoPath, remoteUrl);
    }
  }
}

Future<void> _checkIfBehind(String repoPath, String remoteUrl) async {
  // 1. Get local heads
  final localRefs = <String, String>{};
  final localLines = await _runGit(
      ['for-each-ref', '--format=%(refname:short)|%(objectname)', 'refs/heads'],
      repoPath);
  for (final line in localLines) {
    final parts = line.split('|');
    if (parts.length >= 2) {
      localRefs[parts[0].trim()] = parts[1].trim();
    }
  }

  // 2. Get remote heads
  // git ls-remote --heads <url>
  // Output: <hash>\trefs/heads/<name>
  final remoteLines =
      await _runGit(['ls-remote', '--heads', remoteUrl], repoPath);
  final remoteRefs = <String, String>{};
  for (final line in remoteLines) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      final hash = parts[0];
      final ref = parts[1];
      if (ref.startsWith('refs/heads/')) {
        final name = ref.substring('refs/heads/'.length);
        remoteRefs[name] = hash;
      }
    }
  }

  // 3. Compare
  for (final branch in localRefs.keys) {
    final localHash = localRefs[branch];
    final remoteHash = remoteRefs[branch];

    // Only throw if local != remote AND local is an ancestor of remote (behind).
    // If local is ahead (remote is ancestor of local), that's fine, but then git push shouldn't have said "Everything up-to-date".
    // Wait, if local is ahead, git push SHOULD update remote.
    // So if git push says "Everything up-to-date", it means remote is ALREADY at localHash (equal),
    // OR local is behind remote (and git refused to update but printed up-to-date? No, usually git prints nothing or rejects).
    // Actually, if local is behind remote, 'git push' without force does nothing and says 'Everything up-to-date' because fast-forward is not possible in reverse?
    // No, if behind, git push usually says 'Everything up-to-date' only if it thinks there's nothing to push.

    if (remoteHash != null && localHash != remoteHash) {
      // We need to verify if local is BEHIND remote.
      // If local is AHEAD, git push should have worked. Why did it fail/say up-to-date?
      // Maybe network issue or refspec issue?
      // But here we just want to detect the Reset/Rollback case (Local is Behind).

      // Check if local is ancestor of remote
      bool localIsBehind = false;
      try {
        await _runGit(
            ['merge-base', '--is-ancestor', localHash!, remoteHash], repoPath);
        localIsBehind = true;
      } catch (_) {
        localIsBehind = false;
      }

      if (localIsBehind) {
        throw Exception(
            'Push rejected: Local branch "$branch" is behind remote (non-fast-forward). '
            'Local: ${localHash!.substring(0, 7)}, Remote: ${remoteHash.substring(0, 7)}. '
            'You need to force push to overwrite remote changes.');
      }
    }
  }
}

Future<Map<String, dynamic>> pullFromRemote(
    String repoName, String username, String token,
    {bool force = false}) async {
  final remoteName = repoName.toLowerCase();
  final projDir = _projectDir(repoName);
  final dir = Directory(projDir);
  // Check if git repo exists inside. If dir exists but no .git, it's also considered fresh/broken.
  final gitDir = Directory(p.join(projDir, '.git'));

  final owner = await _resolveRepoOwner(repoName, token);
  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

  Map<String, dynamic>? savedTracking;
  bool isFresh = !dir.existsSync() || !gitDir.existsSync();

  if (!isFresh && force) {
    // Force pull mode: delete local repo and treat as fresh clone
    try {
      savedTracking = await _readTracking(repoName);
    } catch (_) {}
    try {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      isFresh = true;
    } catch (e) {
      throw Exception('Failed to delete local repository for force pull: $e');
    }
  }

  if (!isFresh) {
    // Check safety before destroying
    if (!force) {
      // 1. Use our semantic check (updateTrackingProject) instead of raw git status
      // If updateTrackingProject says "workingChanged": true, it means we have meaningful changes (content diff)
      // If false, it means files are identical to HEAD (even if metadata changed), so it's safe to overwrite.
      try {
        // Check if tracking.json exists first
        final trackingFile = _trackingFile(repoName);
        if (trackingFile.existsSync()) {
          print("Debug tracking file");
          print(trackingFile);
          // Force reset working directory to HEAD to allow pull
          // This discards local repo changes, but external file changes are preserved
          // and will be re-synced after pull.
          try {
            await _runGit(['checkout', 'HEAD', '--', '.'], projDir);
          } catch (e) {
            print("Force checkout failed (maybe no HEAD yet): $e");
          }
        } else {
          // If tracking.json doesn't exist, we assume it's a fresh state or broken tracking.
          // In this case, we skip the check and allow pull to proceed (force pull behavior as requested).
          print(
              "No tracking.json found for $repoName, skipping local changes check.");
        }
      } catch (e) {
        // If update failed, maybe repo is broken, proceed with caution or fail?
        // Let's assume if we can't verify, we block to be safe, unless it's just a minor error.
        print("Pre-pull check warning: $e");
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
    }

    // Preserve tracking info
    savedTracking = await _readTracking(repoName);

    // Instead of deleting and re-cloning, we try standard git fetch + reset
    try {
      // 1. Fetch from remote
      await _runGit(['fetch', remoteUrl], projDir);

      // 2. Get current branch
      final current = await getCurrentBranch(projDir);

      // 3. Reset current branch to remote tracking branch
      // Assuming remote is origin
      // If we are on 'master', we want to reset to 'origin/master'
      // We can get the upstream branch or guess it.

      if (current != null) {
        // Try to find upstream
        // But since we use custom remote url, we might not have upstream configured?
        // We configured remote 'origin' when cloning (implicitly).
        // But here remoteUrl is passed explicitly.
        // Let's assume 'origin' maps to remoteUrl.
        // Or we can just use FETCH_HEAD? But FETCH_HEAD might be HEAD of remote.

        // Safer way: find the matching remote branch for current local branch
        // Usually it's origin/<current>

        // Check if origin/<current> exists
        // If not, maybe we should just pull (merge)? But user wants "force update".
        // Reset --hard to origin/<current> is the standard "force pull".

        // We need to make sure remote is set to remoteUrl
        await addRemote(projDir, remoteName, remoteUrl);

        await _runGit(['reset', '--hard', '$remoteName/$current'], projDir);
      } else {
        // Detached HEAD? Just checkout remote/HEAD?
        // Or maybe we should checkout master?
        // Let's try to checkout remote/HEAD
        // await _runGit(['checkout', '$remoteName/HEAD'], projDir);
        // Or better, checkout master and reset
        await _runGit(['checkout', 'master'], projDir);
        await _runGit(['reset', '--hard', '$remoteName/master'], projDir);
      }

      // Also prune deleted remote branches
      await _runGit(['remote', 'prune', remoteName], projDir);
    } catch (e) {
      // If standard pull fails (e.g. diverged too much or config broken), fallback to delete & clone?
      // Or just throw?
      // User said "no violence", so maybe just throw.
      throw Exception('Standard pull failed: $e');
    }
  } else {
    // Is fresh (clone)
    final base = Directory(_baseDir());
    if (!base.existsSync()) {
      base.createSync(recursive: true);
    }
    // git clone -o <remoteName> <url> <dir>
    final res = await Process.run(
      'git',
      ['clone', '-o', remoteName, remoteUrl, projDir],
      runInShell: true,
    );
    if (res.exitCode != 0) {
      throw Exception('Clone failed: ${res.stderr}');
    }
  }

  // Fetch all remote branches and create local tracking branches
  try {
    // Get list of remote branches using _runGit to handle encoding and quotepath
    final lines = await _runGit(['branch', '-r'], projDir);

    // Get local branches to check for existence efficiently
    final localBranches = await getBranches(projDir);
    final localBranchNames = localBranches.map((b) => b.name).toSet();
    final currentBranch = await getCurrentBranch(projDir);

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.contains('->')) continue; // Skip HEAD -> origin/master

      // trimmed is like "origin/feature-a" or "origin/中文分支"
      final parts = trimmed.split('/');
      if (parts.length < 2) continue;

      // Assuming remote name is always the first part
      if (parts[0] != remoteName) continue;

      // branch name is the rest
      final branchName = parts.sublist(1).join('/');

      if (!localBranchNames.contains(branchName)) {
        // Local branch does not exist, create it tracking the remote
        try {
          await _runGit(['branch', '--track', branchName, trimmed], projDir);
        } catch (e) {
          print('Failed to create tracking branch $branchName: $e');
        }
      } else if (force) {
        if (branchName != currentBranch) {
          try {
            await _runGit(['branch', '-f', branchName, trimmed], projDir);
          } catch (e) {
            print('Failed to force reset branch $branchName: $e');
          }
        }
      }
    }
  } catch (e) {
    print('Warning: Failed to restore remote branches: $e');
    // Non-fatal, we at least have the clone
  }

  // Post-pull cleanup & sync
  // tracking.json handling:
  // We DO NOT touch tracking.json here. It should be ignored by git (.gitignore).
  // If it exists locally, it stays. If it doesn't, we don't create it here (createTrackingProject does that).
  // We also DO NOT sync savedTracking back to disk because tracking.json is local config.

  if (savedTracking != null && savedTracking.isNotEmpty) {
    // Restore Docx path if needed?
    // Actually, if we just pulled, we might have new content in repoDocxPath.
    // But we don't want to overwrite tracking.json.

    // However, we DO want to sync Repo Docx -> External Docx (the file content)
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

Future<void> rebasePull(String repoName, String username, String token) async {
  final remoteName = repoName.toLowerCase();
  final projDir = _projectDir(repoName);
  final owner = await _resolveRepoOwner(repoName, token);
  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

  // Ensure remote is set correctly
  await addRemote(projDir, remoteName, remoteUrl);

  // git pull --rebase remoteName <current_branch>
  final current = await getCurrentBranch(projDir);
  if (current == null) throw Exception('Cannot rebase in detached HEAD state');

  try {
    print('Executing rebase pull with -X theirs (favoring local changes)...');
    await _runGit(
        ['pull', '--rebase', '-X', 'theirs', remoteName, current], projDir);
  } catch (e) {
    // If rebase fails, abort it to restore state
    try {
      await _runGit(['rebase', '--abort'], projDir);
    } catch (_) {}
    throw Exception('Rebase failed (likely conflicts): $e');
  }

  // After rebase, we might need to sync tracking docx?
  // The rebase updates local files to match remote+local changes.
  // We should probably trigger the standard post-pull sync logic if needed.
  // But standard sync logic in pullFromRemote is internal.
  // Let's minimal sync:
  // Just ensure watcher is running?
  clearCache();
}

Future<void> forkAndReset(String repoName, String newBranchName) async {
  final remoteName = repoName.toLowerCase();
  final projDir = _projectDir(repoName);
  final current = await getCurrentBranch(projDir);
  if (current == null) throw Exception('Cannot fork in detached HEAD state');

  // 1. Create new branch from current HEAD
  await _runGit(['branch', newBranchName], projDir);

  // 2. Reset current branch to remote (assuming remoteName/current)
  // We assume we want to make 'current' match 'remoteName/current'
  // and keep 'newBranchName' as the one with local changes.

  // But wait, if we are in "Push rejected" scenario (local ahead of remote, but non-fast-forward):
  // We want to push 'newBranchName'. We don't necessarily need to reset 'current'.
  // If we are in "Pull rejected" scenario (local ahead of remote):
  // We want 'current' to accept remote changes (reset), and 'newBranchName' to keep local changes.

  // The user prompt says "Fork... set local as another branch".
  // If I just 'checkout -b newBranchName', I am now on newBranchName (with local changes).
  // The 'current' (e.g. master) stays as is (with local changes).
  // This is safe.
  // But for "Pull", the user expects to "resolve" the conflict on 'master'.
  // So 'master' should probably become clean (match remote).

  // Let's implement the "Pull-Fork" logic:
  // 1. Create new branch pointing to current HEAD.
  // 2. Fetch remote (to be sure).
  // 3. Reset current branch to remote/current.
  // 4. Checkout new branch.

  await _runGit(['fetch', remoteName], projDir);

  // Check if remote/current exists
  bool remoteExists = false;
  try {
    await _runGit(['rev-parse', '--verify', '$remoteName/$current'], projDir);
    remoteExists = true;
  } catch (_) {}

  if (remoteExists) {
    await _runGit(['reset', '--hard', '$remoteName/$current'], projDir);
  }

  // Checkout the new branch (which has the preserved local changes)
  await _runGit(['checkout', newBranchName], projDir);

  clearCache();
}

Future<void> forkLocal(String repoName, String newBranchName) async {
  // This is for Push scenario: Just create branch and switch.
  // Or maybe we use the same logic?
  // If push is rejected, it means we have commits.
  // If we 'checkout -b newBranch', we take commits with us.
  // We can then push 'newBranch'.
  // The old branch remains 'ahead'.
  // If we want to 'clean' the old branch, we should reset it.
  // So forkAndReset is actually good for both if the intent is "Move my changes to side branch".
  await forkAndReset(repoName, newBranchName);
}

Future<void> prepareMerge(String repoName, String targetBranch) async {
  final projDir = _projectDir(repoName);
  final trackingFile = File(p.join(projDir, 'tracking.json'));
  if (!trackingFile.existsSync()) {
    throw Exception('No tracking project found (tracking.json missing)');
  }

  final savedTracking = jsonDecode(await trackingFile.readAsString());
  final repoDocxPath = savedTracking['repoDocxPath'] as String?;
  final docxPath = savedTracking['docxPath'] as String?;

  if (repoDocxPath == null || docxPath == null) {
    throw Exception(
        'Tracking configuration invalid (repoDocxPath or docxPath missing)');
  }

  final currentFile = File(docxPath); // This is the user's working file
  // Wait, 'docxPath' is the external file path.
  // 'repoDocxPath' is the path inside the git repo.
  // We need to compare "Current Branch Version" vs "Target Branch Version".
  // Or "Working Copy" vs "Target Branch Version".
  // The user says: "Merge target branch INTO current selected branch".
  // Usually this means Base=Current, New=Target.
  // The result (diff) should replace the tracking file (docxPath).

  // 1. Get Target Branch file content to a temp file
  final targetTemp = File(p.join(Directory.systemTemp.path,
      'target_${DateTime.now().millisecondsSinceEpoch}.docx'));
  try {
    // git show targetBranch:path/to/file.docx > temp.docx
    // We need relative path of repoDocxPath from projDir
    final relPath =
        p.relative(repoDocxPath, from: projDir).replaceAll(r'\', '/');
    final result = await Process.run('git', ['show', '$targetBranch:$relPath'],
        workingDirectory: projDir, stdoutEncoding: null);
    if (result.exitCode != 0) {
      throw Exception(
          'Failed to get file from target branch: ${result.stderr}');
    }
    await targetTemp.writeAsBytes(result.stdout as List<int>);
  } catch (e) {
    if (await targetTemp.exists()) await targetTemp.delete();
    rethrow;
  }

  // 2. Get Current Branch file (HEAD) to a temp file?
  // Or use the current working file (docxPath)?
  // If we use working file, we include uncommitted changes.
  // If we use HEAD, we ignore uncommitted changes.
  // Merging usually happens on clean state.
  // Let's use HEAD to be safe and standard.
  final currentTemp = File(p.join(Directory.systemTemp.path,
      'current_${DateTime.now().millisecondsSinceEpoch}.docx'));
  try {
    final relPath =
        p.relative(repoDocxPath, from: projDir).replaceAll(r'\', '/');
    final result = await Process.run('git', ['show', 'HEAD:$relPath'],
        workingDirectory: projDir, stdoutEncoding: null);
    if (result.exitCode != 0) {
      throw Exception('Failed to get file from HEAD: ${result.stderr}');
    }
    await currentTemp.writeAsBytes(result.stdout as List<int>);
  } catch (e) {
    if (await currentTemp.exists()) await currentTemp.delete();
    if (await targetTemp.exists()) await targetTemp.delete();
    rethrow;
  }

  // 3. Compare HEAD (Original) vs Target (Revised) -> Result (Diff)
  // We want the result to show what Target brings in.
  // Result is saved to a temp docx.
  final diffTemp = File(p.join(Directory.systemTemp.path,
      'diff_${DateTime.now().millisecondsSinceEpoch}.docx'));

  // Call doccmp.ps1
  // We need to locate doccmp.ps1. It is in frontend/lib/doccmp.ps1?
  // But we are in server. The server might not know where frontend is.
  // Assuming we are in development environment, we can find it.
  // The user path is fixed: c:/Users/m1369/Documents/gitbin/frontend/lib/doccmp.ps1
  final psScript = r'c:\Users\m1369\Documents\gitbin\frontend\lib\doccmp.ps1';

  try {
    final args = [
      '-ExecutionPolicy', 'Bypass',
      '-File', psScript,
      '-OriginalPath', currentTemp.path,
      '-RevisedPath', targetTemp.path,
      '-PdfPath', diffTemp.path,
      '-IsDocx' // Enable docx output
    ];

    final pRes = await Process.run('powershell', args);
    if (pRes.exitCode != 0) {
      throw Exception(
          'Word comparison failed: ${pRes.stderr}\nOutput: ${pRes.stdout}');
    }

    // 4. Overwrite tracking file (docxPath) with diffTemp
    if (await diffTemp.exists()) {
      // Backup original file before overwriting
      final backupFile = File('$docxPath.bak');
      if (await currentFile.exists()) {
        await currentFile.copy(backupFile.path);
      }
      await currentFile.writeAsBytes(await diffTemp.readAsBytes());
    } else {
      throw Exception('Comparison script did not generate output file');
    }
  } finally {
    // Cleanup temps
    if (await targetTemp.exists()) await targetTemp.delete();
    if (await currentTemp.exists()) await currentTemp.delete();
    if (await diffTemp.exists()) await diffTemp.delete();
  }
}

Future<void> restoreDocx(String repoName) async {
  final projDir = _projectDir(repoName);
  final trackingFile = File(p.join(projDir, 'tracking.json'));

  if (!trackingFile.existsSync()) {
    throw Exception('Tracking configuration not found');
  }

  final savedTracking = jsonDecode(await trackingFile.readAsString());
  final docxPath = savedTracking['docxPath'] as String?;

  if (docxPath == null) {
    throw Exception('Tracking configuration invalid (docxPath missing)');
  }

  final backupFile = File('$docxPath.bak');
  final currentFile = File(docxPath);

  if (await backupFile.exists()) {
    await backupFile.copy(currentFile.path);
    await backupFile.delete();
  } else {
    // If no backup exists, maybe it was already restored or never created.
    // We can treat this as success or ignore.
  }
}

Future<void> completeMerge(String repoName, String targetBranch) async {
  final projDir = _projectDir(repoName);

  // 1. Sync external file to repo file (Simulate "Update Repo")
  // Because user edited the external file (docxPath).
  final trackingFile = File(p.join(projDir, 'tracking.json'));
  if (trackingFile.existsSync()) {
    final savedTracking = jsonDecode(await trackingFile.readAsString());
    final repoDocxPath = savedTracking['repoDocxPath'] as String?;
    final docxPath = savedTracking['docxPath'] as String?;
    if (repoDocxPath != null && docxPath != null) {
      final extFile = File(docxPath);
      final repoFile = File(repoDocxPath);
      if (extFile.existsSync()) {
        await repoFile.writeAsBytes(await extFile.readAsBytes());
      }

      // Cleanup backup file if exists
      final backupFile = File('$docxPath.bak');
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
    }
  }

  // PRE-MERGE: Capture Current HEAD (The "First Parent" of the upcoming merge)
  final oldHeadLines = await _runGit(['rev-parse', 'HEAD'], projDir);
  final oldHead = oldHeadLines.isNotEmpty ? oldHeadLines.first.trim() : null;

  // 2. Perform Git Merge

  // Strategy:
  // git merge --no-commit --no-ff -s ours targetBranch
  // This creates the merge commit state but keeps HEAD content (which we just overwrote? No, ours keeps HEAD).
  // But wait, we overwrote the repo file with user's resolved content.
  // So HEAD (in working dir) matches User Resolved Content.
  // But 'ours' strategy ignores changes from targetBranch in the merge logic.
  // It says "Merge targetBranch, but ignore its diffs, keep my version".
  // Since "my version" (in working dir) is now the "resolved merge result", this is what we want?
  // No, 'ours' strategy keeps the index matching HEAD. It doesn't look at working dir?
  // Actually 'merge -s ours' creates a commit immediately unless --no-commit is used.
  // If we use --no-commit, index is set to HEAD.
  // We have modified working directory.
  // So we just need to `git add` the file and `git commit`.

  try {
    print('gonna merge');
    await _runGit(
        ['merge', '--no-commit', '--no-ff', '-s', 'ours', targetBranch],
        projDir);
  } catch (e) {
    // If it fails (e.g. already up to date), handle it?
    // "Already up to date" might throw.
    print('Merge command result: $e');
    if (e.toString().contains('Already up to date')) {
      // Continue to commit if we have changes
    } else {
      throw e;
    }
  }

  // Handle edges file merging manually (since we use -s ours)
  final edgesFile = File(p.join(projDir, 'edges'));
  List<String>? targetEdgesLines;
  try {
    targetEdgesLines = await _runGit(['show', '$targetBranch:edges'], projDir);
  } catch (_) {
    // Target likely has no edges file
  }

  if (edgesFile.existsSync() &&
      targetEdgesLines != null &&
      targetEdgesLines.isNotEmpty) {
    // Case 3: Both exist -> Merge Algorithm
    final currentLines = await edgesFile.readAsLines();

    // Strip first line (dummy commit id)
    if (currentLines.isNotEmpty) currentLines.removeAt(0);
    // Strip first line from target as well
    if (targetEdgesLines.isNotEmpty) targetEdgesLines.removeAt(0);

    // Merge (Set union)
    final merged = <String>{...currentLines, ...targetEdgesLines};
    print("both exist");
    // Write back with dummy header
    await edgesFile.writeAsString(
        '0000000000000000000000000000000000000000\n${merged.join('\n')}');
  } else if (!edgesFile.existsSync() &&
      targetEdgesLines != null &&
      targetEdgesLines.isNotEmpty) {
    // Case 2: Current null, Target exists -> Use Target
    print("target exist");
    await edgesFile.writeAsString(targetEdgesLines.join('\n'));
  }
  // Case 1: Current exists, Target null -> Keep Current (Do nothing)
  // Case 4: Both null -> Do nothing

  // Resolve target hash early for edge update
  final targetHashLines = await _runGit(['rev-parse', targetBranch], projDir);
  final targetHash =
      targetHashLines.isNotEmpty ? targetHashLines.first.trim() : null;

  // 4. Update edges file with new connection (Moved BEFORE Commit)
  // This ensures the new edge line is included in the merge commit.
  if (targetHash != null && oldHead != null) {
    final lines =
        edgesFile.existsSync() ? await edgesFile.readAsLines() : <String>[];
    if (lines.isEmpty) {
      // Placeholder for first line
      lines.add('0000000000000000000000000000000000000000');
    }
    // User requested edge: Old Head -> Target Head
    // (Instead of Merge Head -> Target Head)
    // This draws a line connecting the two branch tips before the merge commit.
    final edgeLine = '$oldHead $targetHash';
    if (!lines.contains(edgeLine)) {
      lines.add(edgeLine);
      await edgesFile.writeAsString(lines.join('\n'));
    }
  }

  // 3. Commit
  print('Committing merge changes...');

  await _runGit(['add', '.'], projDir);
  // We need a commit message.
  await _runGit([
    'commit',
    '-m',
    'Merge branch \'$targetBranch\' into HEAD (Binary Resolved)'
  ], projDir);

  print('Clearing cache after merge...');
  clearCache();
}

Future<List<String>> findIdenticalCommit(String name) async {
  final projDir = _projectDir(name);
  final dir = Directory(projDir);
  if (!dir.existsSync()) {
    throw Exception('project not found');
  }

  var tracking = await _readTracking(name);
  String? repoDocxPath = tracking['repoDocxPath'] as String?;
  if (repoDocxPath == null || repoDocxPath.trim().isEmpty) {
    repoDocxPath = _findRepoDocx(projDir);
  }
  if (repoDocxPath == null) {
    throw Exception('No .docx file found in repository');
  }

  final docxRel = p.relative(repoDocxPath, from: projDir);
  final gitRelPath = docxRel.replaceAll(r'\', '/');

  // Get all commits (IDs only) from ALL branches
  final log = await _runGit(['log', '--all', '--format=%H'], projDir);
  final commitIds =
      log.where((l) => l.trim().isNotEmpty).map((l) => l.trim()).toList();
  print("commitIds:$commitIds");
  final tmpDir = await Directory.systemTemp.createTemp('git_ident_check_');
  final List<String> identicals = [];
  try {
    for (final commitId in commitIds) {
      final tmpFile = p.join(tmpDir.path, '$commitId.docx');
      try {
        await _runGitToFile(
            ['show', '$commitId:$gitRelPath'], projDir, tmpFile);
        final isIdentical = await _checkDocxIdentical(repoDocxPath, tmpFile);
        print(
            "BigIdentical$isIdentical，thiscommitid：$commitId,repoDocxPath=$repoDocxPath,tmpFile=$tmpFile");
        if (isIdentical) {
          identicals.add(commitId);
        }
      } catch (_) {
        // File might not exist in that commit or other error
      }
    }
  } finally {
    //try {
    //  tmpDir.deleteSync(recursive: true);
    //} catch (_) {}
  }
  return identicals;
}
