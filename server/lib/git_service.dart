import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'ai_diff_service.dart';  // 🔥 新增：AI 对比服务

import 'package:crypto/crypto.dart';

bool _debugMode = false;
void setDebugMode(bool value) => _debugMode = value;
final scriptDir = p.dirname(Platform.script.toFilePath());
Set<String> workingIds = {};
String get _psScriptPath {
  final candidates = <String>[
    if (_debugMode) r'c:\Users\m1369\Documents\gitbin\frontend\lib\doccmp.ps1',
    p.join(scriptDir, 'doccmp.ps1'),
    p.normalize(p.join(scriptDir, '..', '..', 'frontend', 'bin', 'doccmp.ps1')),
    p.normalize(p.join(scriptDir, '..', '..', 'frontend', 'lib', 'doccmp.ps1')),
    p.join(Directory.current.path, 'frontend', 'bin', 'doccmp.ps1'),
    p.join(Directory.current.path, 'frontend', 'lib', 'doccmp.ps1'),
  ];

  for (final candidate in candidates) {
    if (candidate.trim().isEmpty) continue;
    if (File(candidate).existsSync()) return candidate;
  }
  return candidates.first;
}

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

class Semaphore {
  final int max;
  int _current = 0;
  final List<Completer<void>> _waiters = [];

  Semaphore(this.max);

  Future<void> acquire() async {
    if (_current < max) {
      _current++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _current--;
    }
  }
}

final _previewSemaphore = Semaphore(20);
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
const String kTrackingExt = '.tracking.zip';
const String kWorkspaceMetaFile = '.tracking_workspace.json';

String _trackingBaseName(String path) {
  final base = p.basename(path);
  final lower = base.toLowerCase();
  if (lower.endsWith(kTrackingExt)) {
    return base.substring(0, base.length - kTrackingExt.length);
  }
  return p.basenameWithoutExtension(base);
}

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
    } catch (e, s) {
      print('Error deleting docx in _forceRegenerateRepoDocx: $e\n$s');
    }
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
  final info = await _resolveTrackingInfo(repoPath);
  final targetPath = info['docxPath'] as String?;

  if (targetPath == null) return;

  bool diskWriteSuccess = false;
  Object? diskError;

  // 1. Try disk write first
  print('Updating external docx via disk write: $targetPath');
  try {
    if (FileSystemEntity.isDirectorySync(targetPath)) {
      if (FileSystemEntity.isDirectorySync(sourcePath)) {
        await _copyDir(sourcePath, targetPath);
      } else {
        // Unzip source file to target dir
        if (Directory(targetPath).existsSync()) {
          Directory(targetPath).deleteSync(recursive: true);
        }
        Directory(targetPath).createSync();
        await _unzipDocx(sourcePath, targetPath);
      }
    } else {
      if (FileSystemEntity.isDirectorySync(sourcePath)) {
        // Zip source dir to target file
        await _zipDir(sourcePath, targetPath);
      } else {
        // Safer copy: read bytes and write bytes to avoid 183
        // File(sourcePath).copySync(targetPath);
        final bytes = File(sourcePath).readAsBytesSync();
        File(targetPath).writeAsBytesSync(bytes, flush: true);
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
          'options': {'checkPath': targetPath}
        }
      });

      if (result == true) {
        handled = true;
        print('Updated external docx via plugin: $targetPath');
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
  // 使用 archive 包解压，不再依赖 PowerShell
  final bytes = await File(docxPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);

  for (final file in archive) {
    final filename = file.name;
    if (file.isFile) {
      final data = file.content as List<int>;
      final outFile = File(p.join(destDir, filename));
      await outFile.create(recursive: true);
      await outFile.writeAsBytes(data);
    } else {
      await Directory(p.join(destDir, filename)).create(recursive: true);
    }
  }
}

Future<void> _zipDir(String srcDir, String docxPath) async {
  // 使用 archive 包压缩
  final encoder = ZipFileEncoder();
  encoder.create(docxPath);
  
  final dir = Directory(srcDir);
  if (!dir.existsSync()) {
    throw Exception('Source directory not found: $srcDir');
  }

  final entities = dir.listSync(recursive: true);
  for (final entity in entities) {
    if (entity is File) {
      final relPath = p.relative(entity.path, from: srcDir);
      // 使用 relPath 作为 zip 内的文件名，确保不包含源目录名作为前缀
      await encoder.addFile(entity, relPath);
    }
  }
  
  encoder.close();
}

Future<void> _copyDir(String src, String dst) async {
  // Use PowerShell to copy directory contents
  // Copy-Item -Path "src\*" -Destination "dst" -Recurse -Force
  // Ensure dst exists
  if (!Directory(dst).existsSync()) {
    Directory(dst).createSync(recursive: true);
  }

  final cmd =
      "Get-ChildItem -Path '$src' -Force | Copy-Item -Destination '$dst' -Recurse -Force";
  final res = await Process.run('powershell', ['-Command', cmd]);
  if (res.exitCode != 0) {
    throw Exception('Failed to copy dir: ${res.stderr}');
  }
}

Future<void> _gitArchiveToDocx(
    String repoPath, String commitId, String outDocxPath) async {
  // ⚠️ 重要：使用 git archive --format=tar 提取，然后用 archive 包转为 zip (docx)
  // 避免使用 PowerShell Compress-Archive 导致的损坏问题

  final tmpDir = Directory.systemTemp.createTempSync('git_archive_${commitId}_');
  try {
    final tarPath = p.join(tmpDir.path, 'content.tar');
    final res = await Process.run(
      'git',
      [
        'archive',
        '--format=tar',
        '--output=$tarPath',
        '$commitId:$kContentDirName'
      ],
      workingDirectory: repoPath,
    );

    if (res.exitCode != 0) {
      final stderr = res.stderr is String ? res.stderr as String : utf8.decode(res.stderr as List<int>);
      throw Exception('Failed to git archive to tar: $stderr');
    }

    // 使用 archive 包解码 tar
    final tarBytes = await File(tarPath).readAsBytes();
    final archive = TarDecoder().decodeBytes(tarBytes);

    // 重新编码为 Zip (docx)
    final zipEncoder = ZipEncoder();
    final zipBytes = zipEncoder.encode(archive);
    if (zipBytes == null) {
        throw Exception('Failed to encode zip data');
    }
    
    await File(outDocxPath).writeAsBytes(zipBytes);

  } finally {
    try {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    } catch (e, s) {
      print('Error cleaning up tmpDir in _gitArchiveToDocx: $e\n$s');
    }
  }
}

// ------------------------------------------

Future<void> fetchAll(String repoPath) async {
  return _withRepoLock(repoPath, () async {
    await _runGit(['fetch', '--all'], repoPath);
  });
}

Future<List<String>> _runGit(List<String> args, String repoPath,
    {bool throwOnError = true, bool printError = true}) async {
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
      environment: {'GIT_TERMINAL_PROMPT': '0'}, // Prevent interactive prompts
    );
    if (res.exitCode != 0) {
      if (printError) {
        print("git error (exitCode=${res.exitCode}) args=$args");
        print(res.stderr);
        print(res.stdout);
      }
      if (throwOnError) {
        throw Exception(res.stderr is String ? res.stderr : 'git error');
      }
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
      environment: {'GIT_TERMINAL_PROMPT': '0'},
    );
    if (res.exitCode != 0) {
      if (printError) print("git error fallback");
      if (throwOnError) {
        throw Exception(res.stderr is String ? res.stderr : 'git error');
      }
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
  } catch (e, s) {
    print('Error in getCurrentBranch: $e\n$s');
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
  } catch (e, s) {
    print('Error reading local edges file: $e\n$s');
  }

  // 2. Try to read from each commit
  Future<void> fetch(CommitNode c) async {
    try {
      final res = await Process.run(
        'git',
        ['show', '${c.id}:edges'],
        workingDirectory: repoPath,
        stdoutEncoding: utf8,
      );
      if (res.exitCode == 0) {
        parseContent(res.stdout.toString());
      }
    } catch (e, s) {
      print('Error fetching edges from commit ${c.id}: $e\n$s');
    }
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
  // Check if it's a folder project. If so, do not return graph (or return empty).
  // Because we only want to load graph for leaf nodes (DocxRepo).
  if (await _isFolderProject(repoPath)) {
    print('Skipping graph for folder project: $repoPath');
    return GraphResponse(
        commits: [],
        branches: [],
        chains: {},
        currentBranch: await getCurrentBranch(repoPath),
        customEdges: []);
  }

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

Future<bool> _isFolderProject(String repoPath) async {
  // Check if it is a folder project (has .gitmodules)
  // We prefer .gitmodules over legacy folder_meta.json
  if (File(p.join(repoPath, '.gitmodules')).existsSync()) {
    return true;
  }
  
  // Legacy check (deprecated, but keep for now until fully migrated)
  // if (File(p.join(repoPath, 'folder_meta.json')).existsSync()) {
  //   return true;
  // }
  // If it has content.docx or doc_content, it is a leaf (document) project
  if (File(p.join(repoPath, kRepoDocxName)).existsSync()) return false;
  if (Directory(p.join(repoPath, kContentDirName)).existsSync()) return false;

  // If it has neither, assume it's a folder project (e.g. empty root)
  // unless it ends with .tracking.zip which we treat as container
  if (p.basename(repoPath).toLowerCase().endsWith(kTrackingExt)) {
      return true;
  }
  
  // Fallback: Check if it's inside another git repo? 
  // But for now, lack of content implies folder.
  return true;
}

Future<void> pushRepo(String repoPath) async {
  return _withRepoLock(repoPath, () async {
    print('[Push] Pushing $repoPath');
    await _runGit(['push'], repoPath);
    
    // Auto-push parent if this is a sub-repo
    if (!await _isFolderProject(repoPath)) {
        final rootPath = await _findWorkspaceRoot(repoPath);
        if (rootPath != null && p.normalize(rootPath) != p.normalize(repoPath)) {
             print('[AutoPush] Pushing parent: $rootPath');
             try {
                 await _runGit(['push'], rootPath);
             } catch (e) {
                 print('[AutoPush] Parent push failed: $e');
             }
        }
    }
  });
}

Future<void> pullRepo(String repoPath) async {
    return _withRepoLock(repoPath, () async {
        print('[Pull] Pulling $repoPath');
        await _runGit(['pull'], repoPath);
        
        if (await _isFolderProject(repoPath)) {
            print('[Pull] Updating submodules for $repoPath');
            await _runGit(['submodule', 'update', '--init', '--recursive'], repoPath);
        }
    });
}

Future<List<String>> listRemoteRepos(String token) async {
    final url = 'http://47.242.109.145:3000/api/v1/user/repos';
    final headers = {
        'Authorization': 'token $token',
        'Content-Type': 'application/json',
    };
    
    try {
        final resp = await http.get(Uri.parse(url), headers: headers);
        if (resp.statusCode == 200) {
            final List<dynamic> data = jsonDecode(resp.body);
            final List<String> repos = [];
            // MD5 hash is 32 hex characters
            final hashRegex = RegExp(r'^[a-f0-9]{32}$', caseSensitive: false);
            
            for (final repo in data) {
                final name = repo['name'] as String;
                // Filter out hash-named repos (sub-repos)
                if (!hashRegex.hasMatch(name)) {
                    repos.add(repo['clone_url'] as String);
                }
            }
            return repos;
        } else {
            print('Failed to list repos: ${resp.statusCode} ${resp.body}');
        }
    } catch (e) {
        print('Error listing remote repos: $e');
    }
    return [];
}

Future<String> cloneAndPackageProject(String remoteUrl, String savePath) async {
    final tmpDir = await Directory.systemTemp.createTemp('clone_pkg_');
    try {
        print('[Clone] Cloning $remoteUrl to ${tmpDir.path}');
        final res = await Process.run('git', ['clone', '--recursive', remoteUrl, tmpDir.path]);
        if (res.exitCode != 0) {
            throw Exception('Clone failed: ${res.stderr}');
        }
        
        // Pack to .tracking.zip
        print('[Clone] Packing to $savePath');
        await _packTrackingDirectory(tmpDir.path, savePath);
        return savePath;
    } finally {
        try {
            tmpDir.deleteSync(recursive: true);
        } catch (e) {
            print('Error cleaning up tmp clone dir: $e');
        }
    }
}



Future<void> _notifyParentFolderProject(String repoPath) async {
  // Deprecated: No-op
}

Future<void> _expandFolderProject(String repoPath,
    {bool structureOnly = false}) async {
    // Deprecated: No-op
}

Future<bool> _repoHasCommit(String repoPath, String commitId) async {
  try {
    // Check if commit exists in this repo
    await _runGit(['rev-parse', '--verify', '$commitId^{commit}'], repoPath);
    return true;
  } catch (e, s) {
    print('Error checking commit existence: $e\n$s');
    return false;
  }
}

Future<void> _updateParentSubmodule(String subRepoPath, String author, String message) async {
    final rootPath = await _findWorkspaceRoot(subRepoPath);
    // If no parent found, or the parent IS the subRepo (should not happen if logic is correct), return
    if (rootPath == null || p.normalize(rootPath) == p.normalize(subRepoPath)) return;
    
    // Check if rootPath is actually a git repo (it should be)
    if (!Directory(p.join(rootPath, '.git')).existsSync()) return;

    final relPath = p.relative(subRepoPath, from: rootPath).replaceAll(r'\', '/');
    
    print('[AutoUpdateParent] Updating submodule pointer for $relPath in $rootPath');

    try {
        // git add <submodule_path> in root
        await _runGit(['add', relPath], rootPath);
        
        // Check if there are changes to commit
        final status = await _runGit(['status', '--porcelain'], rootPath);
        if (status.isEmpty) {
            print('[AutoUpdateParent] No changes in parent repo.');
            return;
        }

        // git commit in root
        final parentMsg = 'Update submodule $relPath: $message';
        final safeAuthor = author.trim().isEmpty ? 'Unknown' : author.trim();
        final authorArg = '$safeAuthor <$safeAuthor@gitdocx.local>';
        
        await _runGit(['commit', '--author=$authorArg', '-m', parentMsg], rootPath);
        print('[AutoUpdateParent] Parent repo updated.');
    } catch (e) {
        print('[AutoUpdateParent] Failed to update parent repo: $e');
        // We do not throw here to avoid failing the child commit if parent update fails
        // But maybe we should warn?
    }
}

Future<void> commitChanges(
    String repoPath, String author, String message) async {
  return _withRepoLock(repoPath, () async {
    print("repoPath=$repoPath");

    final isFolder = await _isFolderProject(repoPath);

    if (isFolder) {
       throw Exception("Operation not allowed: Cannot commit directly to the root (folder) repository. Please commit to a specific document repository.");
    }

    final info = await _resolveTrackingInfo(repoPath);
    final targetPath = info['docxPath'] as String?;

    if (targetPath == null) {
      throw Exception(
          'Missing "docxPath" in tracking.json (or tracking.json not found). Please re-configure the project.');
    }

    if (!FileSystemEntity.isDirectorySync(targetPath) &&
        !FileSystemEntity.isFileSync(targetPath)) {
      throw Exception(
          'File not found: $targetPath. Has the file in the folder been deleted?');
    }

    await _updateContentDocx(repoPath, targetPath);
    // 1. Unzip content.docx -> doc_content
    await _flushDocxToContent(repoPath);

    // Add doc_content directory
    await _runGit(['add', kContentDirName], repoPath);
    
    if (File(p.join(repoPath, 'edges')).existsSync()) {
      await _runGit(['add', 'edges'], repoPath);
    }
    if (File(p.join(repoPath, '.gitignore')).existsSync()) {
      await _runGit(['add', '.gitignore'], repoPath);
    }
    
    final safeAuthor = author.trim().isEmpty ? 'Unknown' : author.trim();
    final authorArg = '$safeAuthor <$safeAuthor@gitdocx.local>';
    await _runGit(['commit', '--author=$authorArg', '-m', message], repoPath);

    final headLines = await _runGit(['rev-parse', 'HEAD'], repoPath);
    final head =
        headLines.isNotEmpty ? headLines.first.trim().toLowerCase() : '';
    if (head.isNotEmpty) {
      unawaited(ensureCommitPreviewAssets(repoPath, head));
    }

    // Auto-update parent repo (submodule pointer)
    await _updateParentSubmodule(repoPath, author, message);

    try {
      await _persistTrackingPackageForRepo(repoPath);
    } catch (e) {
      print('Persist tracking package failed: $e');
    }

    clearCache();
  });
}

Future<void> createBranch(String repoPath, String branchName) async {
  return _withRepoLock(repoPath, () async {
    if (await _isFolderProject(repoPath)) {
        throw Exception("Operation not allowed: Cannot create branches on the root (folder) repository.");
    }
    await _runGit(['checkout', '-b', branchName], repoPath);
    clearCache();
  });
}

Future<void> switchBranch(String projectName, String branchName) async {
  final repoPath = _projectDir(projectName);
  return _withRepoLock(repoPath, () async {
    if (await _isFolderProject(repoPath)) {
        throw Exception("Operation not allowed: Cannot switch branches on the root (folder) repository.");
    }
    
    final sw = Stopwatch()..start();
    await _runGit(['checkout', '-f', branchName], repoPath);
    print(
        '[Perf][GitService][SwitchBranch][Checkout] ${sw.elapsedMilliseconds}ms');
    sw.stop();
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

    // Notify parent folder project if applicable
    await _notifyParentFolderProject(repoPath);
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
    final info = await _resolveTrackingInfo(repoPath);
    final targetPath = info['docxPath'] as String?;

    if (targetPath == null) {
      throw Exception(
          'Missing "docxPath" in tracking.json. Please re-configure the project.');
    }

    if (!FileSystemEntity.isDirectorySync(targetPath) &&
        !FileSystemEntity.isFileSync(targetPath)) {
      throw Exception(
          'File not found: $targetPath. Has the file in the folder been deleted?');
    }

    await _updateContentDocx(repoPath, targetPath); //保证外部更新内部。

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

      final ps1Path = _psScriptPath;

      final res = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
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
          ],
          workingDirectory: p.dirname(ps1Path));

      final pdfFile = File(pdf);
      if (!pdfFile.existsSync()) {
        final until = DateTime.now().add(const Duration(seconds: 2));
        while (DateTime.now().isBefore(until)) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (pdfFile.existsSync()) break;
        }
      }

      final pdfExists = pdfFile.existsSync();
      final pdfLen = pdfExists ? pdfFile.lengthSync() : 0;
      if (!pdfExists || pdfLen <= 0) {
        throw Exception(
            'Compare failed (exitCode=${res.exitCode}, pdfExists=$pdfExists, pdfLen=$pdfLen, cwd=${Directory.current.path}, ps1=$ps1Path): ${res.stdout}\n${res.stderr}');
      }

      if (res.exitCode != 0) {
        print(
            '[doccmp] warning: powershell exitCode=${res.exitCode} but pdf exists ($pdfLen bytes).');
      }

      return await File(pdf).readAsBytes();
    } catch (e) {
      print('Debug: Temporary directory kept at: ${tmpDir.path} due to error: $e');
      print('Debug: Please check 1.docx and 2.docx in ${tmpDir.path} if available.');
      rethrow;
    } finally {
      // Only delete if no error (or we can implement a flag to keep it)
      // For now, if we rethrew in catch, finally still runs.
      // So we need to check if we want to delete.
      // But we can't easily know if we are in error state inside finally block without a variable.
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

String _workspaceBaseDir() {
  final app = Platform.environment['APPDATA'];
  if (app != null && app.isNotEmpty) return p.join(app, 'tracking_workspace');
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) return p.join(home, '.tracking_workspace');
  return p.join(Directory.systemTemp.path, 'tracking_workspace');
}

String _packageKey(String packagePath) {
  final norm = p.normalize(packagePath).toLowerCase();
  return md5.convert(utf8.encode(norm)).toString();
}

String _workspaceDirForPackage(String packagePath) {
  return p.join(_workspaceBaseDir(), _packageKey(packagePath));
}

Future<void> _writeWorkspaceMeta(
    String workspaceDir, String packagePath) async {
  final f = File(p.join(workspaceDir, kWorkspaceMetaFile));
  await f.writeAsString(jsonEncode({'packagePath': packagePath}));
}

Future<String?> _readWorkspacePackagePath(String workspaceDir) async {
  final f = File(p.join(workspaceDir, kWorkspaceMetaFile));
  if (!f.existsSync()) return null;
  try {
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return j['packagePath'] as String?;
  } catch (e, s) {
    print('Error reading workspace package path: $e\n$s');
    return null;
  }
}

Future<String?> _findWorkspaceRoot(String repoPath) async {
  String current = p.normalize(repoPath);
  final root = p.rootPrefix(current);
  while (true) {
    final metaFile = File(p.join(current, "folder_meta.json"));//让他包含的是folder_meta而不是workspace最基础的json文件
    if (metaFile.existsSync()) return current;
    final parent = p.dirname(current);
    if (parent == current || parent == root) break;
    current = parent;
  }
  return null;
}

Future<void> _persistTrackingPackageForRepo(String repoPath) async {
  final root = await _findWorkspaceRoot(repoPath);
  if (root == null) return;
  final packagePath = await _readWorkspacePackagePath(root);
  if (packagePath == null || packagePath.isEmpty) return;
  await _exportFolderToTrackingPackage(root, packagePath);
}

List<int> _archiveContentBytes(ArchiveFile file) {
  final content = file.content;
  if (content is List<int>) return content;
  if (content is InputStream) return content.toUint8List();
  return const <int>[];
}

Future<void> _extractTrackingPackage(String packagePath, String outDir) async {
  final f = File(packagePath);
  if (!f.existsSync()) {
    throw Exception('Tracking package not found: $packagePath');
  }
  final bytes = await f.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive) {
    final filename = p.normalize(p.join(outDir, file.name));
    if (file.isFile) {
      final outFile = File(filename);
      outFile.parent.createSync(recursive: true);
      final bytes = _archiveContentBytes(file);
      if (bytes.isEmpty) {
        print('Tracking package entry has null content: ${file.name}');
      }
      outFile.writeAsBytesSync(bytes);
    } else {
      Directory(filename).createSync(recursive: true);
    }
  }
  // await _expandTrackingEntries(outDir); // Removed eager expansion for step-by-step
}

Future<Map<String, dynamic>> expandLocalTrackingPackage(String filePath) async {
  final dir = Directory(filePath);
  if (dir.existsSync()) {
    // Already expanded, check content type
    bool hasTracking = dir.listSync().any((e) => e.path.toLowerCase().endsWith(kTrackingExt));
    bool hasGit = Directory(p.join(dir.path, '.git')).existsSync();
    return {
      'path': filePath,
      'type': hasTracking ? 'folder' : (hasGit ? 'file' : 'folder'),
      'hasSubTracking': hasTracking,
    };
  }

  final file = File(filePath);
  if (!file.existsSync()) {
    throw Exception('File not found: $filePath');
  }
  if (!filePath.toLowerCase().endsWith(kTrackingExt)) {
    throw Exception('Not a tracking package: $filePath');
  }

  final targetDir = filePath; // Expand in-place (replace file with dir)
  final tmp = await Directory.systemTemp.createTemp('tracking_expand_');
  try {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final item in archive) {
      final filename = p.normalize(p.join(tmp.path, item.name));
      if (item.isFile) {
        final outFile = File(filename);
        outFile.parent.createSync(recursive: true);
        final bytes = _archiveContentBytes(item);
        outFile.writeAsBytesSync(bytes);
      } else {
        Directory(filename).createSync(recursive: true);
      }
    }

    try {
      file.deleteSync();
    } catch (e) {
      throw Exception('Failed to delete original file: $e');
    }

    final dir = Directory(targetDir);
    if (dir.existsSync()) {
       // Should not happen if we just deleted the file with same name? 
       // Windows: File and Dir with same name? 
       // If file deleted, path is free.
    }
    dir.createSync(recursive: true);
    await _copyDir(tmp.path, dir.path);
    
    // Check type of expanded content
    bool hasTracking = dir.listSync().any((e) => e.path.toLowerCase().endsWith(kTrackingExt));
    bool hasGit = Directory(p.join(dir.path, '.git')).existsSync();
    
    return {
      'path': targetDir,
      'type': hasTracking ? 'folder' : (hasGit ? 'file' : 'folder'), // Default to folder if unknown?
      'hasSubTracking': hasTracking,
    };
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (e, s) {
      print('Error cleaning up tmp dir in expandLocalTrackingPackage: $e\n$s');
    }
  }
}


Future<void> saveTrackingProject(String currentPackagePath, [String? newPackagePath]) async {
  print('[saveTrackingProject] Start: current=$currentPackagePath, new=$newPackagePath');
  final normalizedCurrent = _sanitizeFsPath(currentPackagePath);
  final workspaceDir = _workspaceDirForPackage(normalizedCurrent);
  
  if (!Directory(workspaceDir).existsSync()) {
     print('[saveTrackingProject] Workspace not found at $workspaceDir');
     throw Exception('Workspace not found for package: $currentPackagePath');
  }

  // Ensure folder_meta.json is gone
  final folderMeta = File(p.join(workspaceDir, 'folder_meta.json'));
  if (folderMeta.existsSync()) {
      folderMeta.deleteSync();
  }

  String targetPath = normalizedCurrent;
  if (newPackagePath != null && newPackagePath.trim().isNotEmpty) {
      targetPath = _sanitizeFsPath(newPackagePath);
      
      // Update metadata
      await _writeWorkspaceMeta(workspaceDir, targetPath);
      
      // Pack to new location
      await _exportFolderToTrackingPackage(workspaceDir, targetPath);
      
      // Attempt rename
      final newWorkspaceDir = _workspaceDirForPackage(targetPath);
      if (workspaceDir != newWorkspaceDir) {
          try {
             if (Directory(newWorkspaceDir).existsSync()) {
                 Directory(newWorkspaceDir).deleteSync(recursive: true);
             }
             // Ensure parent exists
             Directory(newWorkspaceDir).parent.createSync(recursive: true);
             Directory(workspaceDir).renameSync(newWorkspaceDir);
             print('[saveTrackingProject] Renamed workspace to $newWorkspaceDir');
          } catch (e) {
             print('[saveTrackingProject] Rename failed: $e');
             // Non-fatal
          }
      }
  } else {
      // Just pack
      await _exportFolderToTrackingPackage(workspaceDir, targetPath);
  }
  print('[saveTrackingProject] Done');
}

Future<void> _packTrackingDirectory(
    String srcDir, String outPackagePath) async {
  
  print('[pack] 开始打包，srcDir=$srcDir, outPackagePath=$outPackagePath');
  final encoder = ZipFileEncoder();
  try {
    encoder.create(outPackagePath);
  } catch (e) {
    print('[pack] ERROR creating zip file: $e');
    throw e;
  }


  final root = Directory(srcDir);
  if (!root.existsSync()) {
    throw Exception('Tracking workspace not found: $srcDir');
  }

  int fileCount = 0;
  int dirCount = 0;

  Future<void> addEntry(String base, FileSystemEntity entity) async {
    // print(entity.path);
    // if (entity.path.endsWith(kWorkspaceMetaFile)) return;
    final rel = p.relative(entity.path, from: base);
    if (entity is File) {
      // print("Add file $entity");
      await encoder.addFile(entity, rel);
      fileCount++;
      if (fileCount % 50 == 0) {
        print('[pack] 已添加 $fileCount 个文件，当前：${entity.path}');
      }
      return;
    }
    if (entity is Directory) {
      // final name = p.basename(entity.path);
      // final entityDir = Directory(entity.path);
      // if (name.toLowerCase().endsWith(kTrackingExt)) {
      //   print('[pack] 递归打包子跟踪目录：${entity.path}');
      //   final tmpFile = File(p.join(Directory.systemTemp.path,
      //       '${DateTime.now().microsecondsSinceEpoch}$kTrackingExt'));
      //   await _packTrackingDirectory(entity.path, tmpFile.path);
      //   await encoder.addFile(tmpFile, rel);
      //   try {
      //     tmpFile.deleteSync();
      //   } catch (_) {}
      //   return;
      // }

      final children = entity.listSync();
      dirCount++;
      for (final child in children) {
        await addEntry(base, child);
      }
    }
  }

  print('[pack] 遍历根目录：$srcDir');
  for (final entity in root.listSync()) {
    // print("[遍历根目录] $entity,$srcDir");
    await addEntry(srcDir, entity);
  }

  encoder.close();
  print('[pack] 打包完成，文件数：$fileCount，目录数：$dirCount，写出到：$outPackagePath');
}

Future<String> _ensureWorkspace(String packagePath) async {
  final normalized = _sanitizeFsPath(packagePath);
  final workspaceDir = _workspaceDirForPackage(normalized);
  final dir = Directory(workspaceDir);

  if (dir.existsSync()) {
    final metaPath = await _readWorkspacePackagePath(workspaceDir);
    if (metaPath != null && p.equals(metaPath, normalized)) {
      return workspaceDir;
    }
    try {
      dir.deleteSync(recursive: true);
    } catch (e) {
      print('Failed to clear workspace: $e');
    }
  }

  dir.createSync(recursive: true);
  await _extractTrackingPackage(normalized, workspaceDir);
  await _writeWorkspaceMeta(workspaceDir, normalized);
  return workspaceDir;
}

Future<void> _exportFolderToTrackingPackage(
    String workspaceDir, String packagePath) async {
  await _packTrackingDirectory(workspaceDir, packagePath);
}

Directory _globalPreviewCacheDir() {
  final app = Platform.environment['APPDATA'];
  if (app != null && app.isNotEmpty) {
    return Directory(p.join(app, 'cache'));
  }
  return Directory(p.join(_baseDir(), 'cache'));
}

String _globalCachedPdfPath(String commitId) {
  return p.join(_globalPreviewCacheDir().path, '$commitId.pdf');
}

String _repoRootDir() {
  final scriptPath = p.fromUri(Platform.script);
  return p.dirname(p.dirname(p.dirname(scriptPath)));
}

String _docx2pdfPs1Path() {
  return p.join(_repoRootDir(), 'frontend', 'lib', 'docx2pdf.ps1');
}

Future<void> _docxToPdf(
    String docxPath, String pdfPath, String commitId) async {
  final psScript = _docx2pdfPs1Path();
  if (!File(psScript).existsSync()) {
    throw Exception('docx2pdf.ps1 not found at $psScript');
  }
  final res = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    psScript,
    '-InputPath',
    docxPath,
    '-OutputPath',
    pdfPath,
  ]);
  if (res.exitCode != 0 || !File(pdfPath).existsSync()) {
    throw Exception('docx->pdf failed: ${res.stderr}');
  }
}

String _doccmpPs1Path() {
  return p.join(_repoRootDir(), 'frontend', 'lib', 'doccmp.ps1');
}

Future<void> _doccmpToPdf(
    String oldDocx, String newDocx, String pdfPath) async {
  final psScript = _doccmpPs1Path();
  if (!File(psScript).existsSync()) {
    throw Exception('doccmp.ps1 not found at $psScript');
  }
  final res = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    psScript,
    '-OriginalPath',
    oldDocx,
    '-RevisedPath',
    newDocx,
    '-PdfPath',
    pdfPath,
  ]);
  if (res.exitCode != 0 || !File(pdfPath).existsSync()) {
    throw Exception('doccmp failed: ${res.stderr}');
  }
}

Future<void> _generatePreviewInternal(
  String repoPath,
  String commitId,
) async {
  final cacheDir = _globalPreviewCacheDir();
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }

  final pdfPath = _globalCachedPdfPath(commitId);
  final pdfFile = File(pdfPath);
  if (pdfFile.existsSync()) {
    return;
  }

  // Determine parent commit
  String parentId = '';
  try {
    // Only lock for git command
    await _withRepoLock(repoPath, () async {
      try {
        final parents = await _runGit(['rev-parse', '$commitId^'], repoPath,
            printError: false);
        if (parents.isNotEmpty && parents.first.trim().isNotEmpty) {
          parentId = parents.first.trim();
        }
      } catch (e) {
        // Ignored: Likely no parent (initial commit)
      }
    });
  } catch (e, s) {
    print('Error finding parent commit in _generatePreviewInternal: $e\n$s');
  }

  final tmpDir = await Directory.systemTemp.createTemp('gitdocx_prev_diff_');
  bool success = false;
  try {
    final currentDocx = p.join(tmpDir.path, '$commitId.docx');

    // 1. Export current docx
    await _withRepoLock(repoPath, () async {
      await _gitArchiveToDocx(repoPath, commitId, currentDocx);
    });

    if (parentId.isEmpty) {
      // Initial commit: just convert to PDF directly using docx2pdf logic (or treat as diff against empty?)
      // For consistency with user request "diff", if no parent, maybe just show the content.
      // But user asked to use doccmp. Let's use docx2pdf for single file if no parent,
      // or we can simulate empty doc.
      // Let's stick to simple conversion for initial commit to avoid complexity.
      if (!pdfFile.existsSync()) {
        final tmpPdfPath = p.join(tmpDir.path, '$commitId.pdf');
        await _docxToPdf(currentDocx, tmpPdfPath, commitId);
        await File(tmpPdfPath).copy(pdfPath);
      }
    } else {
      // Has parent
      final parentDocx = p.join(tmpDir.path, '$parentId.docx');

      // 2. Export parent docx
      await _withRepoLock(repoPath, () async {
        await _gitArchiveToDocx(repoPath, parentId, parentDocx);
      });

      // 3. Compare and generate PDF
      if (!pdfFile.existsSync()) {
        final tmpPdfPath = p.join(tmpDir.path, '$commitId.pdf');
        await _doccmpToPdf(parentDocx, currentDocx, tmpPdfPath);
        await File(tmpPdfPath).copy(pdfPath);
      }
    }
    success = true;
  } catch (e) {
    print('Debug: Temporary directory kept at: ${tmpDir.path} due to error: $e');
    rethrow;
  } finally {
    try {
      if (success && tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    } catch (e, s) {
      print('Error cleaning up tmpDir in _generatePreviewInternal: $e\n$s');
    }
  }
}

Future<Map<String, bool>> ensureCommitPreviewAssets(
  String repoPath,
  String commitId,
) async {
  print(workingIds);

  if (workingIds.contains(commitId)) {
    return {
      'pdf': File(_globalCachedPdfPath(commitId)).existsSync(),
      'thumb': false,
    };
  }

  // Fast check
  if (File(_globalCachedPdfPath(commitId)).existsSync()) {
    return {'pdf': true, 'thumb': false};
  }

  // Mark as working immediately to block other requests
  workingIds.add(commitId);

  try {
    await _previewSemaphore.acquire();
    try {
      // Double check existence (optimization)
      if (File(_globalCachedPdfPath(commitId)).existsSync()) {
        return {'pdf': true, 'thumb': false};
      }

      try {
        await _generatePreviewInternal(repoPath, commitId);
      } catch (e) {
        print('Preview generation failed for $commitId: $e');
      }

      return {
        'pdf': File(_globalCachedPdfPath(commitId)).existsSync(),
        'thumb': false,
      };
    } finally {
      _previewSemaphore.release();
    }
  } finally {
    // Remove from workingIds only after we are completely done (or failed)
    workingIds.remove(commitId);
  }
}

File _trackingFile(String name) {
  final dir = _projectDir(name);
  final rootFile = File(p.join(dir, 'tracking.json'));
  if (rootFile.existsSync()) return rootFile;

  final subName = _trackingBaseName(name);
  if (subName.isNotEmpty && subName != '.') {
    final subFile = File(p.join(dir, subName, 'tracking.json'));
    if (subFile.existsSync()) return subFile;
  }

  return rootFile;
}

Future<Map<String, dynamic>> _readTrackingJson(String jsonPath) async {
  final f = File(jsonPath);
  if (f.existsSync()) {
    try {
      final s = await f.readAsString();
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (e, s) {
      print('Error reading tracking json $jsonPath: $e\n$s');
      return <String, dynamic>{};
    }
  }
  return <String, dynamic>{};
}

Future<Map<String, dynamic>> _resolveTrackingInfo(String repoPath) async {
  String current = p.normalize(repoPath);
  final root = p.rootPrefix(current);

  // 1. Try to find tracking.json recursively
  while (true) {
    final trackingFile = p.join(current, 'tracking.json');
    if (File(trackingFile).existsSync()) {
      final tracking = await _readTrackingJson(trackingFile);
      final baseDocxPath = tracking['docxPath'] as String?;
      final basePackagePath = tracking['packagePath'] as String?;

      if (baseDocxPath != null) {
        String fullDocxPath = baseDocxPath;

        if (p.normalize(current) != p.normalize(repoPath)) {
          // Folder mode: tracking is in parent (current)
          // We are in a sub-repo (repoPath)
          // We need to generate a tracking.json in repoPath

          final relPath = p.relative(repoPath, from: current);
          fullDocxPath = p.join(baseDocxPath, relPath);

          // Create tracking.json in sub-repo
          final subTracking = {
            'docxPath': fullDocxPath,
            if (basePackagePath != null && basePackagePath.isNotEmpty)
              'packagePath': basePackagePath,
            // 'internalPath': relPath, // Optional, but full path is enough
          };
          final f = File(p.join(repoPath, 'tracking.json'));
          await f.writeAsString(jsonEncode(subTracking));

          // Check existence
          if (!FileSystemEntity.isFileSync(fullDocxPath) &&
              !FileSystemEntity.isDirectorySync(fullDocxPath)) {
            // Return info but user will likely hit "File not found" later
            // Or we can throw here?
            // User said: "If docxPath not found... prompt user".
            // If we return, caller (commitChanges) checks existence and throws.
          }

          return {
            'docxPath': fullDocxPath,
            'trackingRoot': repoPath, // Now it has its own tracking
            'rawTracking': subTracking,
            'packagePath': basePackagePath
          };
        } else {
          // Single mode: tracking is in repo dir
          final internalPath = tracking['internalPath'] as String?;
          if (internalPath != null && internalPath.isNotEmpty) {
            fullDocxPath = p.join(baseDocxPath, internalPath);
          }
          return {
            'docxPath': fullDocxPath,
            'trackingRoot': current,
            'rawTracking': tracking,
            'packagePath': basePackagePath
          };
        }
      }
    }

    final parent = p.dirname(current);
    if (parent == current || parent == root) break;
    current = parent;
  }

  // Fallback
  final name = p.basename(repoPath);
  final defaultTracking = await _readTracking(name);
  if (defaultTracking.isNotEmpty && defaultTracking['docxPath'] != null) {
    String fullDocxPath = defaultTracking['docxPath'];
    final internalPath = defaultTracking['internalPath'] as String?;
    if (internalPath != null && internalPath.isNotEmpty) {
      fullDocxPath = p.join(fullDocxPath, internalPath);
    }
    return {
      'docxPath': fullDocxPath,
    };
  }

  return {};
}

Future<Map<String, dynamic>> _readTracking(String name) async {
  final f = _trackingFile(name);
  if (f.existsSync()) {
    try {
      final s = await f.readAsString();
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (e, s) {
      print('Error reading tracking file for $name: $e\n$s');
      return <String, dynamic>{};
    }
  }
  return <String, dynamic>{};
}

Future<Map<String, dynamic>> _readTrackingFromZip(String zipPath) async {
  try {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Check root tracking.json
    ArchiveFile? file = archive.findFile('tracking.json');

    // Check nested
    if (file == null) {
      final subName = _trackingBaseName(zipPath);
      if (subName.isNotEmpty && subName != '.') {
        // Archive paths are usually forward slash
        file = archive.findFile('$subName/tracking.json');
      }
    }

    if (file != null) {
      final content = utf8.decode(file.content as List<int>);
      return jsonDecode(content) as Map<String, dynamic>;
    }
  } catch (e) {
    print('Error reading tracking from zip: $e');
  }
  return {};
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
  final normalized = _sanitizeFsPath(name);
  if (p.isAbsolute(normalized)) {
    if (normalized.toLowerCase().endsWith(kTrackingExt)) {
      final expandedDir = Directory(normalized);
      if (expandedDir.existsSync()) {
        return normalized;
      }
      return _workspaceDirForPackage(normalized);
    }
    return normalized;
  }
  return p.normalize(p.join(_baseDir(), name));
}

String _getPreviewDir(String name) {
  final key = p.isAbsolute(name) ? _packageKey(name) : name;
  return p.normalize(p.join(_baseDir(), 'preview', key));
}

// Deprecated: _findRepoDocx (we use kContentDirName now)
// We still need to find external file/dir sometimes

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
    bool success = false;
    try {
      final p1 = p.join(tmpDir.path, 'old.docx');
      final p2 = p.join(tmpDir.path, 'new.docx');
      final pdf = p.join(tmpDir.path, 'diff.pdf');

      await _gitArchiveToDocx(repoPath, commit1, p1);
      await _gitArchiveToDocx(repoPath, commit2, p2);
      final ps1Path = _psScriptPath;

      if (!File(ps1Path).existsSync()) {
        throw Exception(
            'doccmp.ps1 not found at $ps1Path and _debugMode=$_debugMode');
      }

      final res = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
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
          ],
          workingDirectory: p.dirname(ps1Path));

      final pdfFile = File(pdf);
      if (!pdfFile.existsSync()) {
        final until = DateTime.now().add(const Duration(seconds: 2));
        while (DateTime.now().isBefore(until)) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (pdfFile.existsSync()) break;
        }
      }

      final pdfExists = pdfFile.existsSync();
      final pdfLen = pdfExists ? pdfFile.lengthSync() : 0;
      if (!pdfExists || pdfLen <= 0) {
        throw Exception(
            'Compare failed (exitCode=${res.exitCode}, pdfExists=$pdfExists, pdfLen=$pdfLen, cwd=${Directory.current.path}, ps1=$ps1Path): ${res.stdout}\n${res.stderr}');
      }

      if (res.exitCode != 0) {
        print(
            '[doccmp] warning: powershell exitCode=${res.exitCode} but pdf exists ($pdfLen bytes).');
      }

      await File(pdf).copy(cachePath);
      success = true;
      return await File(pdf).readAsBytes();
    } catch (e) {
      print('Debug: Temporary directory kept at: ${tmpDir.path} due to error: $e');
      rethrow;
    } finally {
      try {
        if (success && tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      } catch (e, s) {
        print('Error cleaning up tmpDir in compareCommits: $e\n$s');
      }
    }
  });
}

// 🔥 新增：AI 语义对比（带缓存）
/// 使用 AI 对比两个 commit 的文档差异
/// 
/// [repoPath] 仓库路径
/// [commit1] 第一个 commit ID
/// [commit2] 第二个 commit ID
/// [docType] 文档类型: word, ppt, excel (默认: word)
/// 
/// 返回: AI 分析结果 (JSON)
Future<Map<String, dynamic>> compareCommitsWithAI(
  String repoPath,
  String commit1,
  String commit2, {
  String docType = 'word',
}) async {
  // 检查 AI 服务是否可用
  final available = await AIDiffService.isAvailable();
  if (!available) {
    throw Exception('AI 服务不可用，请确保 Python API 服务已启动 (端口 8765)');
  }
  
  // 使用锁保护
  return _withRepoLock(repoPath, () async {
    final tmpDir = await Directory.systemTemp.createTemp('ai_cmp_');
    
    try {
      // 确定文件扩展名
      final ext = docType == 'word' ? '.docx' 
                : docType == 'ppt' ? '.pptx' 
                : docType == 'excel' ? '.xlsx'
                : '.docx';
      
      final doc1Path = p.join(tmpDir.path, 'doc1$ext');
      final doc2Path = p.join(tmpDir.path, 'doc2$ext');
      
      print('[AI对比] 提取文档: $commit1 vs $commit2 ($docType)');
      
      // 提取两个 commit 的文档
      await _extractDocFromCommit(repoPath, commit1, doc1Path);
      await _extractDocFromCommit(repoPath, commit2, doc2Path);
      
      // 验证文件存在
      if (!await File(doc1Path).exists()) {
        throw Exception('无法提取文档 (commit: $commit1)');
      }
      if (!await File(doc2Path).exists()) {
        throw Exception('无法提取文档 (commit: $commit2)');
      }
      
      print('[AI对比] 调用 AI 服务...');

      // 调用 AI 服务（自动使用缓存，传递commit ID）
      final result = await AIDiffService.compareDocuments(
        doc1Path,
        doc2Path,
        docType,
        useCache: true,
        useMcp: true,  // ✓ 启用MCP服务
        commitA: commit1,
        commitB: commit2,
      );
      
      print('[AI对比] 分析完成');
      
      return result;
    } catch (e) {
      print('[AI对比] 错误: $e');
      rethrow;
    } finally {
      // 清理临时文件
      try {
        await tmpDir.delete(recursive: true);
      } catch (e) {
        print('Error cleaning up tmpDir in compareCommitsWithAI: $e');
      }
    }
  });
}

/// 从 commit 提取文档文件
/// 
/// [repoPath] 仓库路径
/// [commitId] commit ID
/// [outputPath] 输出文件路径
Future<void> _extractDocFromCommit(
  String repoPath,
  String commitId,
  String outputPath,
) async {
  // 创建临时目录
  final tmpDir = await Directory.systemTemp.createTemp('extract_');
  
  try {
    // ✅ 改用 git archive 命令（和传统PDF对比一样）
    // 这样可以正确处理 doc_content 目录结构
    await _gitArchiveToDocx(repoPath, commitId, outputPath);
    print('[AI对比] 文档提取成功: $outputPath');
  } catch (e) {
    throw Exception('提取文档失败 (commit: $commitId): $e');
  } finally {
    try {
      await tmpDir.delete(recursive: true);
    } catch (e, s) {
      print('Error cleaning up tmpDir in _extractDocFromCommit: $e\n$s');
    }
  }
}

Future<void> _ensureFolderProjectStructure(String projDir, String docxPath,
    {String trackingExt = '',
    String? packagePath}) async {
  // No-op
}

Future<void> _scanAndUpdateFolderMeta(String projDir, String docxPath,
    {String trackingExt = ''}) async {
  // No-op
}

Future<Map<String, dynamic>> createTrackingProject(
    String name, String? docxPath) async {
  print('[createTrackingProject] 开始创建项目，name=$name, docxPath=$docxPath');
  final packagePath = _sanitizeFsPath(name);
  final projDir = _projectDir(packagePath);
  final dir = Directory(projDir);

  if (dir.existsSync()) {
    print('[createTrackingProject] 清理已存在的项目目录: $projDir');
    try {
      dir.deleteSync(recursive: true);
    } catch (e) {
      print('[createTrackingProject] 清理失败: $e');
      throw Exception('Failed to clear tracking workspace: $e');
    }
  }
  dir.createSync(recursive: true);
  print('[createTrackingProject] 项目目录已创建: $projDir');

  await _runGit(['init'], projDir);
  
  await File(p.join(projDir, '.gitignore')).writeAsString('.DS_Store\nThumbs.db\n');
  await _runGit(['add', '.gitignore'], projDir);
  await _runGit(['commit', '-m', 'Initial commit'], projDir);

  if (docxPath != null && docxPath.isNotEmpty) {
      await importTrackingSource(packagePath, '.', docxPath);
  }

  await _writeWorkspaceMeta(projDir, packagePath);

  // Mark as folder project (empty container)
  // if (!File(p.join(projDir, 'folder_meta.json')).existsSync()) {
  //     await File(p.join(projDir, 'folder_meta.json')).writeAsString('{"files":{}, "folders":{}}');
  // }

  if (packagePath.toLowerCase().endsWith(kTrackingExt)) {
    print('[createTrackingProject] 以 .tracking.zip 结尾，打包...');
    await _exportFolderToTrackingPackage(projDir, packagePath);
  }

  return {
    'name': packagePath,
    'repoPath': projDir,
    'type': 'folder', 
  };
}

Future<Map<String, dynamic>> docx2package(
    String docxPath, String packagePath) async {
  return createTrackingProject(packagePath, docxPath);
}

Future<Map<String, dynamic>> importTrackingSource(
    String packagePath, String targetDir, String sourcePath) async {
  final pkg = _sanitizeFsPath(packagePath);
  final workspace = _projectDir(pkg); 
  
  String relTargetDir = targetDir;
  if (p.isAbsolute(targetDir)) {
    if (p.isWithin(workspace, targetDir)) {
      relTargetDir = p.relative(targetDir, from: workspace);
    } else {
        relTargetDir = '.'; 
    }
  }
  if (relTargetDir == '.') relTargetDir = '';

  final source = _sanitizeFsPath(sourcePath);
  
  if (FileSystemEntity.isFileSync(source)) {
     await _addDocxSubmodule(workspace, relTargetDir, source);
  } else if (FileSystemEntity.isDirectorySync(source)) {
     final files = Directory(source).listSync(recursive: true).whereType<File>().where((f) => p.extension(f.path).toLowerCase() == '.docx');
     for (final f in files) {
        final relFile = p.relative(f.path, from: source);
        final fileTargetDir = p.join(relTargetDir, p.dirname(relFile));
        await _addDocxSubmodule(workspace, fileTargetDir, f.path);
     }
  }
  return {};
}

Future<void> _addDocxSubmodule(String rootPath, String relDir, String docxPath) async {
   final docName = p.basenameWithoutExtension(docxPath);
   final submodulePath = p.normalize(p.join(relDir, docName)).replaceAll(r'\', '/');
   final fullSubmodulePath = p.join(rootPath, submodulePath);
   
   if (Directory(fullSubmodulePath).existsSync()) {
      print('Submodule path already exists, skipping: $submodulePath');
      return;
   }
   
   Directory(fullSubmodulePath).createSync(recursive: true);
   
   await _runGit(['init'], fullSubmodulePath);
   
   await _updateContentDocx(fullSubmodulePath, docxPath);
   
   // Create tracking.json in submodule
   final tracking = {'docxPath': docxPath};
   await File(p.join(fullSubmodulePath, 'tracking.json')).writeAsString(jsonEncode(tracking));
   
   await _runGit(['add', '.'], fullSubmodulePath);
   await _runGit(['commit', '-m', 'first version'], fullSubmodulePath);
   
   final remoteRepoName = _calculateHash(submodulePath);
   final remoteUrl = '../$remoteRepoName.git';
   
   final localUrl = './$submodulePath';
   await _runGit(['submodule', 'add', localUrl, submodulePath], rootPath);
   
   await _runGit(['config', '--file', '.gitmodules', 'submodule.$submodulePath.url', remoteUrl], rootPath);
   
   await _runGit(['add', '.gitmodules'], rootPath);
   await _runGit(['commit', '-m', 'Add submodule $docName'], rootPath);
}

Future<void> _initSingleRepo(String repoPath, String? sourceDocxPath) async {
    // Legacy no-op
}

Future<void> _initTrackingRepo(
    String repoPath, String docxPath, String packagePath) async {
    // Legacy no-op
}

Future<List<Map<String, dynamic>>> listProjectRepos(String name) async {
  final projDir = _projectDir(name);
  final tracking = await _readTracking(name);
  final isFolder = await _isFolderProject(projDir);
  if (!isFolder) {
    return [
      {'relPath': '.', 'repoPath': projDir, 'docxPath': tracking['docxPath']}
    ];
  }

  final results = <Map<String, dynamic>>[];
  final rootDocxPath = tracking['docxPath'] as String?;

  // 1. Try reading from .gitmodules (Priority)
  final gitModulesFile = File(p.join(projDir, '.gitmodules'));
  if (gitModulesFile.existsSync()) {
    try {
      final content = await gitModulesFile.readAsString();
      // Simple regex to parse submodule path
      // [submodule "path"]
      // 	path = path
      // 	url = url
      final pathRegex = RegExp(r'^\s*path\s*=\s*(.*)$', multiLine: true);
      final matches = pathRegex.allMatches(content);
      
      for (final match in matches) {
        final relPath = match.group(1)!.trim();
        final repoPath = p.join(projDir, relPath);
        
        String? subDocxPath;
        // Try to read local tracking.json if exists
        final repoTrackingPath = p.join(repoPath, 'tracking.json');
        if (File(repoTrackingPath).existsSync()) {
          final repoTracking = await _readTrackingJson(repoTrackingPath);
          subDocxPath = repoTracking['docxPath'] as String?;
        }
        
        // Infer from root if missing
        if ((subDocxPath == null || subDocxPath.isEmpty) && rootDocxPath != null) {
           // Assume relPath corresponds to a file in rootDocxPath
           // If relPath is "sub/doc1", and rootDocxPath is "C:/Docs",
           // then doc is "C:/Docs/sub/doc1.docx"
           subDocxPath = p.join(rootDocxPath, '$relPath.docx');
        }
        
        results.add({
            'relPath': relPath,
            'repoPath': repoPath,
            'docxPath': subDocxPath,
            'name': p.basename(relPath),
        });
      }
      return results;
    } catch (e) {
      print('Error parsing .gitmodules: $e');
    }
  }

  // 2. Fallback: Scan directory (Preferred method now)
  final dir = Directory(projDir);
  if (dir.existsSync()) {
    // Scan for .git directories
    final entities = dir.listSync(recursive: true);
    for (final entity in entities) {
      if (entity is Directory && p.basename(entity.path) == '.git') {
        final repoPath = entity.parent.path;
        // Skip the root project repo itself
        if (p.equals(p.normalize(repoPath), p.normalize(projDir))) continue;
        
        final relPath = p.relative(repoPath, from: projDir);

        String? subDocxPath;
        final repoTrackingPath = p.join(repoPath, 'tracking.json');

        if (File(repoTrackingPath).existsSync()) {
          final repoTracking = await _readTrackingJson(repoTrackingPath);
          final repoDocxBase = repoTracking['docxPath'] as String?;
          if (repoDocxBase != null && repoDocxBase.isNotEmpty) {
            final internalPath = repoTracking['internalPath'] as String?;
            subDocxPath = (internalPath != null && internalPath.isNotEmpty)
                ? p.join(repoDocxBase, internalPath)
                : repoDocxBase;
          }
        }
        if (subDocxPath == null && rootDocxPath != null) {
          final mapped = p.setExtension(relPath, '.docx');
          subDocxPath = p.join(rootDocxPath, mapped);
        }

        results.add({
          'relPath': relPath,
          'repoPath': repoPath,
          'docxPath': subDocxPath,
        });
      }
    }
  }
  return results;
}

Future<void> syncFolderProject(String name) async {
  
  print('[Debug][syncFolderProject] Start for name: $name');

  final projDir = _projectDir(name);
  print('[Debug][syncFolderProject] projDir: $projDir');

  // Detect Workspace Root
  bool isWorkspaceRoot = false;
  if (File(p.join(projDir, '.tracking_workspace.json')).existsSync()) {
    isWorkspaceRoot = true;
    print('[Debug][syncFolderProject] Detected Workspace Root at $projDir');
  }

  final tracking = await _readTracking(name);
  print('[Debug][syncFolderProject] tracking: $tracking');

  // Attempt to recover packagePath if missing
  if ((tracking['packagePath'] as String? ?? '').isEmpty) {
    if (isWorkspaceRoot) {
      final wsPackagePath = await _readWorkspacePackagePath(projDir);
      if (wsPackagePath != null && wsPackagePath.isNotEmpty) {
        tracking['packagePath'] = wsPackagePath;
        print('[Debug][syncFolderProject] Recovered packagePath from workspace: $wsPackagePath');
      }
    }
  }

  final sourceRoot = tracking['docxPath'] as String?;
  print('[Debug][syncFolderProject] sourceRoot: $sourceRoot');

  if (sourceRoot == null) {
    print('[Debug][syncFolderProject] No docxPath configured. Skipping external sync steps.');
  }

  var targetBaseDir = projDir;
  if (isWorkspaceRoot) {
    // Fix: Use package name instead of source filename for project root
    String pkgPath = tracking['packagePath'] as String? ?? '';
    if (pkgPath.isEmpty) pkgPath = name;
    final projectName = _trackingBaseName(pkgPath);

    targetBaseDir = p.join(projDir, projectName);
    if (!Directory(targetBaseDir).existsSync()) {
      Directory(targetBaseDir).createSync(recursive: true);
    }
    print('[Debug][syncFolderProject] Redirecting sync to subdirectory: $targetBaseDir');
  }

  if (sourceRoot != null) {
    // 1. Scan source folder for .docx files
    List<File> sourceFiles = [];
    bool isSourceFile = false;

    if (FileSystemEntity.isFileSync(sourceRoot)) {
      isSourceFile = true;
      sourceFiles.add(File(sourceRoot));
    } else if (FileSystemEntity.isDirectorySync(sourceRoot)) {
      sourceFiles = Directory(sourceRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.extension(f.path).toLowerCase() == '.docx')
          .where((f) => !p.basename(f.path).startsWith('~\$'))
          .toList();
    } else {
      // Source folder deleted? We might want to warn or do nothing, but user said sync.
      // If source is gone, maybe we should delete everything? Safer to throw for now.
      throw Exception('Source not found: $sourceRoot');
    }

    final sourceRelPaths = <String>{};

    // 2. Update or Create repos
    for (final file in sourceFiles) {
      String relPath;
      if (isSourceFile) {
        relPath = p.basename(file.path);
      } else {
        relPath = p.relative(file.path, from: sourceRoot);
      }
      
      final relTrackingPath = p.setExtension(relPath, kTrackingExt);
      sourceRelPaths.add(relTrackingPath);

      final targetRepoPath = p.join(targetBaseDir, relTrackingPath);
      // This will create if not exists, or update content.docx if exists
      if (!Directory(targetRepoPath).existsSync()) {
        final packagePath = tracking['packagePath'] as String? ?? '';
        if (packagePath.isNotEmpty) {
          await _initTrackingRepo(targetRepoPath, file.path, packagePath);
        } else {
          await _initSingleRepo(targetRepoPath, file.path);
        }
      } else {
        await _updateContentDocx(targetRepoPath, file.path);
      }
    }

    // 3. Update folder_meta.json (Deprecated)
  // await _scanAndUpdateFolderMeta(targetBaseDir, sourceRoot, trackingExt: kTrackingExt);

    // 4. Scan target folder for repos (directories with .git)
    // We need to be careful not to delete the root projDir itself if it happens to be a repo (unlikely in folder mode)
    final targetDir = Directory(targetBaseDir);
    if (targetDir.existsSync()) {
      final entities = targetDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is Directory && p.basename(entity.path) == '.git') {
          final repoPath = entity.parent.path;
          // If repoPath is the project root, skip? Folder mode structure: projDir/sub/a.docx/.git
          if (p.equals(p.normalize(repoPath), p.normalize(targetBaseDir))) continue;

          final relPath = p.relative(repoPath, from: targetBaseDir);

          // Check if this relPath exists in source
          if (!sourceRelPaths.contains(relPath)) {
            // User requested NOT to delete orphaned repos during sync.
            // print('Deleting orphaned repo: $repoPath');
            // try {
            //   entity.parent.deleteSync(recursive: true);
            // } catch (e) {
            //   print('Failed to delete orphaned repo: $e');
            // }
          }
        }
      }
    }
  }

  final packagePath = tracking['packagePath'] as String?;
  if (packagePath != null && packagePath.isNotEmpty) {
    try {
      await _exportFolderToTrackingPackage(projDir, packagePath);
    } catch (e) {
      print('Failed to export tracking package: $e');
    }
  }
  
  print('[Debug][syncFolderProject] End for $name');
  
}

Future<Map<String, dynamic>> openTrackingProject(String name) async {
  final packagePath = _sanitizeFsPath(name);
  final projDir = packagePath.toLowerCase().endsWith(kTrackingExt)
      ? (Directory(packagePath).existsSync()
          ? packagePath
          : await _ensureWorkspace(packagePath))
      : _projectDir(name);

  var repoPath = projDir;
  final subName = _trackingBaseName(packagePath);

  // Check if we are in a workspace root (which we should be for .tracking.zip)
  // final isWorkspaceRoot = File(p.join(projDir, kWorkspaceMetaFile)).existsSync();

  if (subName.isNotEmpty && subName != '.') {
    final subDir = p.join(projDir, subName);
    if (Directory(p.join(subDir, '.git')).existsSync() ||
        File(p.join(subDir, 'tracking.json')).existsSync()) {
      // It exists as a sub-repo, but we are opening the PROJECT (package),
      // so we should stick to the root projDir as the entry point.
      // repoPath = subDir; // DISABLED: Always open root
    }
  }

  final dir = Directory(repoPath);
  if (!dir.existsSync()) {
    throw Exception('project not found');
  }
  var tracking = await _readTracking(packagePath);

  // Fallback: If docxPath is missing and it is a .tracking.zip file, try reading from zip
  if ((tracking['docxPath'] == null || tracking['docxPath'] == '') &&
      packagePath.toLowerCase().endsWith(kTrackingExt) &&
      File(packagePath).existsSync()) {
    final zipTracking = await _readTrackingFromZip(packagePath);
    if (zipTracking['docxPath'] != null && zipTracking['docxPath'] != '') {
      print('Recovered docxPath from zip: ${zipTracking['docxPath']}');
      tracking['docxPath'] = zipTracking['docxPath'];
      // Persist back to workspace
      await _writeTracking(packagePath, tracking);
    }
  }

  if (tracking.isEmpty) {
    // Check if it is a folder project (has .gitmodules or no tracking.json)
    // If so, do NOT create tracking.json in root if it's meant to be a container
    // But wait, if it's a container, we just need a name.
    
    final initial = {
        'name': packagePath,
        'packagePath': packagePath,
        // No docxPath for root project as it is a container
    };
      
    if (repoPath != projDir) {
        await File(p.join(repoPath, 'tracking.json')).writeAsString(jsonEncode(initial));
    } else {
        await _writeTracking(packagePath, initial);
    }
  }

  // Check and auto-init structure for folder projects if needed
  bool shouldInitStructure = false;
  // if (File(p.join(repoPath, 'folder_meta.json')).existsSync()) {
  //   shouldInitStructure = true;
  // } else 
  if (tracking['docxPath'] != null &&
      FileSystemEntity.isDirectorySync(tracking['docxPath'])) {
    shouldInitStructure = true;
  }
  
  // Force structure init if it's a root project (no docxPath)
  if (tracking['docxPath'] == null) {
      shouldInitStructure = true;
  }

  if (shouldInitStructure) {
    final pkgPath = (tracking['packagePath'] as String?) ?? packagePath;
    await _ensureFolderProjectStructure(repoPath, tracking['docxPath'] ?? '',
        trackingExt: kTrackingExt, packagePath: pkgPath);
  }

  // Always try to notify parent folder project (if any) to keep metadata fresh
  // This covers the case where we open a sub-project directly
  await _notifyParentFolderProject(repoPath);

  // Re-check folder status after potential structure init
  final isFolder = await _isFolderProject(repoPath);
  
  // Root project is ALWAYS a folder project
  final isRoot = await _isWorkspaceRoot(repoPath) || repoPath == projDir;

  return {
    'name': packagePath,
    'repoPath': repoPath,
    'docxPath': tracking['docxPath'],
    'type': (isFolder || isRoot) ? 'folder' : 'file',
    'packagePath': packagePath,
  };
}

Future<bool> _isWorkspaceRoot(String path) async {
    return File(p.join(path, kWorkspaceMetaFile)).existsSync();
}


Future<Map<String, dynamic>?> getTrackingInfo(String repoPath) async {
  final normalized = p.normalize(repoPath);
  final root = await _findWorkspaceRoot(normalized);
  if (root == null) return null;
  final packagePath = await _readWorkspacePackagePath(root) ?? '';
  final info = await _resolveTrackingInfo(normalized);
  final tracking = info.isNotEmpty
      ? (info['rawTracking'] as Map<String, dynamic>? ?? <String, dynamic>{})
      : await _readTracking(packagePath.isNotEmpty ? packagePath : root);
  final docxPath = info['docxPath'] ?? tracking['docxPath'];
  final trackingRoot = info['trackingRoot'] as String?;
  final resolvedPackagePath =
      tracking['packagePath'] as String? ?? packagePath;
  return {
    'name': resolvedPackagePath.isNotEmpty
        ? resolvedPackagePath
        : (packagePath.isNotEmpty ? packagePath : root),
    'docxPath': docxPath,
    'repoDocxPath': tracking['repoDocxPath'],
    'packagePath': resolvedPackagePath,
    'trackingRoot': trackingRoot,
  };
}

Future<Map<String, dynamic>> updateTrackingProject(
    String name, bool opIdentical,
    {String? newDocxPath, String? repoPath, String? docxPath}) async {
  final normalizedName = _sanitizeFsPath(name);
  var projDir = repoPath ?? _projectDir(normalizedName);
  if (repoPath == null && normalizedName.toLowerCase().endsWith(kTrackingExt)) {
    if (Directory(normalizedName).existsSync()) {
      projDir = normalizedName;
    } else {
      projDir = await _ensureWorkspace(normalizedName);
    }
    // We do NOT auto-resolve to subfolder if it is the root project.
    // The root project is the container.
  }
  if (repoPath != null) {
    final gitDir = Directory(p.join(projDir, '.git'));
    if (!gitDir.existsSync()) {
      print('[updateTrackingProject] No .git at $projDir, trying to resolve');
      // If we are updating the root project, and .git is missing, it might be an empty container.
      // We should NOT try to resolve to a sub-repo unless explicitly asked.
      // But updateTrackingProject logic for root is just metadata sync.
    }
  }
  return _withRepoLock(projDir, () async {
    _isUpdating[normalizedName] = true;
    final totalSw = Stopwatch()..start();
    final sectionSw = Stopwatch()..start();

    try {
      final dir = Directory(projDir);
      if (!dir.existsSync()) {
        throw Exception('project not found');
      }

      Map<String, dynamic> tracking;
      if (repoPath != null) {
        final info = await _resolveTrackingInfo(projDir);
        tracking = {
          'name': normalizedName,
          'docxPath': info['docxPath'] ?? docxPath,
          'packagePath': info['packagePath'] ?? normalizedName,
        };
      } else {
        tracking = await _readTracking(normalizedName);
      }

      String? sourcePath = tracking['docxPath'] as String?;
      if (newDocxPath != null && newDocxPath.trim().isNotEmpty) {
        sourcePath = _sanitizeFsPath(newDocxPath);
        tracking['docxPath'] = sourcePath;
      }

      // Check if root project (no docxPath usually)
      final isRoot = await _isWorkspaceRoot(projDir) || (sourcePath == null && repoPath == null);
      
      // If root project, we force it to be a folder project and skip docx checks
      if (isRoot) {
          print('[updateTrackingProject] Root project detected. Treating as folder.');
          
          await _notifyParentFolderProject(projDir);
          await syncFolderProject(name);

          try {
             await _persistTrackingPackageForRepo(projDir);
          } catch (e) {
             print('Persist tracking package failed: $e');
          }

          return {
            'repoPath': projDir,
            'workingChanged': false,
            'head': null,
          };
      }

      // Verify source exists
      bool sourceExists = false;
      if (sourcePath != null && sourcePath.isNotEmpty) {
        if (FileSystemEntity.isFileSync(sourcePath) ||
            FileSystemEntity.isDirectorySync(sourcePath)) {
          sourceExists = true;
        }
      }

      print(
          '[Perf] Pre-checks & Tracking Read: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      if (!sourceExists) {
        // Allow empty source for folder projects / workspace roots
        final isFolder = await _isFolderProject(projDir);
        // We already checked isRoot above, but double check
        
        if (!isFolder && !isRoot) {
           return {'needDocx': true, 'repoPath': projDir};
        }
      }

      // Ensure repo is initialized if it doesn't exist (e.g. empty project populated for the first time)
      if (!Directory(p.join(projDir, '.git')).existsSync()) {
        // New: Check if we should initialize in a subfolder (e.g. example.tracking.zip -> example/.git)
        final subName = _trackingBaseName(normalizedName);
        if (subName.isNotEmpty && subName != '.') {
          final subDir = p.join(projDir, subName);
          
          bool switchToSub = false;

          // Case 1: Folder project matching name
          if (FileSystemEntity.isDirectorySync(sourcePath!) &&
              sourcePath.endsWith(subName)) {
            switchToSub = true;
          }

          // Case 2: Workspace root context (e.g. .tracking.zip)
          // If the current projDir has .tracking_workspace.json, we should NEVER init .git in it.
          if (File(p.join(projDir, kWorkspaceMetaFile)).existsSync()) {
            switchToSub = true;
          }

          if (switchToSub) {
            print('[updateTrackingProject] Switching initialization to subfolder: $subDir');
            if (!Directory(subDir).existsSync()) {
              Directory(subDir).createSync(recursive: true);
            }
            projDir = subDir;
          }
        }

        print('[updateTrackingProject] Initializing git repo at $projDir');
        if (FileSystemEntity.isDirectorySync(sourcePath!)) {
          await _ensureFolderProjectStructure(projDir, sourcePath,
              trackingExt: kTrackingExt, packagePath: tracking['packagePath']);
        } else {
          await _initSingleRepo(projDir, sourcePath);
        }
      }

      // Check if folder type
      final isFolder = await _isFolderProject(projDir);

      if (!isFolder) {
        // Ensure content dir exists in repo
        final contentDir = Directory(p.join(projDir, kContentDirName));
        if (!contentDir.existsSync()) {
          contentDir.createSync();
        }
        tracking['repoDocxPath'] = contentDir.path;
      }

      if (repoPath == null) {
        await _writeTracking(normalizedName, tracking);
      }

      print(
          '[Perf] Ensure Content Dir & Write Tracking: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      // Check if folder type, if so, we are done with tracking update, return.
      // Folder type projects are containers, not git repos themselves.
      if (isFolder) {
        print(
            '[Perf] Folder project updated. Skipping git operations on root.');

        await _notifyParentFolderProject(projDir);
        await syncFolderProject(name);

        try {
          await _persistTrackingPackageForRepo(projDir);
        } catch (e) {
          print('Persist tracking package failed: $e');
        }

        return {
          'repoPath': projDir,
          'workingChanged':
              false, // or true? Folder tracking update implies maybe sub-repos changed?
          // But status check on root will fail.
          // Let's assume folder project update is just metadata update.
          'head': null,
        };
      }

      // Compare Source vs HEAD
      bool isIdenticalToHead =
          true; // Default assumption until proven otherwise
      bool hasHead = false;

      final tmpDir = await Directory.systemTemp.createTemp('git_head_check_');
      try {
        if (opIdentical) {
          final headDocx = p.join(tmpDir.path, 'HEAD.docx');
          try {
            await _gitArchiveToDocx(projDir, 'HEAD', headDocx);
            hasHead = true;
          } catch (e) {
            print('Git archive HEAD failed (maybe no HEAD?): $e');
          }

          print('[Perf] Git Archive HEAD: ${sectionSw.elapsedMilliseconds}ms');
          sectionSw.reset();

          if (hasHead && sourcePath != null) {
            // Always check to know if changed
            isIdenticalToHead = await _checkDocxIdentical(sourcePath, headDocx);
            print("identical? $isIdenticalToHead");
            print(
                '[Perf] Check Identical (Source vs HEAD): ${sectionSw.elapsedMilliseconds}ms');
            sectionSw.reset();
          }

          if (hasHead && isIdenticalToHead) {
            // Restore working copy (repo/doc_content) to HEAD
            await _runGit(['reset', '--hard', 'HEAD'], projDir);
            print(
                '[Perf] Restore (Git Reset Hard): ${sectionSw.elapsedMilliseconds}ms');
            sectionSw.reset();
          }
        }
      } finally {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (e) {
          print('Error cleaning up tmpDir in updateTrackingProject: $e');
        }
      }

      // Check status
      List<String> status = [];
      try {
        status = await _runGit(['status', '--porcelain'], projDir);
        if (status.isNotEmpty) {
          print("Git Status dirty: $status");
        }
      } catch (e) {
        print("Git status check failed (ignored): $e");
      }

      bool changed = status.isNotEmpty;
      if (opIdentical) {
        if (hasHead && !isIdenticalToHead) {
          changed = true;
        }
        // If we don't have HEAD (initial commit), and source exists -> changed.
        if (!hasHead && sourcePath != null) {
          changed = true;
        }
      }

      print('[Perf] Git Status: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      String? head;
      try {
        final lines = await _runGit(['rev-parse', 'HEAD'], projDir);
        if (lines.isNotEmpty) head = lines.first.trim();
      } catch (e) {
        print('Error getting HEAD in updateTrackingProject: $e');
      }
      print('[Perf] Get HEAD: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      totalSw.stop();
      print(
          '[Perf] updateTrackingProject Total Time: ${totalSw.elapsedMilliseconds}ms');

      await _notifyParentFolderProject(projDir);

      try {
        await _persistTrackingPackageForRepo(projDir);
      } catch (e) {
        print('Persist tracking package failed: $e');
      }

      return {
        'repoPath': projDir,
        'workingChanged': changed,
        'head': head,
      };
    } finally {
      // await Future.delayed(const Duration(milliseconds: 1000));
      _isUpdating[normalizedName] = false;
    }
  });
}

Future<void> _syncToExternal(String repoPath) async {
  final sw = Stopwatch()..start();
  // Sync doc_content -> content.docx -> External
  // This should be called after operations that modify the working tree (pull, merge, reset, checkout)
  final info = await _resolveTrackingInfo(repoPath);
  final docxPath = info['docxPath'] as String?;
  if (docxPath == null) return;

  print('Syncing internal doc_content to external: $docxPath');

  // 1. Zip doc_content -> content.docx
  // We use _forceRegenerateRepoDocx which does exactly this:
  // zips doc_content -> content.docx
  // But wait, _forceRegenerateRepoDocx calls _ensureRepoDocx which calls _zipDir.
  // Let's use _ensureRepoDocx logic but forced.

  final contentDir = p.join(repoPath, kContentDirName);
  final repoDocx = p.join(repoPath, kRepoDocxName);

  if (Directory(contentDir).existsSync()) {
    // Always regenerate content.docx from doc_content to be sure
    if (File(repoDocx).existsSync()) {
      try {
        File(repoDocx).deleteSync();
      } catch (e) {
        print('Error deleting repoDocx: $e');
      }
    }
    await _zipDir(contentDir, repoDocx);
    print(
        '[Perf][GitService][SyncToExternal][ZipDir] ${sw.elapsedMilliseconds}ms');
    sw.reset();
  }

  // 2. Update External
  if (File(repoDocx).existsSync()) {
    await _writeExternalDocx(repoPath, repoDocx);
    print(
        '[Perf][GitService][SyncToExternal][WriteExternal] ${sw.elapsedMilliseconds}ms');
    sw.reset();
  }
  sw.stop();

  try {
    await _persistTrackingPackageForRepo(repoPath);
  } catch (e) {
    print('Persist tracking package failed: $e');
  }
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
      print(
          '[_checkDocxIdentical_Perf] _checkDocxIdentical Zip Dir: ${sectionSw.elapsedMilliseconds}ms');
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
      print(
          '[_checkDocxIdentical_Perf] _checkDocxIdentical Read Files: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      writePart('file1', p.basename(path1), b1);
      writePart('file2', p.basename(path2), b2);
      req.write('--$boundary--\r\n');

      final resp = await req.close().timeout(const Duration(seconds: 30));
      print(
          '[_checkDocxIdentical_Perf] _checkDocxIdentical Request & Response: ${sectionSw.elapsedMilliseconds}ms');
      sectionSw.reset();

      if (resp.statusCode != 200) {
        return false;
      }
      final bodyStr = await utf8.decodeStream(resp);
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;

      totalSw.stop();
      print(
          '[_checkDocxIdentical_Perf] _checkDocxIdentical Total: ${totalSw.elapsedMilliseconds}ms');

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
    } catch (e) {
      print('Error cleaning up tmpDir in _checkDocxIdentical: $e');
    }
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
  await ensureCommitPreviewAssets(repoPath, commitId);
  final pdfPath = _globalCachedPdfPath(commitId);
  final f = File(pdfPath);
  if (f.existsSync()) {
    return await f.readAsBytes();
  }
  throw Exception('Preview generation failed');
}

Future<void> resetBranch(String projectName, String commitId) async {
  final repoPath = _projectDir(projectName);
  return _withRepoLock(repoPath, () async {
    if (await _isFolderProject(repoPath)) {
      final repos = await listProjectRepos(projectName);
      for (final r in repos) {
        final subPath = r['repoPath'] as String;
        if (await _repoHasCommit(subPath, commitId)) {
          print('Found commit $commitId in sub-repo $subPath. Resetting...');
          await _runGit(['reset', '--hard', commitId], subPath);
          clearCache();
          return;
        }
      }
      throw Exception(
          'Commit $commitId not found in any sub-repository of $projectName');
    }

    await _runGit(['reset', '--hard', commitId], repoPath);
    //await _syncToExternal(repoPath);
    clearCache();
  });
}

Future<void> rollbackVersion(String projectName, String commitId) async {
  final repoPath = _projectDir(projectName);
  return _withRepoLock(repoPath, () async {
    if (await _isFolderProject(repoPath)) {
      final repos = await listProjectRepos(projectName);
      for (final r in repos) {
        final subPath = r['repoPath'] as String;
        if (await _repoHasCommit(subPath, commitId)) {
          print('Found commit $commitId in sub-repo $subPath. Rolling back...');
          await _runGit(['checkout', commitId, '--', kContentDirName], subPath);
          await _syncToExternal(subPath);
          return;
        }
      }
      throw Exception(
          'Commit $commitId not found in any sub-repository of $projectName');
    }

    // Checkout doc_content from commitId to working dir
    // git checkout commitId -- doc_content
    await _runGit(['checkout', commitId, '--', kContentDirName], repoPath);

    // Sync to external
    await _syncToExternal(repoPath);
  });
}

Future<String?> getHead(String repoPath) async {
  try {
    final lines = await _runGit(['rev-parse', 'HEAD'], repoPath);
    if (lines.isEmpty) return null;
    final id = lines.first.trim();
    return id.isEmpty ? null : id;
  } catch (e) {
    print('Error getting HEAD: $e');
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
    } catch (e) {
      print('Error parsing file URI: $e');
    }
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

  List<String> accessibleRepos = [];

  String? findOwnerInList(List<dynamic> list) {
    for (final repo in list) {
      final name = repo['name'].toString();
      accessibleRepos.add(name);
      if (name.toLowerCase() == repoName.toLowerCase()) {
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

  print('Debug: Repo $repoName not found. Access list: $accessibleRepos');

  throw Exception(
      'Repository $repoName not found in your account access list. Available: ${accessibleRepos.join(", ")}');
}

String _calculateHash(String input) {
  var bytes = utf8.encode(input);
  var digest = md5.convert(bytes);
  return digest.toString();
}

Future<String?> _findParentFolderProject(String path) async {
  try {
    final root = await _findWorkspaceRoot(path);
    if (root == null) return null;
    if (!p.isWithin(root, path) && !p.equals(root, path)) return null;
    return root;
  } catch (e) {
    print('Error finding parent tracking root: $e');
    return null;
  }
}

Future<void> _ensureUniqueRemote(
    String repoPath, String remoteName, String remoteUrl) async {
  // Get all existing remotes
  final remotes = await _runGit(['remote'], repoPath);
  for (final existingRemote in remotes) {
    if (existingRemote.trim().isEmpty) continue;
    // Remove if it's not the one we want, OR if we want to force update the url
    if (existingRemote.trim() != remoteName) {
      await _runGit(['remote', 'remove', existingRemote.trim()], repoPath);
    }
  }

  // Check if target remote exists and has correct URL
  bool exists = false;
  try {
    final currentUrl =
        await _runGit(['remote', 'get-url', remoteName], repoPath);
    if (currentUrl.isNotEmpty && currentUrl.first.trim() == remoteUrl) {
      exists = true;
    } else {
      // URL mismatch or exists but we want to be sure, remove it
      await _runGit(['remote', 'remove', remoteName], repoPath);
    }
  } catch (_) {
    // remote doesn't exist
  }

  if (!exists) {
    await _runGit(['remote', 'add', remoteName, remoteUrl], repoPath);
  }
}

Future<void> pushToRemote(String repoPath, String username, String token,
    {bool force = false}) async {
  return _withRepoLock(repoPath, () async {
    final repoName = p.basename(repoPath);
    String effectiveRemoteRepoName;

    final parentFolder = await _findParentFolderProject(repoPath);
    if (parentFolder == null || p.equals(parentFolder, repoPath)) {
      effectiveRemoteRepoName = repoName;
    } else {
      final relativePath = p.relative(repoPath, from: parentFolder);
      final normalizedRelPath = relativePath.replaceAll(r'\', '/');
      effectiveRemoteRepoName = _calculateHash(normalizedRelPath);
      print(
          'Pushing sub-repo "$repoName" as hashed remote: $effectiveRemoteRepoName (rel: $normalizedRelPath)');
    }

    String owner;
    try {
      owner = await _resolveRepoOwner(effectiveRemoteRepoName, token);
    } catch (_) {
      await ensureRemoteRepoExists(effectiveRemoteRepoName, token);
      owner = username;
    }

    final remoteUrl =
        'http://$username:$token@47.242.109.145:3000/$owner/$effectiveRemoteRepoName.git';

    // Ensure unique remote logic
    final remoteName = effectiveRemoteRepoName.toLowerCase();
    await _ensureUniqueRemote(repoPath, remoteName, remoteUrl);

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
      if (!force) {
        final outStr = output.join('\n');
        if (outStr.contains('Everything up-to-date')) {
          await _checkIfBehind(repoPath, remoteUrl);
        }
      }
    }

    // Check for parent folder project and update/push if needed
    try {
      final baseDir = _baseDir();
      final workspaceBase = _workspaceBaseDir();
      Directory current = Directory(p.dirname(repoPath));

      if (p.isWithin(baseDir, repoPath) || p.isWithin(workspaceBase, repoPath)) {
        while (true) {
          final path = current.path;
          if (p.equals(path, baseDir) || p.equals(path, workspaceBase)) break;
          if (!p.isWithin(baseDir, path) && !p.isWithin(workspaceBase, path)) break;

          if (File(p.join(path, 'folder_meta.json')).existsSync()) {
            print('Found parent folder project: $path');
            // Recursively push parent
            try {
              await pushToRemote(path, username, token, force: force);
            } catch (e) {
              print(
                  'Push to parent failed: $e. Attempting rebase pull and retry...');
              try {
                // If push failed (likely behind), try to pull --rebase
                final remoteName = p.basename(path).toLowerCase();
                final parentRemoteUrl =
                    'http://$username:$token@47.242.109.145:3000/${await _resolveRepoOwner(remoteName, token)}/$remoteName.git';
                // Ensure unique remote logic for parent too
                await _ensureUniqueRemote(path, remoteName, parentRemoteUrl);

                await _runGit(['pull', '--rebase', remoteName, 'master'], path);
                print('Rebase successful. Retrying push...');
                await pushToRemote(path, username, token, force: force);
              } catch (retryErr) {
                print('Retry push failed: $retryErr');
                // Rethrow original error or new error?
                // Let's print but not crash the whole chain?
                // Or maybe we SHOULD crash to let user know sync failed.
                throw Exception(
                    'Failed to sync parent folder "$path": $retryErr');
              }
            }
            break;
          }

          final parent = current.parent;
          if (parent.path == current.path) break;
          current = parent;
        }
      }
    } catch (e) {
      print('Failed to push parent folder: $e');
    }
  });
}

Future<void> _checkIfBehind(String repoPath, String remoteUrl) async {
  // We must ensure we have the latest remote objects to perform merge-base checks.
  // Otherwise, if we haven't fetched the remote commit, merge-base will fail.
  try {
    await _runGit(['fetch', remoteUrl], repoPath);
  } catch (e) {
    print('Warning: Failed to fetch during check-if-behind: $e');
  }

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
    String nameOrPath, String username, String token,
    {bool force = false, String? targetRepoName, String? localTrackingZipPath, String? currentPath}) async {
  
  print('Debug: pullFromRemote - nameOrPath: $nameOrPath, targetRepoName: $targetRepoName, localTrackingZipPath: $localTrackingZipPath');
  final repoPath = (localTrackingZipPath != null && localTrackingZipPath.isNotEmpty)
      ? p.join(
          _workspaceDirForPackage(localTrackingZipPath), p.basename(nameOrPath))
      : (p.isAbsolute(nameOrPath) ? nameOrPath : _projectDir(nameOrPath));
  return _withRepoLock(repoPath, () async {
    String effectiveRemoteRepoName;
    if (targetRepoName != null && targetRepoName.isNotEmpty) {
      effectiveRemoteRepoName = targetRepoName;
    } else {
      final parentFolder = await _findParentFolderProject(repoPath);
      if (parentFolder == null || p.equals(parentFolder, repoPath)) {
        effectiveRemoteRepoName = p.basename(repoPath);
      } else {
        final relativePath = p.relative(repoPath, from: parentFolder);
        final normalizedRelPath = relativePath.replaceAll(r'\', '/');
        effectiveRemoteRepoName = _calculateHash(normalizedRelPath);
        print(
            'Pulling sub-repo as hashed remote: $effectiveRemoteRepoName (rel: $normalizedRelPath)');
      }
    }

    final remoteName = effectiveRemoteRepoName.toLowerCase();
    final projDir = repoPath;
    final dir = Directory(projDir);
    final gitDir = Directory(p.join(projDir, '.git'));

    final owner = await _resolveRepoOwner(effectiveRemoteRepoName, token);
    final remoteUrl =
        'http://$username:$token@47.242.109.145:3000/$owner/$effectiveRemoteRepoName.git';

    // Map<String, dynamic>? savedTracking;
    // Map<String, dynamic>? savedTracking;
    bool isFresh = !dir.existsSync() || !gitDir.existsSync();

    if (!isFresh && force) {
      try {
        // savedTracking = await _readTracking(repoName);
      } catch (e) {
        print('Error reading tracking (commented out code): $e');
      }
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
      // Check if it is a folder project (has .gitmodules)
  final isFolderProject = File(p.join(projDir, '.gitmodules')).existsSync();
  print('Debug: pullFromRemote - repoPath: $projDir, isFresh: $isFresh, isFolderProject: $isFolderProject');
  
  if (isFolderProject || !File(p.join(projDir, 'tracking.json')).existsSync()) {
      // If it has .gitmodules OR if it has no tracking.json (likely an empty container just initialized),
      // we treat it as a folder project.
      
     // Folder Project Pull Logic: Pull Container + Update Submodules
        try {
          await _ensureUniqueRemote(projDir, remoteName, remoteUrl);
          await _runGit(['fetch', remoteName], projDir);

          // For folder projects (containers), we generally just want to sync the structure (gitmodules)
          // We can try to fast-forward merge or reset hard to remote master if we treat it as a pure container.
          
          final current = await getCurrentBranch(projDir);
          if (current != null) {
              // Try merge first? Or reset hard? 
              // Since user says "folder_meta is deprecated", we assume we trust git structure.
              // Let's do a pull (fetch + merge)
              await _runGit(['pull', remoteName, current], projDir);
          } else {
              // Detached head?
              await _runGit(['fetch', remoteName, 'master'], projDir);
              await _runGit(['reset', '--hard', '$remoteName/master'], projDir);
          }
          
          // Update submodules
          await _runGit(['submodule', 'update', '--init', '--recursive'], projDir);

        } catch (e) {
          print('Folder project pull failed: $e');
          throw Exception('Folder project pull failed: $e');
        }
      } else {
        if (!force) {
          try {
            final trackingFile = File(p.join(projDir, 'tracking.json'));
            if (trackingFile.existsSync()) {
              try {
                await _runGit(['checkout', 'HEAD', '--', '.'], projDir);
              } catch (e) {
                print('Checkout HEAD failed: $e');
              }
            }
          } catch (e) {
            print('Check tracking file failed: $e');
          }

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
          } catch (e) {
            print('Fetch or merge-base check failed: $e');
          }
        }
        // savedTracking = await _readTracking(repoName);

        try {
          await _ensureUniqueRemote(projDir, remoteName, remoteUrl);
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
      }
    } else {
      final parentDir = Directory(projDir).parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
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

    if (localTrackingZipPath != null && localTrackingZipPath.isNotEmpty) {
      
      print('DEBUG: New Project Pull - Packing Strategy');
      print('repoPath (projDir): $projDir');
      print('localTrackingZipPath: $localTrackingZipPath');
      

      try {
        final parentDir = Directory(projDir).parent;
        final globalMetaFile =
            File(p.join(parentDir.path, '.tracking_workspace.json'));
        Map<String, dynamic> meta = {};
        if (await globalMetaFile.exists()) {
          meta = jsonDecode(await globalMetaFile.readAsString());
        }
        meta['externalPath'] = localTrackingZipPath;
        meta['packagePath'] = localTrackingZipPath;
        await globalMetaFile.writeAsString(jsonEncode(meta));
        print(
            'Updated global metadata with externalPath: $localTrackingZipPath');

        // Ensure folder_meta.json exists for the root of the workspace if it's a new package
        // final folderMeta = File(p.join(projDir, 'folder_meta.json'));
        // if (!folderMeta.existsSync()) {
        //   print('Creating default folder_meta.json at ${folderMeta.path}');
        //   await folderMeta.writeAsString(jsonEncode({'files': {}, 'folders': {}}));
        // }

        // Pack the tracking package immediately after cloning and setup
        print('Packing initial structure to $localTrackingZipPath');
        await _exportFolderToTrackingPackage(parentDir.path, localTrackingZipPath);
        print('Packing completed successfully');

      } catch (e, s) {
        print('Failed to update global metadata or pack: $e');
        print(s);
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
          } catch (e) {
            print('Track branch failed: $e');
          }
        } else if (force) {
          if (branchName != currentBranch) {
            try {
              await _runGit(['branch', '-f', branchName, trimmed], projDir);
            } catch (e) {
              print('Force update branch failed: $e');
            }
          }
        }
      }
    } catch (e) {
      print('Sync branches failed: $e');
    }

    // Check if it is a folder project (has .gitmodules)
    final hasGitModules = File(p.join(projDir, '.gitmodules')).existsSync();
    print('Debug: pullFromRemote - Final check - hasGitModules: $hasGitModules');

    if (hasGitModules) {
      // Folder projects should not have tracking.json or content.docx in the root
      print('Debug: Folder project detected. Expanding structure...');
      await _expandFolderProject(projDir, structureOnly: isFresh);
    } else {
       // Only sync external if it's NOT a folder project
       // This prevents content.docx creation in folder project roots
       print('Debug: File project detected (or mixed). Syncing to external...');
       await _syncToExternal(projDir);
    }

    // Notify parent folder project if applicable (only for folder projects)
    if (hasGitModules) {
      await _notifyParentFolderProject(projDir);
    }

    try {
      await _persistTrackingPackageForRepo(projDir);
    } catch (e) {
      print('Persist tracking package failed: $e');
    }

    clearCache();
    return {
      'status': 'success',
      'path': projDir,
      'openPath': currentPath ?? projDir,
      'isFresh': isFresh,
    };
  });
}

Future<Map<String, dynamic>> checkPullStatus(
    String repoName, String username, String token) async {
  final projDir = _projectDir(repoName);
  return _withRepoLock(projDir, () async {
    // Folder project check removed to allow root pull status check

    String effectiveRemoteRepoName;
    final parentRoot = await _findParentFolderProject(projDir);
    if (parentRoot != null && !p.equals(parentRoot, projDir)) {
      final relativePath = p.relative(projDir, from: parentRoot);
      final normalizedRelPath = relativePath.replaceAll(r'\', '/');
      effectiveRemoteRepoName = _calculateHash(normalizedRelPath);
    } else {
      effectiveRemoteRepoName = p.basename(projDir);
    }

    final remoteName = effectiveRemoteRepoName.toLowerCase();
    final owner = await _resolveRepoOwner(effectiveRemoteRepoName, token);
    final remoteUrl =
        'http://$username:$token@47.242.109.145:3000/$owner/$effectiveRemoteRepoName.git';

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
      } catch (e) {
        print('Remote branch check failed (might not exist): $e');
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
  if (!base.existsSync()) {
    base.createSync(recursive: true);
    return [];
  }

  final results = <String>[];
  try {
    final entities = base.listSync();
    for (final entity in entities) {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        if (name == 'cache') continue;
        if (name == 'preview') continue;
        results.add(name);
      } else if (entity is File &&
          entity.path.toLowerCase().endsWith(kTrackingExt)) {
        results.add(p.basename(entity.path));
      }
    }
  } catch (e) {
    print('Error listing projects: $e');
  }
  return results;
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
    } catch (e) {
      print('Error checking project $name: $e');
    }
  }
  print('DEBUG: No project matched for $docxPath');
  return null;
}

Future<void> rebasePull(String repoName, String username, String token) async {
  final projDir = _projectDir(repoName);
  // Removed explicit folder check to allow rebasing root container if needed (unify logic)

  String effectiveRemoteRepoName;
  final parentRoot = await _findParentFolderProject(projDir);
  if (parentRoot != null && !p.equals(parentRoot, projDir)) {
    final relativePath = p.relative(projDir, from: parentRoot);
    final normalizedRelPath = relativePath.replaceAll(r'\', '/');
    effectiveRemoteRepoName = _calculateHash(normalizedRelPath);
  } else {
    effectiveRemoteRepoName = p.basename(projDir);
  }

  final remoteName = effectiveRemoteRepoName.toLowerCase();
  final owner = await _resolveRepoOwner(effectiveRemoteRepoName, token);
  final remoteUrl =
      'http://$username:$token@47.242.109.145:3000/$owner/$effectiveRemoteRepoName.git';

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
    } catch (e) {
      print('Rebase abort failed: $e');
    }
    throw Exception('Rebase failed (likely conflicts): $e');
  }
  try {
    await _persistTrackingPackageForRepo(projDir);
  } catch (e) {
    print('Persist tracking package failed: $e');
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
    String effectiveRemoteRepoName;
    final parentRoot = await _findParentFolderProject(projDir);
    if (parentRoot != null && !p.equals(parentRoot, projDir)) {
      final relativePath = p.relative(projDir, from: parentRoot);
      final normalizedRelPath = relativePath.replaceAll(r'\\', '/');
      effectiveRemoteRepoName = _calculateHash(normalizedRelPath);
    } else {
      effectiveRemoteRepoName = p.basename(projDir);
    }
    final remoteName = effectiveRemoteRepoName.toLowerCase();
    final owner = await _resolveRepoOwner(effectiveRemoteRepoName, token);
    final remoteUrl =
        'http://$username:$token@47.242.109.145:3000/$owner/$effectiveRemoteRepoName.git';

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
      }
    }

    return PullPreviewResult(
      current: currentGraph,
      target: finalTargetGraph,
      result: resultGraph,
      rowMapping: {},
      hasConflicts: hasConflicts,
      conflictingFiles: conflictingFiles,
    );
  });
}

Future<void> deleteProject(String packagePath,
    [String? targetPath, String? trackingbase]) async {
  final pkg = _sanitizeFsPath(packagePath);
  if (pkg.toLowerCase().endsWith(kTrackingExt)) {
    final workspace = await _ensureWorkspace(pkg);
    if (targetPath == null || targetPath.trim().isEmpty) {
      try {
        final f = File(pkg);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        throw Exception('Failed to delete tracking package: $e');
      }
      try {
        final d = Directory(workspace);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (e) {
        print('Error cleaning up workspace: $e');
      }
      return;
    }

    final normalizedTarget = _sanitizeFsPath(targetPath);
    if (!p.isWithin(workspace, normalizedTarget)) {
      throw Exception('Access denied: target not within workspace');
    }

    try {
      if (File(normalizedTarget).existsSync()) {
        File(normalizedTarget).deleteSync();
      } else if (Directory(normalizedTarget).existsSync()) {
        Directory(normalizedTarget).deleteSync(recursive: true);
      }
    } catch (e) {
      throw Exception('Failed to delete target: $e');
    }

    try {
      await _persistTrackingPackageForRepo(normalizedTarget);
    } catch (e) {
      print('Persist tracking package failed: $e');
    }
    return;
  }

  throw Exception('Legacy delete is not supported for non-tracking packages');
}





Future<void> copyTrackingProject(
    String sourceName, String targetRelPath, bool deleteSource) async {
  throw Exception(
      'Copy tracking project is not supported for tracking packages');
}

// Map<String, int> _computeUnifiedMapping(List<GraphResponse> graphs) {
// ...
// }

Future<void> forkLocal(String repoName, String newBranchName) async {
  final repoPath = _projectDir(repoName);
  return _withRepoLock(repoPath, () async {
    // Removed folder check to allow forking root branch

    final currentBranch = await getCurrentBranch(repoPath);
    final remoteName = repoName.toLowerCase();

    // FORK/BRANCH Execution Logic:
    // 1. Cleanup any stale PreviewFork branch
    try {
      await _runGit(['branch', '-D', 'PreviewFork'], repoPath);
    } catch (e) {
      print('Error deleting PreviewFork branch (might not exist): $e');
    }

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
    if (await _isFolderProject(projDir)) {
      throw Exception('Cannot merge on Folder Project Root.');
    }

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
      final psScript = _psScriptPath;

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
      } catch (e) {
        print('Error cleaning up tmpDir in _checkDocxIdentical: $e');
      }
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
    if (await _isFolderProject(projDir)) {
      throw Exception('Cannot complete merge on Folder Project Root.');
    }

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
    } catch (e) {
      print('Error reading edges from target branch: $e');
    }

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
      } catch (e) {
        print('Error checking commit $cid: $e');
      }
    }
  } finally {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (e) {
      print('Error cleaning up tmpDir in findIdenticalCommit: $e');
    }
  }
  return identicals;
}

Future<void> _ensureWebhook(String repoName, String owner, String token) async {
  final giteaUrl = 'http://47.242.109.145:3000/';
  final targetUrl = 'https://llinker.com/gitbackup//webhook';
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
