import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'models.dart';

final Map<String, GraphResponse> _graphCache = <String, GraphResponse>{};

const String kContentDirName = 'doc_content';

void clearCache() {
  _graphCache.clear();
}

// --- Helpers for Docx/Folder operations ---

Future<void> _unzipDocx(String docxPath, String destDir) async {
  // Use PowerShell to unzip
  final res = await Process.run('powershell', [
    '-Command',
    'Expand-Archive -Path "$docxPath" -DestinationPath "$destDir" -Force'
  ]);
  if (res.exitCode != 0) {
    throw Exception('Failed to unzip docx: ${res.stderr}');
  }
}

Future<void> _zipDir(String srcDir, String docxPath) async {
  // PowerShell Compress-Archive.
  // We use Get-ChildItem to avoid zipping the root folder itself.
  final cmd =
      "Get-ChildItem -Path '$srcDir' | Compress-Archive -DestinationPath '$docxPath' -Force";
  final res = await Process.run('powershell', ['-Command', cmd]);
  if (res.exitCode != 0) {
    throw Exception('Failed to zip dir: ${res.stderr}');
  }
}

Future<void> _copyDir(String src, String dst) async {
  // Use PowerShell to copy directory contents
  // Copy-Item -Path "src\*" -Destination "dst" -Recurse -Force
  final cmd = 'Copy-Item -Path "$src\\*" -Destination "$dst" -Recurse -Force';
  final res = await Process.run('powershell', ['-Command', cmd]);
  if (res.exitCode != 0) {
    throw Exception('Failed to copy dir: ${res.stderr}');
  }
}

Future<void> _gitArchiveToDocx(
    String repoPath, String commitId, String outDocxPath) async {
  // Use git archive to create a zip (docx) from the doc_content tree
  // git archive --format=zip --output=out.docx <commit>:<kContentDirName>
  final res = await Process.run(
    'git',
    [
      'archive',
      '--format=zip',
      '--output=$outDocxPath',
      '$commitId:$kContentDirName'
    ],
    workingDirectory: repoPath,
  );
  if (res.exitCode != 0) {
    throw Exception('Failed to git archive to docx: ${res.stderr}');
  }
}

// ------------------------------------------

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
      print("git error (exitCode=${res.exitCode}) args=$args");
      print(res.stderr);
      print(res.stdout);
      throw Exception(res.stderr is String ? res.stderr : 'git error');
    }
    final out =
        res.stdout is String ? res.stdout as String : utf8.decode(res.stdout);
    return LineSplitter.split(out).toList();
  } on FormatException {
    print("Git format error!!!");
    final res = await Process.run(
      'git',
      fullArgs,
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    if (res.exitCode != 0) {
      print("git error fallback");
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
  // Add doc_content directory
  await _runGit(['add', kContentDirName], repoPath);
  if (File(p.join(repoPath, 'edges')).existsSync()) {
    await _runGit(['add', 'edges'], repoPath);
  }
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
  await _runGit(['checkout', '-f', branchName], repoPath);
  clearCache();
}

Future<void> addRemote(String repoPath, String name, String url) async {
  try {
    final remotes = await _runGit(['remote'], repoPath);
    if (remotes.contains(name)) {
      await _runGit(['remote', 'set-url', name, url], repoPath);
    } else {
      await _runGit(['remote', 'add', name, url], repoPath);
    }
  } catch (e) {
    print('Failed to add/update remote $name: $e');
  }
}

Future<Uint8List> compareWorking(String repoPath) async {
  final contentDir = Directory(p.join(repoPath, kContentDirName));
  if (!contentDir.existsSync()) {
    throw Exception('No $kContentDirName directory found in repository');
  }

  final tmpDir = await Directory.systemTemp.createTemp('gitdocx_cmp_work_');
  try {
    final p1 = p.join(tmpDir.path, 'HEAD.docx');
    final p2 = p.join(tmpDir.path, 'Working.docx');
    final pdf = p.join(tmpDir.path, 'diff.pdf');

    // HEAD -> p1
    try {
      await _gitArchiveToDocx(repoPath, 'HEAD', p1);
    } catch (e) {
      // If no HEAD, maybe empty? Handle gracefully or throw
      throw Exception('Could not get HEAD content: $e');
    }

    // Working -> p2
    await _zipDir(contentDir.path, p2);

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
  final dir = Directory(p.dirname(f.path));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  await f.writeAsString(jsonEncode(data));
}

String _projectDir(String name) {
  return p.normalize(p.join(_baseDir(), name));
}

// Deprecated: _findRepoDocx (we use kContentDirName now)
// We still need to find external file/dir sometimes

final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};

Future<Uint8List> compareCommits(
    String repoPath, String commit1, String commit2) async {
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

  final tmpDir = await Directory.systemTemp.createTemp('gitdocx_cmp_');
  try {
    final p1 = p.join(tmpDir.path, 'old.docx');
    final p2 = p.join(tmpDir.path, 'new.docx');
    final pdf = p.join(tmpDir.path, 'diff.pdf');

    await _gitArchiveToDocx(repoPath, commit1, p1);
    await _gitArchiveToDocx(repoPath, commit2, p2);

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

  // Handle doc content
  final contentDir = Directory(p.join(projDir, kContentDirName));
  if (contentDir.existsSync()) {
    contentDir.deleteSync(recursive: true);
  }
  contentDir.createSync();

  if (docxPath != null && docxPath.trim().isNotEmpty) {
    if (FileSystemEntity.isDirectorySync(docxPath)) {
      await _copyDir(docxPath, contentDir.path);
    } else if (FileSystemEntity.isFileSync(docxPath)) {
      await _unzipDocx(docxPath, contentDir.path);
    }
  }

  final tracking = await _readTracking(name);
  tracking['name'] = name;
  if (docxPath != null && docxPath.trim().isNotEmpty) {
    tracking['docxPath'] = _sanitizeFsPath(docxPath);
  }
  tracking['repoDocxPath'] = contentDir.path;

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
  final normalized = p.normalize(repoPath);
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
  
  // Verify source exists
  bool sourceExists = false;
  if (sourcePath != null && sourcePath.isNotEmpty) {
    if (FileSystemEntity.isFileSync(sourcePath) || FileSystemEntity.isDirectorySync(sourcePath)) {
        sourceExists = true;
    }
  }

  if (!sourceExists) {
    return {'needDocx': true, 'repoPath': projDir};
  }
  
  // Ensure content dir exists in repo
  final contentDir = Directory(p.join(projDir, kContentDirName));
  if (!contentDir.existsSync()) {
      contentDir.createSync();
  }
  tracking['repoDocxPath'] = contentDir.path;
  await _writeTracking(name, tracking);

  // Compare Source vs HEAD
  bool restored = false;
  
  final tmpDir = await Directory.systemTemp.createTemp('git_head_check_');
  try {
    final headDocx = p.join(tmpDir.path, 'HEAD.docx');
    bool hasHead = false;
    try {
        await _gitArchiveToDocx(projDir, 'HEAD', headDocx);
        hasHead = true;
    } catch (_) {}

    if (hasHead) {
        final isIdentical = await _checkDocxIdentical(sourcePath!, headDocx);
        print("identical? $isIdentical");
        if (isIdentical) {
            // Restore working copy (repo/doc_content) to HEAD
             await _runGit(['checkout', 'HEAD', '--', kContentDirName], projDir);
             restored = true;
        }
    }
  } finally {
      try { tmpDir.deleteSync(recursive: true); } catch(_) {}
  }

  print('restored? $restored');
  if (!restored) {
    // Update repo content from source
    // Clear content dir
    if (contentDir.existsSync()) contentDir.deleteSync(recursive: true);
    contentDir.createSync();
    
    if (FileSystemEntity.isDirectorySync(sourcePath!)) {
        await _copyDir(sourcePath, contentDir.path);
    } else {
        await _unzipDocx(sourcePath, contentDir.path);
    }
  }

  final head = await getHead(projDir);
  final changed = !restored;
  return {
    'workingChanged': changed,
    'repoPath': projDir,
    'head': head,
  };
}

Future<bool> _checkDocxIdentical(String externalPath, String compareToDocx) async {
  // compareToDocx is a .docx file (e.g. from HEAD archive)
  // externalPath could be .docx or dir
  
  final tmpDir = await Directory.systemTemp.createTemp('ident_check_');
  try {
      String path1 = externalPath;
      String path2 = compareToDocx;
      
      // If external is dir, zip it
      if (FileSystemEntity.isDirectorySync(externalPath)) {
          final zip1 = p.join(tmpDir.path, 'ext.docx');
          await _zipDir(externalPath, zip1);
          path1 = zip1;
      }
      
      // Use existing compare logic via HTTP or direct?
      // Direct call is easier since we are in same process, 
      // but _checkDocxIdentical in original code called localhost:5000/compare.
      // localhost:5000 is 'compare' service (Heidegger?). 
      // If we assume the compare service handles .docx, we are good.
      // Yes, the original code used localhost:5000.
      
      final f1 = File(path1);
      final f2 = File(path2);
      if (!f1.existsSync() || !f2.existsSync()) return false;

      final client = HttpClient();
      final req = await client.post('localhost', 5000, '/compare');
      final boundary = '---gitbin-boundary-${DateTime.now().millisecondsSinceEpoch}';
      req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});

      void writePart(String fieldName, String filename, List<int> content) {
        req.write('--$boundary\r\n');
        req.write('Content-Disposition: form-data; name="$fieldName"; filename="$filename"\r\n');
        req.write('Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n\r\n');
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
      print('Check identical failed: $e');
      return false;
  } finally {
      try { tmpDir.deleteSync(recursive: true); } catch(_) {}
  }
}

Future<Uint8List> previewVersion(String repoPath, String commitId) async {
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

  final tmpDir = await Directory.systemTemp.createTemp('gitdocx_prev_');
  try {
    final p1 = p.join(tmpDir.path, 'preview.docx');
    final pdf = p.join(tmpDir.path, 'preview.pdf');

    await _gitArchiveToDocx(repoPath, commitId, p1);

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
  await _runGit(['reset', '--hard', commitId], repoPath);
  clearCache();
}

Future<void> rollbackVersion(String projectName, String commitId) async {
  final repoPath = _projectDir(projectName);
  
  // Checkout doc_content from commitId to working dir
  // git checkout commitId -- doc_content
  await _runGit(['checkout', commitId, '--', kContentDirName], repoPath);

  // Sync to external
  final tracking = await _readTracking(projectName);
  final docxPath = tracking['docxPath'] as String?;

  if (docxPath != null) {
    final contentDir = Directory(p.join(repoPath, kContentDirName));
    if (FileSystemEntity.isDirectorySync(docxPath)) {
        // Target is dir: Copy contentDir to docxPath
        // Clean target first? Maybe risky. But user asked for rollback.
        // We overwrite.
        await _copyDir(contentDir.path, docxPath);
    } else {
        // Target is file: Zip contentDir to docxPath
        await _zipDir(contentDir.path, docxPath);
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
  
  final sub = _watchers[name];
  if (sub != null) return;

  // Watch file or directory
  final isDir = FileSystemEntity.isDirectorySync(docx);
  if (!isDir && !File(docx).existsSync()) return;

  final s = isDir 
      ? Directory(docx).watch(events: FileSystemEvent.all, recursive: true)
      : File(docx).watch(events: FileSystemEvent.modify);

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

// ... Remote operations (ensureRemoteRepoExists, _resolveRepoOwner, pushToRemote, etc)
// These generally work on the git repo, which is fine as we just changed content structure.
// But _checkIfBehind might need care? No, it uses git commands on commits.
// I will just copy them back.

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
    } else if (resp.statusCode == 409) {
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
      if (repo['name'].toLowerCase() == repoName) {
        return repo['owner']['login'] as String;
      }
    }
    return null;
  }

  try {
    final resp = await http.get(Uri.parse('$giteaUrl/api/v1/user/repos'),
        headers: headers);
    if (resp.statusCode == 200) {
      final owner = findOwnerInList(jsonDecode(resp.body));
      if (owner != null) return owner;
    }
  } catch (e) {
    print('Error checking owned repos: $e');
  }

  try {
    final resp = await http.get(
        Uri.parse('$giteaUrl/api/v1/user/repos?type=member'),
        headers: headers);
    if (resp.statusCode == 200) {
      final owner = findOwnerInList(jsonDecode(resp.body));
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
  final repoName = p.basename(repoPath);

  String owner;
  try {
    owner = await _resolveRepoOwner(repoName, token);
  } catch (_) {
    await ensureRemoteRepoExists(repoName, token);
    owner = username;
  }

  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

  final args = ['push'];
  if (force) args.add('--force');
  args.add(remoteUrl);

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
    args.add('refs/heads/*:refs/heads/*');
  } else {
    for (final b in localBranches) {
      args.add('refs/heads/$b:refs/heads/$b');
    }
  }

  List<String> output = [];
  try {
    output = await _runGit(args, repoPath);
  } catch (e) {
    if (!force) {
      await _checkIfBehind(repoPath, remoteUrl);
    }
    rethrow;
  }

  try {
    await _runGit(['fetch', remoteUrl], repoPath);
  } catch (e) {
    print('Fetch after push failed: $e');
  }

  if (!force) {
    final outStr = output.join('\n');
    if (outStr.contains('Everything up-to-date')) {
      await _checkIfBehind(repoPath, remoteUrl);
    }
  }
}

Future<void> _checkIfBehind(String repoPath, String remoteUrl) async {
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

  for (final branch in localRefs.keys) {
    final localHash = localRefs[branch];
    final remoteHash = remoteRefs[branch];

    if (remoteHash != null && localHash != remoteHash) {
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
            'Push rejected: Local branch "$branch" is behind remote (non-fast-forward).');
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
  final gitDir = Directory(p.join(projDir, '.git'));

  final owner = await _resolveRepoOwner(repoName, token);
  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

  Map<String, dynamic>? savedTracking;
  bool isFresh = !dir.existsSync() || !gitDir.existsSync();

  if (!isFresh && force) {
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
    if (!force) {
      try {
        final trackingFile = _trackingFile(repoName);
        if (trackingFile.existsSync()) {
          try {
            await _runGit(['checkout', 'HEAD', '--', '.'], projDir);
          } catch (e) {}
        }
      } catch (e) {}

      try {
        await _runGit(['fetch', remoteUrl, 'HEAD'], projDir);
        final mergeBaseRes = await Process.run(
          'git',
          ['merge-base', '--is-ancestor', 'HEAD', 'FETCH_HEAD'],
          workingDirectory: projDir,
          runInShell: true,
        );
        if (mergeBaseRes.exitCode != 0) {
          return {
            'status': 'error',
            'errorType': 'ahead',
            'path': projDir,
            'message':
                'Local branch is ahead of remote or diverged.'
          };
        }
      } catch (e) {}
    }

    savedTracking = await _readTracking(repoName);

    try {
      await addRemote(projDir, remoteName, remoteUrl);
      await _runGit(['fetch', remoteName], projDir);
      final current = await getCurrentBranch(projDir);

      if (current != null) {
        await _runGit(['reset', '--hard', '$remoteName/$current'], projDir);
      } else {
        await _runGit(['checkout', 'master'], projDir);
        await _runGit(['reset', '--hard', '$remoteName/master'], projDir);
      }
      await _runGit(['remote', 'prune', remoteName], projDir);
    } catch (e) {
      throw Exception('Standard pull failed: $e');
    }
  } else {
    final base = Directory(_baseDir());
    if (!base.existsSync()) {
      base.createSync(recursive: true);
    }
    final res = await Process.run(
      'git',
      ['clone', '-o', remoteName, remoteUrl, projDir],
      runInShell: true,
    );
    if (res.exitCode != 0) {
      throw Exception('Clone failed: ${res.stderr}');
    }
  }

  try {
    final lines = await _runGit(['branch', '-r'], projDir);
    final localBranches = await getBranches(projDir);
    final localBranchNames = localBranches.map((b) => b.name).toSet();
    final currentBranch = await getCurrentBranch(projDir);

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.contains('->')) continue;
      final parts = trimmed.split('/');
      if (parts.length < 2) continue;
      if (parts[0] != remoteName) continue;
      final branchName = parts.sublist(1).join('/');

      if (!localBranchNames.contains(branchName)) {
        try {
          await _runGit(['branch', '--track', branchName, trimmed], projDir);
        } catch (e) {}
      } else if (force) {
        if (branchName != currentBranch) {
          try {
            await _runGit(['branch', '-f', branchName, trimmed], projDir);
          } catch (e) {}
        }
      }
    }
  } catch (e) {}

  if (savedTracking != null && savedTracking.isNotEmpty) {
    final docxPath = savedTracking['docxPath'] as String?;

    if (docxPath != null) {
      // Sync Repo Content -> External Docx
      final contentDir = Directory(p.join(projDir, kContentDirName));
      if (contentDir.existsSync()) {
         if (FileSystemEntity.isDirectorySync(docxPath)) {
            await _copyDir(contentDir.path, docxPath);
         } else {
            await _zipDir(contentDir.path, docxPath);
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
      if (name.startsWith('.')) continue;
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

  await addRemote(projDir, remoteName, remoteUrl);
  final current = await getCurrentBranch(projDir);
  if (current == null) throw Exception('Cannot rebase in detached HEAD state');

  try {
    await _runGit(
        ['pull', '--rebase', '-X', 'theirs', remoteName, current], projDir);
  } catch (e) {
    try {
      await _runGit(['rebase', '--abort'], projDir);
    } catch (_) {}
    throw Exception('Rebase failed (likely conflicts): $e');
  }
  clearCache();
}

Future<void> forkLocal(String repoName, String newBranchName) async {
  final repoPath = _projectDir(repoName);
  // forkAndReset logic inline or separate? Inline for simplicity.
  // checkout -b newBranch
  // fetch remote
  // reset current (which was master) to remote/master?
  // User wants to move local changes to new branch.
  
  // 1. Create branch (keeps local changes)
  await _runGit(['checkout', '-b', newBranchName], repoPath);
  
  // The old branch is still there, but we are now on new branch.
  // That's usually enough for "Fork Local".
  // If we want to reset the old branch, we need to checkout it, reset, then checkout new.
  // But we are now safe on new branch.
  
  clearCache();
}

Future<void> prepareMerge(String repoName, String targetBranch) async {
  final projDir = _projectDir(repoName);
  final trackingFile = File(p.join(projDir, 'tracking.json'));
  if (!trackingFile.existsSync()) {
    throw Exception('No tracking project found');
  }

  final savedTracking = jsonDecode(await trackingFile.readAsString());
  final docxPath = savedTracking['docxPath'] as String?;

  if (docxPath == null) {
    throw Exception('Tracking configuration invalid');
  }

  final tmpDir = await Directory.systemTemp.createTemp('merge_prep_');
  try {
      // 1. Target -> target.docx
      final targetDocx = p.join(tmpDir.path, 'target.docx');
      await _gitArchiveToDocx(projDir, targetBranch, targetDocx);
      
      // 2. HEAD -> head.docx
      final headDocx = p.join(tmpDir.path, 'head.docx');
      await _gitArchiveToDocx(projDir, 'HEAD', headDocx);
      
      // 3. Compare -> diff.docx
      final diffDocx = p.join(tmpDir.path, 'diff.docx');
      final psScript = r'c:\Users\m1369\Documents\gitbin\frontend\lib\doccmp.ps1';
      
      final pRes = await Process.run('powershell', [
          '-ExecutionPolicy', 'Bypass',
          '-File', psScript,
          '-OriginalPath', headDocx,
          '-RevisedPath', targetDocx,
          '-PdfPath', diffDocx,
          '-IsDocx'
      ]);
      
      if (pRes.exitCode != 0 || !File(diffDocx).existsSync()) {
          throw Exception('Merge comparison failed');
      }
      
      // 4. Update External (docxPath)
      // Backup
      final backupPath = '$docxPath.bak';
      if (FileSystemEntity.isDirectorySync(docxPath)) {
         // Backup Dir?
         // _copyDir(docxPath, backupPath);
      } else if (File(docxPath).existsSync()) {
         File(docxPath).copySync(backupPath);
      }
      
      if (FileSystemEntity.isDirectorySync(docxPath)) {
          // Unzip diffDocx to docxPath
          // Clean target?
          // Directory(docxPath).deleteSync(recursive: true);
          // Directory(docxPath).createSync();
          await _unzipDocx(diffDocx, docxPath);
      } else {
          // Overwrite file
          File(diffDocx).copySync(docxPath);
      }
      
  } finally {
      try { tmpDir.deleteSync(recursive: true); } catch(_) {}
  }
}

Future<void> restoreDocx(String repoName) async {
    // Restore backup if exists
    // Simplification: Not fully implemented for dirs
}

Future<void> completeMerge(String repoName, String targetBranch) async {
  final projDir = _projectDir(repoName);
  
  // 1. Sync External -> Repo Content
  final tracking = await _readTracking(repoName);
  final docxPath = tracking['docxPath'] as String?;
  if (docxPath != null) {
      final contentDir = Directory(p.join(projDir, kContentDirName));
      if (contentDir.existsSync()) contentDir.deleteSync(recursive: true);
      contentDir.createSync();
      
      if (FileSystemEntity.isDirectorySync(docxPath)) {
          await _copyDir(docxPath, contentDir.path);
      } else if (File(docxPath).existsSync()) {
          await _unzipDocx(docxPath, contentDir.path);
      }
  }
  
  final oldHead = await getHead(projDir);
  
  // 2. Merge -s ours
  try {
    await _runGit(
        ['merge', '--no-commit', '--no-ff', '-s', 'ours', targetBranch],
        projDir);
  } catch (e) {
    if (!e.toString().contains('Already up to date')) throw e;
  }
  
  // Handle edges
  final edgesFile = File(p.join(projDir, 'edges'));
  // ... (Edge logic same as before, omitted for brevity, but needed)
  // Re-implementing edge logic quickly:
  List<String>? targetEdges;
  try {
     final out = await _runGit(['show', '$targetBranch:edges'], projDir);
     targetEdges = out;
  } catch (_) {}
  
  if (edgesFile.existsSync() && targetEdges != null && targetEdges.isNotEmpty) {
      final current = await edgesFile.readAsLines();
      if (current.isNotEmpty) current.removeAt(0);
      if (targetEdges.isNotEmpty) targetEdges.removeAt(0);
      final merged = {...current, ...targetEdges};
      await edgesFile.writeAsString('0000000000000000000000000000000000000000\n${merged.join('\n')}');
  } else if (!edgesFile.existsSync() && targetEdges != null) {
      await edgesFile.writeAsString(targetEdges.join('\n'));
  }
  
  final targetHashLines = await _runGit(['rev-parse', targetBranch], projDir);
  final targetHash = targetHashLines.isNotEmpty ? targetHashLines.first.trim() : null;
  if (targetHash != null && oldHead != null) {
      final lines = edgesFile.existsSync() ? await edgesFile.readAsLines() : <String>[];
      if (lines.isEmpty) lines.add('0000000000000000000000000000000000000000');
      final edgeLine = '$oldHead $targetHash';
      if (!lines.contains(edgeLine)) {
          lines.add(edgeLine);
          await edgesFile.writeAsString(lines.join('\n'));
      }
  }

  await _runGit(['add', '.'], projDir);
  await _runGit(['commit', '-m', 'Merge branch \'$targetBranch\' into HEAD'], projDir);
  clearCache();
}

Future<List<String>> findIdenticalCommit(String name) async {
  final projDir = _projectDir(name);
  final tracking = await _readTracking(name);
  // We assume repo has doc_content
  
  final log = await _runGit(['log', '--all', '--format=%H'], projDir);
  final commitIds = log.where((l) => l.trim().isNotEmpty).map((l) => l.trim()).toList();
  
  final identicals = <String>[];
  final tmpDir = await Directory.systemTemp.createTemp('ident_find_');
  try {
      // Check external path
      final docxPath = tracking['docxPath'] as String?;
      if (docxPath == null) return [];
      
      for (final cid in commitIds) {
          final tmpDocx = p.join(tmpDir.path, '$cid.docx');
          try {
              await _gitArchiveToDocx(projDir, cid, tmpDocx);
              final isId = await _checkDocxIdentical(docxPath, tmpDocx);
              if (isId) identicals.add(cid);
          } catch (_) {}
      }
  } finally {
      try { tmpDir.deleteSync(recursive: true); } catch(_) {}
  }
  return identicals;
}
