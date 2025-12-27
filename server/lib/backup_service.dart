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

final String _backupBaseUrl = 'http://47.242.109.145:4829';
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
  // New logic for pre-exploded snapshots
  final dir = Directory(repoPath);
  if (await dir.exists()) {
    final entities = dir.listSync();
    final snapshotDirs = entities.whereType<Directory>().where((d) {
      return p.basename(d.path).contains('_son-');
    }).toList();
    print(
        "On executing _precacheSnapshots with param snapshotDirs=$snapshotDirs");
    if (snapshotDirs.isNotEmpty) {
      print('Found ${snapshotDirs.length} snapshots.');
      final checkoutRoot = Directory(p.join(_checkoutBaseDir, repoName));
      if (!await checkoutRoot.exists()) {
        await checkoutRoot.create(recursive: true);
      }

      for (final d in snapshotDirs) {
        final name = p.basename(d.path);
        final parts = name.split('_son-');
        if (parts.length < 2) continue;
        final commitId = parts.last;

        final targetDir = Directory(p.join(checkoutRoot.path, commitId));
        if (await targetDir.exists()) {
          await targetDir.delete(recursive: true);
        }

        try {
          await d.rename(targetDir.path);
        } catch (e) {
          await Process.run('powershell', [
            '-Command',
            'Copy-Item -Path "${d.path}" -Destination "${targetDir.path}" -Recurse -Force'
          ]);
          await d.delete(recursive: true);
        }

        await Process.run('bin/mingw64/bin/git.exe', ['init', '--bare', '.'],
            workingDirectory: targetDir.path);
      }
      return;
    }
  }

  /*
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

  final checkoutRoot = Directory(p.join(_checkoutBaseDir, repoName));
  if (!await checkoutRoot.exists()) {
    await checkoutRoot.create(recursive: true);
  }

  for (final commitId in commits) {
    final targetDir = Directory(p.join(checkoutRoot.path, commitId));
    if (await targetDir.exists()) {
      // Skip if already cached
      continue;
    }

    print('Caching snapshot for $commitId...');
    print("repoPath=$repoPath");
    // Checkout commit in the parent repo
    final checkoutRes = await Process.run('git', ['checkout', '-f', commitId],
        workingDirectory: repoPath);
    if (checkoutRes.exitCode != 0) {
      print('Failed to checkout $commitId: ${checkoutRes.stderr}');
      continue;
    }

    // Identify child directory in the checked out state
    // We scan subdirectories for a git repo
    String? childPath;
    final parentDir = Directory(repoPath);
    // Be careful not to pick .git folder of parent
    await for (final entity in parentDir.list(recursive: false)) {
      if (entity is Directory) {
        if (p.basename(entity.path) == '.git') continue;

        // Check if this directory looks like a git repo (bare or normal)
        // Normal: has .git subdirectory
        // Bare-ish/Embedded: has HEAD, config, objects, refs
        if (await Directory(p.join(entity.path, '.git')).exists()) {
          childPath = entity.path; // Normal repo structure
          break;
        } else if (await File(p.join(entity.path, 'HEAD')).exists() &&
            await File(p.join(entity.path, 'config')).exists() &&
            await Directory(p.join(entity.path, 'objects')).exists()) {
          print("bare");
          childPath = entity.path; // Bare/Embedded structure
          break;
        }
      }
    }

    if (childPath != null) {
      // Copy childPath to targetDir
      // Using PowerShell for robust recursive copy
      await targetDir.create(recursive: true);
      final copyRes = await Process.run('powershell', [
        '-Command',
        'Copy-Item -Path "${childPath}\\*" -Destination "${targetDir.path}" -Recurse -Force'
      ]);
      print("copied ${childPath} to ${targetDir.path}");
      final childPath_hashRes = await Process.run('powershell', ['-Command', 'hash-files "${childPath}"']);
if (childPath_hashRes.exitCode != 0) {
  stderr.writeln("hash-files 执行失败 (childPath): ${childPath_hashRes.stderr.toString()}");
  throw Exception("hash-files 命令失败，退出码: ${childPath_hashRes.exitCode}");
}
final childPathstdoutOutput = childPath_hashRes.stdout.toString();

final targetDir_hashRes = await Process.run('powershell', ['-Command', 'hash-files "${targetDir.path}"']);
if (targetDir_hashRes.exitCode != 0) {
  stderr.writeln("hash-files 执行失败 (targetDir): ${targetDir_hashRes.stderr.toString()}");
  throw Exception("hash-files 命令失败，退出码: ${targetDir_hashRes.exitCode}");
}
final targetDirstdoutOutput = targetDir_hashRes.stdout.toString();

final childoutputFile = File('${Directory.current.path}/child${commitId}.txt');
final targetoutputFile = File('${Directory.current.path}/target${commitId}.txt');

await childoutputFile.writeAsString(childPathstdoutOutput);
await targetoutputFile.writeAsString(targetDirstdoutOutput);
      if (copyRes.exitCode != 0) {
        print('Failed to copy snapshot for $commitId: ${copyRes.stderr}');
      }
    } else {
      print('No child repo found in commit $commitId');
    }
  }

  //Restore master
  //await Process.run('git', ['checkout', '-f', 'master'],
  //  workingDirectory: repoPath);
  */
}

Future<List<Map<String, dynamic>>> _getCommitsFromDir(
    String repoPath, String repoName) async {
  print("Execute _getCommitsFromDir with param repoPath=$repoPath");
  // Check for cached snapshots first (Snapshot Mode)
  final cachedRepoDir = Directory(p.join(_checkoutBaseDir, repoName));
  if (await cachedRepoDir.exists()) {
    print("cachedRepoDir.exists");
    final subs = cachedRepoDir.listSync().whereType<Directory>().toList();
    if (subs.isNotEmpty) {
      // We are in snapshot mode
      final commits = <Map<String, dynamic>>[];
      for (final d in subs) {
        final id = p.basename(d.path);
        commits.add({
          'id': id,
          'parents': [],
          'refs': [],
          'author': 'Snapshot',
          'date': DateTime.now().toIso8601String(),
          'subject': 'Snapshot $id',
        });
      }
      return commits;
    }
  }

  final result = await Process.run(
    'bin/mingw64/bin/git.exe',
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
  print("repodir=$repoDir");
  if (await Directory(p.join(repoDir, '.git')).exists()) {
    print(1);
    return repoDir;
  }

  // Check if we have already cached snapshots in _checkoutBaseDir
  final checkoutDir = Directory(p.join(_checkoutBaseDir, repoName));
  if (await checkoutDir.exists() && checkoutDir.listSync().isNotEmpty) {
    print(2);
    print(checkoutDir);
    return p.join(repoDir, repoName); // Who the fuck writes this piece of shit
  }

  // Check if we have snapshot folders (pre-exploded)
  final dir = Directory(repoDir);
  if (await dir.exists()) {
    final subs = dir.listSync().whereType<Directory>();
    if (subs.any((d) => p.basename(d.path).contains('_son-'))) {
      print(3);
      return repoDir;
    }
  }

  final subs = Directory(repoDir).listSync().whereType<Directory>().toList();
  print("subs=$subs");
  if (subs.length == 1) {
    return subs.first.path;
  }
  throw Exception('Parent repository not found');
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

  final res = await Process.run('bin/mingw64/bin/git.exe', logArgs, stdoutEncoding: utf8);
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
    final res = await Process.run('bin/mingw64/bin/git.exe', args);
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
    final res = await Process.run(
        'bin/mingw64/bin/git.exe', ['--git-dir=$gitDir', 'symbolic-ref', '--short', 'HEAD']);
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
