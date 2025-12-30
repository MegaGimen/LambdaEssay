import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'models.dart';

class PullPreviewResult {
  final GraphResponse current;
  final GraphResponse target;
  final GraphResponse? result;
  final Map<String, int> rowMapping;
  final bool hasConflicts;
  final List<String> conflictingFiles;

  PullPreviewResult({
    required this.current,
    required this.target,
    this.result,
    required this.rowMapping,
    this.hasConflicts = false,
    this.conflictingFiles = const [],
  });

  Map<String, dynamic> toJson() => {
        'current': current.toJson(),
        'target': target.toJson(),
        'result': result?.toJson(),
        'rowMapping': rowMapping,
        'hasConflicts': hasConflicts,
        'conflictingFiles': conflictingFiles,
      };
}

Future<dynamic> Function(Map<String, dynamic>)? pluginSender;

class Mutex {
  Future<void> _last = Future.value();

  Future<T> protect<T>(Future<T> Function() block) async {
    final prev = _last;
    final completer = Completer<void>();
    _last = completer.future;
    try {
      await prev;
      return await block();
    } finally {
      completer.complete();
    }
  }
}

final Map<String, Mutex> _repoLocks = {};

Future<T> _withRepoLock<T>(String repoPath, Future<T> Function() block) async {
  final key = p.normalize(repoPath);
  final mutex = _repoLocks.putIfAbsent(key, () => Mutex());
  return mutex.protect(block);
}

final Map<String, GraphResponse> _graphCache = <String, GraphResponse>{};
final Map<String, PullPreviewResult> _previewCache = {};

const String kContentDirName = 'doc_content';
const String kRepoDocxName = 'content.docx';

void clearCache() {
  _graphCache.clear();
  _previewCache.clear();
}

// --- Helpers for Docx/Folder operations ---

Future<void> _ensureRepoDocx(String repoPath) async {
  // Only zip if content.docx is missing
  final docxPath = p.join(repoPath, kRepoDocxName);
  if (File(docxPath).existsSync()) return;

  final contentDir = p.join(repoPath, kContentDirName);
  if (Directory(contentDir).existsSync()) {
    await _zipDir(contentDir, docxPath);
  }
}

Future<void> _forceRegenerateRepoDocx(String repoPath) async {
  int timestamp1 = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // Used when Git updates the folder (checkout/pull/reset)
  // We must update content.docx to reflect new state
  final docxPath = p.join(repoPath, kRepoDocxName);
  final f = File(docxPath);
  if (f.existsSync()) {
    try {
      f.deleteSync();
    } catch (_) {}
  }
  await _ensureRepoDocx(repoPath);
  int timestamp2 = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  print("[_forceRegenerateRepoDocx] costs ${timestamp2 - timestamp1} sec");
}

Future<void> _updateContentDocx(String repoPath, String sourceDocxPath) async {
  // Just update content.docx from source. Do NOT unzip to doc_content yet.
  final docxPath = p.join(repoPath, kRepoDocxName);
  if (FileSystemEntity.isDirectorySync(sourceDocxPath)) {
    await _zipDir(sourceDocxPath, docxPath);
  } else {
    try {
      final bytes = File(sourceDocxPath).readAsBytesSync();
      File(docxPath).writeAsBytesSync(bytes, flush: true);
    } catch (e) {
      print("Error copying source docx (locked?): $e");
      rethrow;
    }
  }
}

Future<void> _writeExternalDocx(String repoPath, String sourcePath) async {
  final name = p.basename(repoPath);
  final tracking = await _readTracking(name);
  final docxPath = tracking['docxPath'] as String?;

  if (docxPath == null) return;

  bool diskWriteSuccess = false;
  Object? diskError;

  // 1. Try disk write first
  print('Updating external docx via disk write: $docxPath');
  try {
    if (FileSystemEntity.isDirectorySync(docxPath)) {
      if (FileSystemEntity.isDirectorySync(sourcePath)) {
        await _copyDir(sourcePath, docxPath);
      } else {
        // Unzip source file to target dir
        if (Directory(docxPath).existsSync()) {
          Directory(docxPath).deleteSync(recursive: true);
        }
        Directory(docxPath).createSync();
        await _unzipDocx(sourcePath, docxPath);
      }
    } else {
      if (FileSystemEntity.isDirectorySync(sourcePath)) {
        // Zip source dir to target file
        await _zipDir(sourcePath, docxPath);
      } else {
        // Safer copy: read bytes and write bytes to avoid 183
        // File(sourcePath).copySync(docxPath);
        final bytes = File(sourcePath).readAsBytesSync();
        File(docxPath).writeAsBytesSync(bytes, flush: true);
      }
    }
    diskWriteSuccess = true;
  } catch (e) {
    print('Disk write failed: $e');
    diskError = e;
  }

  if (diskWriteSuccess) return;
  // 2. If disk write failed, try plugin if source is a file
  bool handled = false;
  if (pluginSender != null && File(sourcePath).existsSync()) {
    print('Attempting update via plugin due to disk write failure...');
    try {
      final bytes = await File(sourcePath).readAsBytes();
      final base64Content = base64Encode(bytes);

      final result = await pluginSender!({
        'action': 'replace',
        'payload': {
          'content': base64Content,
          'type': 'base64',
          'options': {'checkPath': docxPath}
        }
      });

      if (result == true) {
        handled = true;
        print('Updated external docx via plugin: $docxPath');
      } else {
        print('Plugin update skipped/failed (result: $result)');
      }
    } catch (e) {
      print('Plugin write attempt failed: $e');
    }
  }

  if (!handled) {
    if (diskError != null) {
      // If plugin couldn't handle it, rethrow the disk error
      throw diskError;
    }
  }
}

Future<void> _flushDocxToContent(String repoPath) async {
  // Unzip content.docx -> doc_content (Only used before commit)
  final docxPath = p.join(repoPath, kRepoDocxName);
  if (!File(docxPath).existsSync()) return;

  final contentDir = Directory(p.join(repoPath, kContentDirName));
  if (contentDir.existsSync()) {
    contentDir.deleteSync(recursive: true);
  }
  contentDir.createSync();
  await _unzipDocx(docxPath, contentDir.path);
}

Future<void> _unzipDocx(String docxPath, String destDir) async {
  String zipPath = docxPath;
  Directory? tempDir;

  // PowerShell Expand-Archive requires .zip extension
  if (!docxPath.toLowerCase().endsWith('.zip')) {
    tempDir = Directory.systemTemp.createTempSync('gitdocx_unzip_');
    zipPath = p.join(tempDir.path, 'temp.zip');
    File(docxPath).copySync(zipPath);
  }

  try {
    final res = await Process.run('powershell', [
      '-Command',
      'Expand-Archive -Path "$zipPath" -DestinationPath "$destDir" -Force'
    ]);
    if (res.exitCode != 0) {
      throw Exception('Failed to unzip docx: ${res.stderr}');
    }
  } finally {
    if (tempDir != null) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

Future<void> _zipDir(String srcDir, String docxPath) async {
  String zipPath = docxPath;
  bool needsRename = false;
  Directory? tempDir;

  // PowerShell Compress-Archive requires .zip extension
  if (!docxPath.toLowerCase().endsWith('.zip')) {
    tempDir = Directory.systemTemp.createTempSync('gitdocx_zip_');
    zipPath = p.join(tempDir.path, 'temp.zip');
    needsRename = true;
  }

  try {
    final cmd =
        "Get-ChildItem -Path '$srcDir' | Compress-Archive -DestinationPath '$zipPath' -Force";
    final res = await Process.run('powershell', ['-Command', cmd]);
    if (res.exitCode != 0) {
      throw Exception('Failed to zip dir: ${res.stderr}');
    }

    if (needsRename) {
      final f = File(zipPath);
      if (f.existsSync()) {
        f.copySync(docxPath);
      } else {
        throw Exception('Failed to create zip file at $zipPath');
      }
    }
  } finally {
    if (tempDir != null) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
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

Future<void> fetchAll(String repoPath) async {
  return _withRepoLock(repoPath, () async {
    await _runGit(['fetch', '--all'], repoPath);
  });
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
      'mingw64/bin/git.exe',
      fullArgs,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      environment: {'GIT_TERMINAL_PROMPT': '0'}, // Prevent interactive prompts
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
      'mingw64/bin/git.exe',
      fullArgs,
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
      environment: {'GIT_TERMINAL_PROMPT': '0'},
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

Future<List<Branch>> getRemoteBranches(
    String repoPath, String? remoteName) async {
  final args = [
    'for-each-ref',
    '--format=%(refname:short)|%(objectname)',
  ];
  if (remoteName != null && remoteName.isNotEmpty) {
    args.add('refs/remotes/$remoteName');
  } else {
    args.add('refs/remotes');
  }

  final lines = await _runGit(args, repoPath);
  final result = <Branch>[];
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    final parts = l.split('|');
    if (parts.length >= 2) {
      final name = parts[0];
      if (name.endsWith('/HEAD')) continue;
      if (remoteName != null && name == remoteName) continue;
      result.add(Branch(name: name, head: parts[1].toLowerCase()));
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

Future<List<List<String>>> _collectAllEdges(
    String repoPath, List<CommitNode> commits) async {
  final uniquePairs = <String>{};
  final commitIds = commits.map((c) => c.id).toSet();

  // Regex for SHA1 pairs (40 hex chars), ignoring potential "zeros" line
  final edgeRegex = RegExp(r'([0-9a-fA-F]{40})\s+([0-9a-fA-F]{40})');
  final zeroRegex = RegExp(r'^[0]+$');

  void parseContent(String content) {
    final matches = edgeRegex.allMatches(content);
    for (final m in matches) {
      final u = m.group(1)!.toLowerCase();
      final v = m.group(2)!.toLowerCase();
      if (zeroRegex.hasMatch(u) || zeroRegex.hasMatch(v)) continue;
      uniquePairs.add('$u|$v');
    }
  }

  // 1. Try to read local 'edges' file in the repo root
  try {
    final localFile = File(p.join(repoPath, 'edges'));
    if (localFile.existsSync()) {
      final content = await localFile.readAsString();
      parseContent(content);
    }
  } catch (_) {}

  // 2. Try to read from each commit
  Future<void> fetch(CommitNode c) async {
    try {
      final res = await Process.run(
        'mingw64/bin/git.exe',
        ['show', '${c.id}:edges'],
        workingDirectory: repoPath,
        stdoutEncoding: utf8,
      );
      if (res.exitCode == 0) {
        parseContent(res.stdout.toString());
      }
    } catch (_) {}
  }

  final int batchSize = 20;
  for (var i = 0; i < commits.length; i += batchSize) {
    final end =
        (i + batchSize < commits.length) ? i + batchSize : commits.length;
    final batch = commits.sublist(i, end);
    await Future.wait(batch.map(fetch));
  }

  final result = <List<String>>[];
  for (final pair in uniquePairs) {
    final parts = pair.split('|');
    final u = parts[0];
    final v = parts[1];

    if (!commitIds.contains(u) || !commitIds.contains(v)) continue;
    // Removed allParents check as it was too restrictive (filtered out tips)

    result.add([u, v]);
  }
  return result;
}

Future<GraphResponse> getGraph(String repoPath,
    {int? limit, bool includeLocal = true, List<String>? remoteNames}) async {
  return _withRepoLock(repoPath, () async {
    return _getGraphUnlocked(repoPath,
        limit: limit, includeLocal: includeLocal, remoteNames: remoteNames);
  });
}

Future<GraphResponse> _getGraphUnlocked(String repoPath,
    {int? limit, bool includeLocal = true, List<String>? remoteNames}) async {
  final key = '${repoPath}|${limit ?? 0}|$includeLocal|$remoteNames';
  // final cached = _graphCache[key];
  // if (cached != null) {
  //   print('Graph cache hit for $key');
  //   return cached;
  // }
  // Disable cache for preview accuracy
  print('Graph fetching for $key...');

  final branches = <Branch>[];
  if (includeLocal) {
    branches.addAll(await getBranches(repoPath));
  }
  if (remoteNames != null) {
    if (remoteNames.isEmpty) {
      final remotes = await _runGit(['remote'], repoPath);
      for (final r in remotes) {
        if (r.trim().isNotEmpty) {
          branches.addAll(await getRemoteBranches(repoPath, r.trim()));
        }
      }
    } else {
      for (final r in remoteNames) {
        branches.addAll(await getRemoteBranches(repoPath, r));
      }
    }
  }

  final chains = await getBranchChains(repoPath, branches, limit: limit);
  final current = await getCurrentBranch(repoPath);

  final logArgs = [
    'log',
  ];
  if (includeLocal) logArgs.add('--branches');
  if (remoteNames != null) {
    if (remoteNames.isEmpty) {
      logArgs.add('--remotes'); // All remotes
    } else {
      for (final r in remoteNames) {
        logArgs.add('--remotes=$r');
      }
    }
  }

  logArgs.addAll([
    '--tags',
    '--decorate=full',
    '--date=iso',
    '--encoding=UTF-8',
    '--pretty=format:%H|%P|%D|%s|%an|%ad',
    '--date-order',
  ]);

  if (limit != null && limit > 0) {
    logArgs.add('--max-count=$limit');
  }
  final lines = await _runGit(logArgs, repoPath);
  final commits = <CommitNode>[];
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    final parts = l.split('|');
    if (parts.length < 6) continue;
    final id = parts[0].toLowerCase();
    final rawParents = parts[1].trim().isEmpty
        ? <String>[]
        : parts[1]
            .trim()
            .split(RegExp(r'\s+'))
            .map((e) => e.toLowerCase())
            .toList();

    final parents = rawParents;
    final dec = parts[2];
    final refs =
        _parseRefs(dec, includeLocal: includeLocal, remoteNames: remoteNames);
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

  final customEdges = await _collectAllEdges(repoPath, commits);

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
  return _withRepoLock(repoPath, () async {
    final repoName = p.basename(repoPath);
    print("repoName=$repoName");
    print("repoPath=$repoPath");
    final tracking = await _readTracking(repoName);
    final docxPath = tracking['docxPath'] as String?;

    await _updateContentDocx(repoPath, docxPath!);
    // 1. Unzip content.docx -> doc_content
    await _flushDocxToContent(repoPath);

    // Add doc_content directory
    await _runGit(['add', kContentDirName], repoPath);
    if (File(p.join(repoPath, 'edges')).existsSync()) {
      await _runGit(['add', 'edges'], repoPath);
    }
    if (File(p.join(repoPath, '.gitignore')).existsSync()) {
      await _runGit(['add', '.gitignore'], repoPath);
      print("Add Gitignore!");
    }
    print("Do You add Gitignore?");
    final safeAuthor = author.trim().isEmpty ? 'Unknown' : author.trim();
    final authorArg = '$safeAuthor <$safeAuthor@gitdocx.local>';
    await _runGit(['commit', '--author=$authorArg', '-m', message], repoPath);
    clearCache();
  });
}

Future<void> createBranch(String repoPath, String branchName) async {
  return _withRepoLock(repoPath, () async {
    await _runGit(['checkout', '-b', branchName], repoPath);
    clearCache();
  });
}

Future<void> switchBranch(String projectName, String branchName) async {
  final repoPath = _projectDir(projectName);
  return _withRepoLock(repoPath, () async {
    await _runGit(['checkout', '-f', branchName], repoPath);
    //await _forceRegenerateRepoDocx(repoPath);

    clearCache();
  });
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
  return _withRepoLock(repoPath, () async {
    final contentDir = Directory(p.join(repoPath, kContentDirName));
    if (!contentDir.existsSync()) {
      throw Exception('No $kContentDirName directory found in repository');
    }

    final tmpDir = await Directory.systemTemp.createTemp('gitdocx_cmp_work_');
    try {
      // If content.docx doesn't exist, create it from doc_content
      await _ensureRepoDocx(repoPath);
      final p2 = p.join(repoPath, kRepoDocxName);

      final pdf = p.join(tmpDir.path, 'diff.pdf');

      final p1 = p.join(tmpDir.path, 'HEAD.docx');
      // HEAD -> p1
      try {
        await _gitArchiveToDocx(repoPath, 'HEAD', p1);
      } catch (e) {
        // If no HEAD, maybe empty? Handle gracefully or throw
        throw Exception('Could not get HEAD content: $e');
      }

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
  });
}

List<String> _parseRefs(String decoration,
    {bool includeLocal = true, List<String>? remoteNames}) {
  final s = decoration.trim();
  if (s.isEmpty) return <String>[];

  // %D format: "HEAD -> refs/heads/master, refs/remotes/origin/master, tag: v1"
  // It does NOT have wrapping parenthesis like %d

  // However, if we were using %d, it would be "(HEAD -> master, origin/master)".
  // We switched to %D.
  // But wait, if I switched to %D, the old parsing logic (expecting parenthesis) might fail if %D doesn't wrap.
  // Git doc says: %D: "ref names without the ' (', ')' wrapping."
  // So I need to remove the parenthesis stripping logic or handle both.
  // Let's handle just the split.

  // Split by comma
  final items = s.split(',');
  final refs = <String>{};

  for (var i in items) {
    var t = i.trim();
    if (t.isEmpty) continue;

    // Handle HEAD -> ...
    if (t.startsWith('HEAD -> ')) {
      t = t.substring(8).trim();
    }

    // Handle tag: ...
    if (t.startsWith('tag: ')) {
      // Tags are usually global, we might want to keep them or filter?
      // Let's keep them as is, or strip 'tag: '?
      // Original logic stripped 'tag: '.
      t = 'refs/tags/${t.substring(5).trim()}';
      // Actually standard ref is refs/tags/...
    }

    // Now t should be a full ref like 'refs/heads/master' or 'refs/remotes/origin/master'
    // But sometimes it might be just 'master' if %D is not fully qualified?
    // %D gives full refs usually?
    // "ref names without the ' (', ')' wrapping."
    // Actually, %D gives "HEAD -> master, origin/master" (short names)?
    // No, %D gives "HEAD -> refs/heads/master, refs/remotes/origin/master" (full names) IS NOT GUARANTEED?
    // Let's verify git documentation.
    // %d: ref names, like the --decorate option of git-log.
    // %D: ref names without the " (", ")" wrapping.
    // --decorate=full vs --decorate=short (default).
    // git log defaults to short decoration.
    // So %D will likely output SHORT names if we don't specify --decorate=full.

    // To be safe, I should use --decorate=full in logArgs?
    // But wait, I can just interpret what I get.
    // If I see 'refs/heads/', it's local.
    // If I see 'refs/remotes/', it's remote.
    // If I see 'origin/...', it's likely remote (short).

    // Let's assume we ADD '--decorate=full' to logArgs to be robust.
    // I will add another Edit to add '--decorate=full'.

    bool isLocal = false;
    bool isRemote = false;
    // bool isTag = false;

    if (t.startsWith('refs/heads/')) {
      isLocal = true;
    } else if (t.startsWith('refs/remotes/')) {
      isRemote = true;
    } else if (t.startsWith('refs/tags/')) {
      // isTag = true;
    } else {
      // Fallback for short names or other refs
      if (t.startsWith('origin/') ||
          (remoteNames != null &&
              remoteNames.any((r) => t.startsWith('$r/')))) {
        isRemote = true;
      } else {
        // Assume local if not remote?
        // Or assume local if it doesn't look like a remote?
        isLocal = true;
      }
    }

    if (isLocal && !includeLocal) continue;
    if (isRemote) {
      // Check if allowed remote
      if (remoteNames == null) {
        // If remoteNames is null (and includeLocal is true/false), what do we do?
        // Usually if includeLocal is true, we might hide remotes?
        // User said: "In displaying local, flagrantly filter out ALL remote branches".
        // So if includeLocal=true (Local View), we DROP isRemote.
        // Wait, 'remoteNames' is null in Local View?
        // In _getGraphUnlocked(includeLocal: true), remoteNames is null.
        // So if remoteNames is null, we DROP remotes?
        // Yes, let's assume if remoteNames is null/empty, we don't want remotes.
        continue;
      }

      // If remoteNames is provided, we check if it matches
      // If remoteNames is empty, it means ALL remotes are allowed
      if (remoteNames.isNotEmpty) {
        bool matches = false;
        for (final r in remoteNames) {
          if (t.startsWith('$r/') || t.contains('/$r/')) {
            matches = true;
            break;
          }
        }
        if (!matches) continue;
      }
    }

    // EXPLICITLY EXCLUDE REMOTE HEAD (e.g. refs/remotes/origin/HEAD)
    // It usually points to the default branch on remote, but in graph view it's noise.
    if (t.endsWith('/HEAD')) continue;

    // Clean up for display
    var clean = t;
    if (clean.startsWith('refs/heads/'))
      clean = clean.substring(11);
    else if (clean.startsWith('refs/remotes/'))
      clean = clean.substring(13);
    else if (clean.startsWith('refs/tags/')) clean = clean.substring(10);

    refs.add(clean);
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

String _getPreviewDir(String name) {
  return p.normalize(p.join(_baseDir(), 'preview', name));
}

// Deprecated: _findRepoDocx (we use kContentDirName now)
// We still need to find external file/dir sometimes

final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
final Map<String, Timer> _debounceTimers = {};
final Map<String, bool> _isUpdating = {};

Future<Uint8List> compareCommits(
    String repoPath, String commit1, String commit2) async {
  return _withRepoLock(repoPath, () async {
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
  });
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
    await gitignore.writeAsString('tracking.json\n*.docx\n');
  }

  // Handle doc content
  if (docxPath != null && docxPath.trim().isNotEmpty) {
    // Just copy/zip to content.docx. NO UNZIP to doc_content.
    await _updateContentDocx(projDir, docxPath);
  } else {
    // Ensure empty content dir exists (so git init works?)
    // Actually git init works fine.
    // We might want an empty content.docx
    await _ensureRepoDocx(projDir);
  }

  final tracking = await _readTracking(name);
  tracking['name'] = name;
  if (docxPath != null && docxPath.trim().isNotEmpty) {
    tracking['docxPath'] = _sanitizeFsPath(docxPath);
  }
  tracking['repoDocxPath'] = p.join(projDir, kContentDirName);

  await _writeTracking(name, tracking);
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
  return _withRepoLock(projDir, () async {
    _isUpdating[name] = true;
    final totalSw = Stopwatch()..start();
    final sectionSw = Stopwatch()..start();
    
    try {
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
        if (FileSystemEntity.isFileSync(sourcePath) ||
            FileSystemEntity.isDirectorySync(sourcePath)) {
          sourceExists = true;
        }
      }

      print('[Perf] Pre-checks & Tracking Read: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

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
      
      print('[Perf] Ensure Content Dir & Write Tracking: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      // Compare Source vs HEAD
      bool restored = false;

      final tmpDir = await Directory.systemTemp.createTemp('git_head_check_');
      try {
        final headDocx = p.join(tmpDir.path, 'HEAD.docx');
        try {
          await _gitArchiveToDocx(projDir, 'HEAD', headDocx);
        } catch (_) {}
        
        print('[Perf] Git Archive HEAD: ${sectionSw.elapsedMilliseconds}ms');
        sectionSw.reset();
      } finally {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      }

      print('restored? $restored');
      if (!restored) {
        // Check if Repo is already identical to Source (e.g. after a rollback)
        bool alreadySynced = false;
        final repoDocx = p.join(projDir, kRepoDocxName);
        if (File(repoDocx).existsSync()) {
          alreadySynced = await _checkDocxIdentical(sourcePath!, repoDocx);
          print("Already synced with repo? $alreadySynced");
          print('[Perf] Check Identical (Source vs Repo): ${sectionSw.elapsedMilliseconds}ms');
          sectionSw.reset();
        }

        if (!alreadySynced) {
          // Update repo content from source
          // Do NOT unzip to doc_content yet. Just update content.docx.
          await _updateContentDocx(projDir, sourcePath!);
          print('[Perf] Update Content Docx: ${sectionSw.elapsedMilliseconds}ms');
          sectionSw.reset();

          // Also force regenerate doc_content (unzip) to make sure working directory matches
          // But wait, if we are going to commit, we need doc_content.
          // And we need to show changes in graph?
          // GitGraph usually shows committed changes.
          // But we have "WorkingState".
          // We need to unzip content.docx -> doc_content so that `git status` shows changes.
          await _flushDocxToContent(projDir);
          print('[Perf] Flush Docx To Content: ${sectionSw.elapsedMilliseconds}ms');
          sectionSw.reset();
        }
      }

      // Check status
      final status = await _runGit(['status', '--porcelain'], projDir);
      if (status.isNotEmpty) {
        print("Git Status dirty: $status");
      }
      final changed = status.isNotEmpty;
      print('[Perf] Git Status: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      String? head;
      try {
        final lines = await _runGit(['rev-parse', 'HEAD'], projDir);
        if (lines.isNotEmpty) head = lines.first.trim();
      } catch (_) {}
      print('[Perf] Get HEAD: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      totalSw.stop();
      print('[Perf] updateTrackingProject Total Time: ${totalSw.elapsedMilliseconds}ms');

      return {
        'repoPath': projDir,
        'workingChanged': changed,
        'head': head,
      };
    } finally {
      await Future.delayed(const Duration(milliseconds: 1000));
      _isUpdating[name] = false;
    }
  });
}

Future<bool> _checkDocxIdentical(
    String externalPath, String compareToDocx) async {
  // compareToDocx is a .docx file (e.g. from HEAD archive)
  // externalPath could be .docx or dir

  final totalSw = Stopwatch()..start();
  final sectionSw = Stopwatch()..start();

  final tmpDir = await Directory.systemTemp.createTemp('ident_check_');
  try {
    String path1 = externalPath;
    String path2 = compareToDocx;

    // If external is dir, zip it
    if (FileSystemEntity.isDirectorySync(externalPath)) {
      final zip1 = p.join(tmpDir.path, 'ext.docx');
      await _zipDir(externalPath, zip1);
      path1 = zip1;
      print('[_checkDocxIdentical_Perf] _checkDocxIdentical Zip Dir: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();
    }

    final f1 = File(path1);
    final f2 = File(path2);
    if (!f1.existsSync() || !f2.existsSync()) return false;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
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

      final b1 = await f1.readAsBytes();
      final b2 = await f2.readAsBytes();
      print('[_checkDocxIdentical_Perf] _checkDocxIdentical Read Files: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      writePart('file1', p.basename(path1), b1);
      writePart('file2', p.basename(path2), b2);
      req.write('--$boundary--\r\n');

      final resp = await req.close().timeout(const Duration(seconds: 30));
      print('[_checkDocxIdentical_Perf] _checkDocxIdentical Request & Response: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      if (resp.statusCode != 200) {
        return false;
      }
      final bodyStr = await utf8.decodeStream(resp);
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      
      totalSw.stop();
      print('[_checkDocxIdentical_Perf] _checkDocxIdentical Total: ${totalSw.elapsedMilliseconds}ms');

      return body['identical'] == true;
    } catch (e) {
      print('Check identical failed (timeout or error): $e');
      return false;
    } finally {
      client.close();
    }
  } catch (e) {
    print('Check identical failed: $e');
    return false;
  } finally {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() async {
  while (true) {
    print('开始比较两个文档...');
    final result1 = await _checkDocxIdentical('1.docx', '2.docx');
    print(result1);
  }
}

Future<Uint8List> previewVersion(String repoPath, String commitId) async {
  return _withRepoLock(repoPath, () async {
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
  });
}

Future<void> resetBranch(String projectName, String commitId) async {
  final repoPath = _projectDir(projectName);
  return _withRepoLock(repoPath, () async {
    await _runGit(['reset', '--hard', commitId], repoPath);
    //await _forceRegenerateRepoDocx(repoPath);
    clearCache();
  });
}

Future<void> rollbackVersion(String projectName, String commitId) async {
  final repoPath = _projectDir(projectName);
  return _withRepoLock(repoPath, () async {
    // Checkout doc_content from commitId to working dir
    // git checkout commitId -- doc_content
    await _runGit(['checkout', commitId, '--', kContentDirName], repoPath);

    // No needs to sync to content.docx
    //await _forceRegenerateRepoDocx(repoPath);

    // Sync to external
    final tracking = await _readTracking(projectName);
    final docxPath = tracking['docxPath'] as String?;

    if (docxPath != null) {
      final localDocx = p.join(repoPath, kRepoDocxName);
      // Ensure we use _writeExternalDocx for robust handling
      if (File(localDocx).existsSync()) {
        await _writeExternalDocx(repoPath, localDocx);
      } else {
        final contentDir = Directory(p.join(repoPath, kContentDirName));
        if (contentDir.existsSync()) {
          await _writeExternalDocx(repoPath, contentDir.path);
        }
      }
    }
  });
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

Future<void> initTrackingService() async {
  final base = Directory(_baseDir());
  if (!base.existsSync()) return;
  final ents = base.listSync().whereType<Directory>().toList();
  for (final d in ents) {
    final name = p.basename(d.path);
    if (name.startsWith('.')) continue;
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
  return _withRepoLock(repoPath, () async {
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

    // Ensure remote is added so fetch --all works
    final remoteName = repoName.toLowerCase();
    await addRemote(repoPath, remoteName, remoteUrl);

    final args = ['push'];
    if (force) args.add('--force');
    args.add(remoteUrl);

    final localBranches = <String>[];
    try {
      final lines = await _runGit(
          ['for-each-ref', '--format=%(refname:short)', 'refs/heads'],
          repoPath);
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
      await _runGit(['fetch', remoteName], repoPath);
    } catch (e) {
      print('Fetch after push failed: $e');
    }

    print('Executing git push with args: $args');
    try {
      output = await _runGit(args, repoPath);
      print('Git push output: ${output.join('\n')}');

      // Automatically setup webhook
      print('hook OK');
      await _ensureWebhook(repoName, owner, token);
    } catch (e) {
      print('Git push failed with error: $e');
      // If push failed, it might be because of non-fast-forward (rejected).
      // Even if the error message is localized (e.g. Chinese), we should check the repo state.
      if (!force) {
        final outStr = output.join('\n');
        if (outStr.contains('Everything up-to-date')) {
          await _checkIfBehind(repoPath, remoteUrl);
        }
      }
    }
  });
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
  final projDir = _projectDir(repoName);
  return _withRepoLock(projDir, () async {
    final remoteName = repoName.toLowerCase();
    // final projDir = _projectDir(repoName); // Already calculated
    final dir = Directory(projDir);
    final gitDir = Directory(p.join(projDir, '.git'));

    final owner = await _resolveRepoOwner(repoName, token);
    final remoteUrl =
        'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

    // Map<String, dynamic>? savedTracking;
    // Map<String, dynamic>? savedTracking;
    bool isFresh = !dir.existsSync() || !gitDir.existsSync();

    if (!isFresh && force) {
      try {
        // savedTracking = await _readTracking(repoName);
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
          final current = await getCurrentBranch(projDir);
          if (current != null) {
            await _runGit(['fetch', remoteUrl, current], projDir);
          } else {
            await _runGit(['fetch', remoteUrl, 'HEAD'], projDir);
          }
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
              'message': 'Local branch is ahead of remote or diverged.'
            };
          }
        } catch (e) {}
      }
      // savedTracking = await _readTracking(repoName);

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
/*
    if (savedTracking != null && savedTracking.isNotEmpty) {
      // Ensure content.docx is up to date (especially if we just cloned or reset)
      await _forceRegenerateRepoDocx(projDir);

      final docxPath = savedTracking['docxPath'] as String?;

      if (docxPath != null) {
        // Sync Repo Content -> External Docx
        final localDocx = p.join(projDir, kRepoDocxName);
        if (File(localDocx).existsSync()) {
            await _writeExternalDocx(projDir, localDocx);
        } else {
          if (File(localDocx).existsSync()) {
            final bytes = await File(localDocx).readAsBytes();
            await File(docxPath).writeAsBytes(bytes);
          } else {
            final contentDir = Directory(p.join(projDir, kContentDirName));
            if (contentDir.existsSync()) {
              await _zipDir(contentDir.path, docxPath);
            }
          }
        }
      }
    }
*/
    clearCache();
    return {
      'status': 'success',
      'path': projDir,
      'isFresh': isFresh,
    };
  });
}

Future<Map<String, dynamic>> checkPullStatus(
    String repoName, String username, String token) async {
  final projDir = _projectDir(repoName);
  return _withRepoLock(projDir, () async {
    final remoteName = repoName.toLowerCase();
    final owner = await _resolveRepoOwner(repoName, token);
    final remoteUrl =
        'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

    try {
      await addRemote(projDir, remoteName, remoteUrl);
      await _runGit(['fetch', remoteName], projDir);

      final current = await getCurrentBranch(projDir);
      if (current == null)
        return {'status': 'error', 'message': 'No current branch'};

      final remoteBranch = '$remoteName/$current';

      // Check if remote branch exists
      try {
        await _runGit(['rev-parse', '--verify', remoteBranch], projDir);
      } catch (_) {
        // Remote branch doesn't exist?
        return {'status': 'no_remote_branch'};
      }

      // Check behind/ahead count
      final out = await _runGit(
          ['rev-list', '--left-right', '--count', '$current...$remoteBranch'],
          projDir);

      if (out.isEmpty)
        return {'status': 'error', 'message': 'Failed to check status'};

      final parts = out.first.trim().split(RegExp(r'\s+'));
      if (parts.length < 2)
        return {'status': 'error', 'message': 'Invalid rev-list output'};

      final ahead = int.tryParse(parts[0]) ?? 0;
      final behind = int.tryParse(parts[1]) ?? 0;

      if (behind > 0 && ahead > 0)
        return {'status': 'diverged', 'behind': behind, 'ahead': ahead};
      if (behind > 0) return {'status': 'behind', 'behind': behind};
      if (ahead > 0) return {'status': 'ahead', 'ahead': ahead};
      return {'status': 'up-to-date'};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  });
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

Future<String?> findProjectByDocxPath(String docxPath) async {
  print('DEBUG: Searching project for docx: $docxPath');
  final projects = await listProjects();
  for (final name in projects) {
    try {
      final tracking = await _readTracking(name);
      final trackedPath = tracking['docxPath'] as String?;
      if (trackedPath != null) {
        final normTracked = p.normalize(trackedPath).toLowerCase();
        final normDocx = p.normalize(docxPath).toLowerCase();
        // print('DEBUG: Checking $name: $normTracked vs $normDocx');

        // Normalize paths for comparison (manual lower case to be sure)
        if (normTracked == normDocx || p.equals(trackedPath, docxPath)) {
          print('DEBUG: Match found: $name');
          return name;
        }
      }
    } catch (_) {}
  }
  print('DEBUG: No project matched for $docxPath');
  return null;
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
    //await _forceRegenerateRepoDocx(projDir);
  } catch (e) {
    try {
      await _runGit(['rebase', '--abort'], projDir);
    } catch (_) {}
    throw Exception('Rebase failed (likely conflicts): $e');
  }
  clearCache();
}

Future<void> cancelPull(String repoName) async {
  // No-op for main repo since we use preview copy
  // We keep the cache for future previews
}

Future<PullPreviewResult> previewPull(
    String repoName, String username, String token, String type) async {
  final projDir = _projectDir(repoName);
  // Lock projDir to ensure consistent snapshot for copy
  return _withRepoLock(projDir, () async {
    final previewDir = _getPreviewDir(repoName);
    final cacheKey = '$repoName|$type';
    final cachedResult = _previewCache[cacheKey];

    if (cachedResult != null) {
      print('Preview cache hit for $cacheKey');
      return cachedResult;
    }

    // Prepare Preview Directory
    final pd = Directory(previewDir);
    if (pd.existsSync()) {
      try {
        pd.deleteSync(recursive: true);
      } catch (e) {
        print("Failed to delete preview dir: $e");
        // Try to proceed, maybe it's fine
      }
    }
    pd.createSync(recursive: true);

    // Copy projDir to previewDir
    await _copyDir(projDir, previewDir);

    // From now on, operate on previewDir
    final remoteName = repoName.toLowerCase();
    final owner = await _resolveRepoOwner(repoName, token);
    final remoteUrl =
        'http://$username:$token@47.242.109.145:3000/$owner/$repoName.git';

    // Ensure remote exists in preview repo
    await addRemote(previewDir, remoteName, remoteUrl);

    try {
      await _runGit(['fetch', remoteName], previewDir);
    } catch (e) {
      print('Fetch failed during preview: $e');
      throw Exception('Failed to fetch from remote: $e');
    }

    // 2. Get Current Graph (from Preview Repo, which is a copy of Local)
    final currentGraph =
        await _getGraphUnlocked(previewDir, includeLocal: true);

    // 3. Get Target Graph
    String? targetBranchName;
    final currentBranch = await getCurrentBranch(previewDir);
    if (currentBranch != null) {
      targetBranchName = '$remoteName/$currentBranch';
    }

    final targetGraph = await _getGraphUnlocked(previewDir,
        includeLocal: false, remoteNames: [remoteName]);

    final finalTargetGraph = GraphResponse(
      commits: targetGraph.commits,
      branches: targetGraph.branches,
      chains: targetGraph.chains,
      currentBranch: targetBranchName ?? targetGraph.currentBranch,
      customEdges: targetGraph.customEdges,
    );

    GraphResponse? resultGraph;
    bool hasConflicts = false;
    List<String> conflictingFiles = [];

    if (type == 'rebase') {
      if (currentBranch == null) throw Exception('Detached HEAD');

      // Direct rebase on current branch in PREVIEW DIR
      try {
        await _runGit(['rebase', '-X', 'theirs', '$remoteName/$currentBranch'],
            previewDir);
        await _forceRegenerateRepoDocx(previewDir);
      } catch (e) {
        // Check for conflicts
        final status = await _runGit(['status', '--porcelain'], previewDir);
        if (status.any((l) => l.startsWith('UU') || l.startsWith('AA'))) {
          hasConflicts = true;
          conflictingFiles = status
              .where((l) => l.startsWith('UU') || l.startsWith('AA'))
              .map((l) => l.substring(3).trim())
              .toList();
        }
      }

      // Get Result Graph
      resultGraph = await _getGraphUnlocked(previewDir,
          includeLocal: true, remoteNames: []);
    } else if (type == 'branch' || type == 'fork') {
      if (currentBranch == null) throw Exception('Detached HEAD');

      // FORK/BRANCH Preview Logic:
      try {
        await _runGit(
            ['branch', '-f', 'PreviewFork', '$remoteName/$currentBranch'],
            previewDir);
        await _runGit(['checkout', 'PreviewFork'], previewDir);
        await _forceRegenerateRepoDocx(previewDir);
      } catch (e) {
        throw Exception('Failed to create/checkout PreviewFork branch: $e');
      }

      resultGraph = await _getGraphUnlocked(previewDir,
          includeLocal: true, remoteNames: []);
    }

    // Fix for Rebase Preview (Label cleanup)
    if (type == 'rebase' && currentBranch != null && resultGraph != null) {
      for (final c in resultGraph.commits) {
        c.refs.remove(currentBranch);
        c.refs.remove('refs/heads/$currentBranch');
      }
    }

    final result = PullPreviewResult(
      current: currentGraph,
      target: finalTargetGraph,
      result: resultGraph,
      rowMapping: {},
      hasConflicts: hasConflicts,
      conflictingFiles: conflictingFiles,
    );

    _previewCache[cacheKey] = result;

    return result;
  });
}

// Map<String, int> _computeUnifiedMapping(List<GraphResponse> graphs) {
// ...
// }

Future<void> forkLocal(String repoName, String newBranchName) async {
  final repoPath = _projectDir(repoName);
  return _withRepoLock(repoPath, () async {
    final currentBranch = await getCurrentBranch(repoPath);
    final remoteName = repoName.toLowerCase();

    // FORK/BRANCH Execution Logic:
    // 1. Cleanup any stale PreviewFork branch
    try {
      await _runGit(['branch', '-D', 'PreviewFork'], repoPath);
    } catch (_) {}

    // 2. Create and checkout new branch from remote
    // This creates 'newBranchName' pointing to 'remote/currentBranch' and switches to it.
    // The original local branch is left untouched.
    if (currentBranch != null) {
      await _runGit(
          ['checkout', '-b', newBranchName, '$remoteName/$currentBranch'],
          repoPath);
      // Force regenerate docx to match the new branch content (which is remote content)
      await _forceRegenerateRepoDocx(repoPath);
    } else {
      // Fallback if no current branch (unlikely in this flow)
      await _runGit(['checkout', '-b', newBranchName], repoPath);
    }

    clearCache();
  });
}

Future<void> prepareMerge(String repoName, String targetBranch) async {
  final projDir = _projectDir(repoName);
  return _withRepoLock(projDir, () async {
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
      final psScript =
          r'c:\Users\m1369\Documents\gitbin\frontend\lib\doccmp.ps1';

      final pRes = await Process.run('powershell', [
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        psScript,
        '-OriginalPath',
        headDocx,
        '-RevisedPath',
        targetDocx,
        '-PdfPath',
        diffDocx,
        '-IsDocx'
      ]);

      if (pRes.exitCode != 0 || !File(diffDocx).existsSync()) {
        throw Exception('Merge comparison failed');
      }

      // 4. Update External (docxPath)
      // No backup creation (handled by git restore if needed)

      if (FileSystemEntity.isDirectorySync(docxPath)) {
        // Unzip diffDocx to docxPath
        // Clean target?
        // Directory(docxPath).deleteSync(recursive: true);
        // Directory(docxPath).createSync();
        // await _unzipDocx(diffDocx, docxPath);

        // Use _writeExternalDocx for consistency (it handles dir unzipping too)
        await _writeExternalDocx(projDir, diffDocx);
      } else {
        // Overwrite file
        await _writeExternalDocx(projDir, diffDocx);
      }
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}

Future<void> restoreDocx(String repoName) async {
  final projDir = _projectDir(repoName);
  await _ensureRepoDocx(projDir);
  final sourcePath = p.join(projDir, kRepoDocxName);
  print(sourcePath);
  // Restore using _writeExternalDocx which handles Plugin API and file overwrite
  await _writeExternalDocx(projDir, sourcePath);
}

Future<void> completeMerge(String repoName, String targetBranch) async {
  final projDir = _projectDir(repoName);
  return _withRepoLock(projDir, () async {
    // 1. Sync External -> Repo Content
    final tracking = await _readTracking(repoName);
    final docxPath = tracking['docxPath'] as String?;
    if (docxPath != null) {
      // Sync to content.docx & doc_content
      await _updateContentDocx(projDir, docxPath);
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

    // 3. Flush content.docx to doc_content so git sees the changes from user resolution
    if (docxPath != null) {
      await _flushDocxToContent(projDir);
    }

    // Handle edges
    final edgesFile = File(p.join(projDir, 'edges'));
    List<String>? targetEdges;
    try {
      final out = await _runGit(['show', '$targetBranch:edges'], projDir);
      targetEdges = out;
    } catch (_) {}

    if (edgesFile.existsSync() &&
        targetEdges != null &&
        targetEdges.isNotEmpty) {
      final current = await edgesFile.readAsLines();
      if (current.isNotEmpty) current.removeAt(0);
      if (targetEdges.isNotEmpty) targetEdges.removeAt(0);
      final merged = {...current, ...targetEdges};
      await edgesFile.writeAsString(
          '0000000000000000000000000000000000000000\n${merged.join('\n')}');
    } else if (!edgesFile.existsSync() && targetEdges != null) {
      await edgesFile.writeAsString(targetEdges.join('\n'));
    }

    final targetHashLines = await _runGit(['rev-parse', targetBranch], projDir);
    final targetHash =
        targetHashLines.isNotEmpty ? targetHashLines.first.trim() : null;
    if (targetHash != null && oldHead != null) {
      final lines =
          edgesFile.existsSync() ? await edgesFile.readAsLines() : <String>[];
      if (lines.isEmpty) lines.add('0000000000000000000000000000000000000000');
      final edgeLine = '$oldHead $targetHash';
      if (!lines.contains(edgeLine)) {
        lines.add(edgeLine);
        await edgesFile.writeAsString(lines.join('\n'));
      }
    }

    await _runGit(['add', '.'], projDir);
    await _runGit(
        ['commit', '-m', 'Merge branch \'$targetBranch\' into HEAD'], projDir);
    clearCache();
  });
}

Future<List<String>> findIdenticalCommit(String name) async {
  final projDir = _projectDir(name);
  final tracking = await _readTracking(name);
  // We assume repo has doc_content

  final log = await _runGit(['log', '--all', '--format=%H'], projDir);
  final commitIds =
      log.where((l) => l.trim().isNotEmpty).map((l) => l.trim()).toList();

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
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }
  return identicals;
}

Future<void> _ensureWebhook(String repoName, String owner, String token) async {
  final giteaUrl = 'http://47.242.109.145:3000/';
  final targetUrl = 'http://47.242.109.145:4829/webhook';
  final headers = {
    'Authorization': 'token $token',
    'Content-Type': 'application/json',
  };

  try {
    // 1. List existing hooks
    final listResp = await http.get(
      Uri.parse('$giteaUrl/api/v1/repos/$owner/$repoName/hooks'),
      headers: headers,
    );

    if (listResp.statusCode == 200) {
      final List<dynamic> hooks = jsonDecode(listResp.body);
      for (final hook in hooks) {
        final config = hook['config'];
        if (config != null && config['url'] == targetUrl) {
          print('Webhook already exists for $repoName');
          return;
        }
      }
    } else {
      print('Failed to list webhooks: ${listResp.statusCode} ${listResp.body}');
    }

    // 2. Create hook
    print('Creating webhook for $repoName...');
    final createResp = await http.post(
      Uri.parse('$giteaUrl/api/v1/repos/$owner/$repoName/hooks'),
      headers: headers,
      body: jsonEncode({
        'type': 'gitea',
        'config': {
          'content_type': 'json',
          'url': targetUrl,
          'http_method': 'post',
        },
        'events': ['push'],
        'active': true,
      }),
    );

    if (createResp.statusCode == 201) {
      print('Webhook created successfully for $repoName');
    } else {
      print(
          'Failed to create webhook: ${createResp.statusCode} ${createResp.body}');
    }
  } catch (e) {
    print('Error setting up webhook: $e');
  }
}
