import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'models.dart';

import 'package:crypto/crypto.dart';

Future<String> sha1hash(String filePath) async {
  print(filePath);

  try {
    final file = File(filePath);

    if (!file.existsSync()) {
      return "错误：文件 '$filePath' 不存在";
    }

    final stream = file.openRead();
    final hash = sha1;
    final bytes = await stream.fold<List<int>>(
        <int>[], (previous, element) => previous..addAll(element));

    final digest = hash.convert(bytes);
    return digest.toString();
  } on FileSystemException catch (e) {
    if (e.osError?.errorCode == 13) {
      return "错误：没有权限读取文件 '$filePath'";
    }
    return "错误：${e.message}";
  } catch (e) {
    return "错误：$e";
  }
}

String _baseDir() {
  final app = Platform.environment['APPDATA'];
  if (app != null && app.isNotEmpty)
    return p.join(app, 'gitdocx_history_cache');
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) return p.join(home, '.gitdocx_history_cachex');
  return p.join(Directory.systemTemp.path, 'gitdocx_history_cache');
}

final String _backupBaseUrl = 'https://llinker.com/gitbackup/';
final String _tempDirName = p.join(_baseDir(), 'temp_backups');

// New checkout base directory
final String _checkoutBaseDir =
    p.join(Directory.systemTemp.path, 'gitbin_checkout');

String _getBackupDir(String repoName) {
  final scriptDir = p.dirname(Platform.script.toFilePath());
  return p.join(p.dirname(scriptDir), _tempDirName, repoName);
}

Future<List<Map<String, dynamic>>> listBackupCommits(
    String repoName, String AuthToken) async {
  final dirPath = _getBackupDir(repoName);
  final dir = Directory(dirPath);
  String LocalSha1 = "";
  if (await File('$dirPath.zip').exists()) {
    LocalSha1 = await sha1hash('$dirPath.zip');
  }

  final zipUrl =
      '$_backupBaseUrl/backups/$repoName/download?token=$AuthToken&LocalSha1=$LocalSha1';
  print("Debug,url=$zipUrl");
  final resp = await http.get(Uri.parse(zipUrl));

  if (resp.statusCode != 200) {
    print(resp.body);
    throw Exception('Failed to download backup: ${resp.statusCode}');
  }

  try {
    final jsonData = jsonDecode(resp.body);
    print("Debug,jsonData=$jsonData,everything cool bro!");
    if (jsonData["message"] == "success") print("File up to date");
  } catch (_) {
    print("New file!");
    //新的文件
    if (await dir.exists()) await dir.delete(recursive: true);
    if (await File('$dirPath.zip').exists())
      await File('$dirPath.zip').delete();
    print("Deleted");
    if (!await dir.exists()) {
      // Download
      print('Downloading backup for $repoName...');

      final zipFile = File('$dirPath.zip');
      await zipFile.parent.create(recursive: true);
      await zipFile.writeAsBytes(resp.bodyBytes);

      // Unzip using PowerShell
      print('Unzipping $repoName...');
      final res = await Process.run('powershell', [
        '-Command',
        'Expand-Archive -Path "${zipFile.path}" -DestinationPath "$dirPath" -Force'
      ]);

      if (res.exitCode != 0) {
        throw Exception('Failed to unzip: ${res.stderr}');
      }
    }
  }

  // Pre-cache all snapshots logic
  print('Pre-caching snapshots for $repoName...');
  final effectiveRepoPath = await _findEffectiveRepoPath(repoName);
  await _precacheSnapshots(repoName, effectiveRepoPath);

  return _getCommitsFromDir(effectiveRepoPath, repoName);
}

Future<void> _precacheSnapshots(String repoName, String repoPath) async {
  final checkoutRoot = Directory(p.join(_checkoutBaseDir, repoName));
  if (!await checkoutRoot.exists()) {
    await checkoutRoot.create(recursive: true);
  }

  // Get all commit hashes
  final res = await Process.run('git', ['log', '--format=%H'],
      workingDirectory: repoPath);
  if (res.exitCode != 0) {
    throw Exception('Failed to get commits for precache: ${res.stderr}');
  }

  final commits = (res.stdout as String)
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  print('Found ${commits.length} commits in backup repo.');

  for (final commitId in commits) {
    final targetDir = Directory(p.join(checkoutRoot.path, commitId));
    if (await targetDir.exists()) {
      // Skip if already cached
      continue;
    }

    print('Caching snapshot for $commitId...');
    
    // Checkout commit in the parent repo
    final checkoutRes = await Process.run('git', ['checkout', '-f', commitId],
        workingDirectory: repoPath);
    if (checkoutRes.exitCode != 0) {
      print('Failed to checkout $commitId: ${checkoutRes.stderr}');
      continue;
    }

    // Copy content to targetDir
    await targetDir.create(recursive: true);
    
    // Use PowerShell to copy everything except .git folder of the backup repo
    // We want to capture the workspace state at that commit.
    final copyRes = await Process.run('powershell', [
      '-Command',
      'Get-ChildItem -Path "${repoPath}" -Exclude ".git" | Copy-Item -Destination "${targetDir.path}" -Recurse -Force'
    ]);

    if (copyRes.exitCode != 0) {
      print('Failed to copy snapshot for $commitId: ${copyRes.stderr}');
    }
    
    // Check if we have a bare repo in subdirectories
    bool hasBareRepo = false;
    final subs = targetDir.listSync().whereType<Directory>();
    for (final s in subs) {
      if (await File(p.join(s.path, 'HEAD')).exists() && 
          await File(p.join(s.path, 'config')).exists() && 
          await Directory(p.join(s.path, 'refs')).exists()) {
        hasBareRepo = true;
        break;
      }
    }

    // Ensure targetDir is a valid git repo (so getGraph works correctly for comparison)
    // If the snapshot itself doesn't contain a .git folder (which it likely doesn't if it's just a file backup),
    // we create a dummy one.
    if (!hasBareRepo && !await Directory(p.join(targetDir.path, '.git')).exists()) {
        await Process.run('git', ['init'], workingDirectory: targetDir.path);
        await Process.run('git', ['config', 'user.email', 'backup@local'], workingDirectory: targetDir.path);
        await Process.run('git', ['config', 'user.name', 'BackupBot'], workingDirectory: targetDir.path);
        await Process.run('git', ['add', '.'], workingDirectory: targetDir.path);
        await Process.run('git', ['commit', '-m', 'Snapshot state'], workingDirectory: targetDir.path);
    }
  }

  // Restore master
  await Process.run('git', ['checkout', '-f', 'master'],
    workingDirectory: repoPath);
}

Future<List<Map<String, dynamic>>> _getCommitsFromDir(
    String repoPath, String repoName) async {
  print("Execute _getCommitsFromDir with param repoPath=$repoPath");
  
  // Previously we checked for cached snapshots here, but now we rely on the backup repo's git history directly.
  
  final result = await Process.run(
    'git',
    [
      'log',
      '--pretty=format:%H|%P|%an|%ad|%s',
      '--date=iso',
      'master', // Assuming master branch of parent repo
    ],
    workingDirectory: repoPath,
  );

  if (result.exitCode != 0) {
    // If git log failed and we didn't find snapshots above, it's a real error
    var stackTrace = StackTrace.current;
    print('调用栈信息：');
    print(stackTrace);
    throw Exception('Git log failed and no snapshots found: ${result.stderr}');
  }

  final lines = (result.stdout as String).split('\n');
  final commits = <Map<String, dynamic>>[];

  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('|');
    if (parts.length < 5) continue;

    final id = parts[0];
    final parents = parts[1].split(' ').where((s) => s.isNotEmpty).toList();
    final author = parts[2];
    final date = parts[3];
    final subject = parts.sublist(4).join('|');

    commits.add({
      'id': id,
      'parents': parents,
      'refs': [],
      'author': author,
      'date': date,
      'subject': subject,
    });
  }
  return commits;
}

Future<String> _findEffectiveRepoPath(String repoName) async {
  final repoDir = _getBackupDir(repoName);
  print("Searching for repo in: $repoDir");

  // 1. Check if repoDir itself is a git repo
  if (await Directory(p.join(repoDir, '.git')).exists()) {
    return repoDir;
  }

  // 2. Check if repoDir/<repoName>_parent is a git repo
  final parentDir = Directory(p.join(repoDir, '${repoName}_parent'));
  if (await parentDir.exists() && await Directory(p.join(parentDir.path, '.git')).exists()) {
    return parentDir.path;
  }

  // 3. Fallback: Check immediate subdirectories
  final dir = Directory(repoDir);
  if (await dir.exists()) {
      final subs = dir.listSync().whereType<Directory>();
      for(final sub in subs) {
          if (await Directory(p.join(sub.path, '.git')).exists()) {
              return sub.path;
          }
      }
  }

  throw Exception('Parent repository not found in $repoDir');
}

Future<Map<String, dynamic>> getBackupChildGraph(
    String repoName, String commitId) async {
  // Use cached snapshot
  final snapshotPath = p.join(_checkoutBaseDir, repoName, commitId);
  final snapshotDir = Directory(snapshotPath);

  if (!await snapshotDir.exists()) {
    throw Exception('Snapshot not found for $commitId. Try refreshing list.');
  }

  // The snapshot directory contains the child repo contents directly
  // It might be a normal repo (with .git) or bare-ish
  String gitDir = snapshotPath;
  if (await Directory(p.join(snapshotPath, '.git')).exists()) {
    gitDir = p.join(snapshotPath, '.git');
  } else {
    // Check if it looks like a bare repo/embedded git dir
    if (!await File(p.join(snapshotPath, 'HEAD')).exists()) {
      // Maybe inside a subdir?
      final subs = snapshotDir.listSync().whereType<Directory>();
      for (final s in subs) {
        if (await Directory(p.join(s.path, '.git')).exists()) {
          gitDir = p.join(s.path, '.git');
          break;
        }
        // Check for bare repo
        if (await File(p.join(s.path, 'HEAD')).exists() && 
            await File(p.join(s.path, 'config')).exists() && 
            await Directory(p.join(s.path, 'refs')).exists()) {
          gitDir = s.path;
          break;
        }
      }
    }
  }

  return (await _getGraphFromGitDir(gitDir)).toJson();
}

Future<String> getSnapshotPath(String repoName, String commitId) async {
  final snapshotPath = p.join(_checkoutBaseDir, repoName, commitId);
  final snapshotDir = Directory(snapshotPath);
  if (!await snapshotDir.exists()) {
    // Try to ensure it exists? Or just throw
    throw Exception('Snapshot not found for $commitId');
  }
  return snapshotPath;
}

Future<GraphResponse> _getGraphFromGitDir(String gitDir, {int? limit}) async {
  // We can use git --git-dir=... log ...
  // branches
  final branches = await _getBranchesFromGitDir(gitDir);
  final chains =
      await _getBranchChainsFromGitDir(gitDir, branches, limit: limit);
  final current = await _getCurrentBranchFromGitDir(gitDir);
  print("gitDir=$gitDir");
  print("branches=$branches");
  print("current=$current");

  final logArgs = [
    '--git-dir=$gitDir',
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

  final res =
      await Process.run('git', logArgs, stdoutEncoding: utf8);
  if (res.exitCode != 0) throw Exception('Git log failed: ${res.stderr}');

  final lines = LineSplitter.split(res.stdout as String).toList();
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

  return GraphResponse(
      commits: commits,
      branches: branches,
      chains: chains,
      currentBranch: current);
}

Future<List<Branch>> _getBranchesFromGitDir(String gitDir) async {
  final res = await Process.run('git', [
    '--git-dir=$gitDir',
    'for-each-ref',
    '--format=%(refname:short)|%(objectname)',
    'refs/heads',
  ]);
  final lines = LineSplitter.split(res.stdout as String).toList();
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

Future<GraphResponse> getBackupGraph(String repoName, String commitId) async {
  // Use cached snapshot
  final snapshotPath = p.join(_checkoutBaseDir, repoName, commitId);
  final snapshotDir = Directory(snapshotPath);

  if (!await snapshotDir.exists()) {
    throw Exception('Snapshot not found for $commitId. Try refreshing list.');
  }

  // The snapshot directory contains the child repo contents directly
  // It might be a normal repo (with .git) or bare-ish
  String gitDir = snapshotPath;
  if (await Directory(p.join(snapshotPath, '.git')).exists()) {
    gitDir = p.join(snapshotPath, '.git');
  } else {
    // Check if it looks like a bare repo/embedded git dir
    if (!await File(p.join(snapshotPath, 'HEAD')).exists()) {
      // Maybe inside a subdir?
      final subs = snapshotDir.listSync().whereType<Directory>();
      for (final s in subs) {
        if (await Directory(p.join(s.path, '.git')).exists()) {
          gitDir = p.join(s.path, '.git');
          break;
        }
        // Check for bare repo
        if (await File(p.join(s.path, 'HEAD')).exists() && 
            await File(p.join(s.path, 'config')).exists() && 
            await Directory(p.join(s.path, 'refs')).exists()) {
          gitDir = s.path;
          break;
        }
      }
    }
  }

  return _getGraphFromGitDir(gitDir);
}

Future<Map<String, List<String>>> _getBranchChainsFromGitDir(
    String gitDir, List<Branch> branches,
    {int? limit}) async {
  final result = <String, List<String>>{};
  for (final b in branches) {
    final args = [
      '--git-dir=$gitDir',
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
    final res = await Process.run('git', args);
    final lines = LineSplitter.split(res.stdout as String).toList();
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

Future<String?> _getCurrentBranchFromGitDir(String gitDir) async {
  // For bare repo, HEAD might point to a branch
  try {
    final res = await Process.run('git',
        ['--git-dir=$gitDir', 'symbolic-ref', '--short', 'HEAD']);
    if (res.exitCode == 0) return (res.stdout as String).trim();
  } catch (_) {}
  return null;
}

// Copied from git_service.dart
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

Future<List<int>> previewBackupChildDoc(
    String repoName, String commitId) async {
  // Use cached snapshot
  final snapshotPath = p.join(_checkoutBaseDir, repoName, commitId);
  final snapshotDir = Directory(snapshotPath);

  if (!await snapshotDir.exists()) {
    throw Exception('Snapshot not found for $commitId');
  }

  // Find docx in snapshot (it's just a folder now)
  // Recursively search for docx
  final files = snapshotDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => p.extension(f.path).toLowerCase() == '.docx')
      .toList();

  if (files.isEmpty) {
    throw Exception('No docx file found in snapshot');
  }

  final docxPath = files.first.path;

  // Convert
  final tmp = await Directory.systemTemp.createTemp('backup_preview_');
  try {
    // Copy docx to temp
    final inPath = p.join(tmp.path, 'temp.docx');
    await File(docxPath).copy(inPath);

    final scriptPath = p.fromUri(Platform.script);
    final repoRoot = p.dirname(p.dirname(p.dirname(scriptPath)));
    final psScript = p.join(repoRoot, 'frontend', 'lib', 'docx2pdf.ps1');
    final pdfPath = p.join(tmp.path, 'temp.pdf');

    final result = await Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      psScript,
      '-InputPath',
      inPath,
      '-OutputPath',
      pdfPath
    ]);

    if (result.exitCode != 0) {
      throw Exception('Conversion failed: ${result.stderr}');
    }

    if (!await File(pdfPath).exists()) {
      throw Exception('PDF not generated');
    }

    return await File(pdfPath).readAsBytes();
  } finally {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  }
}
