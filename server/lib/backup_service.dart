import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'models.dart';

final String _backupBaseUrl = 'http://47.242.109.145:4829';
final String _tempDirName = 'temp_backups';

String _getBackupDir(String repoName) {
  final scriptDir = p.dirname(Platform.script.toFilePath());
  return p.join(p.dirname(scriptDir), _tempDirName, repoName);
}

Future<List<Map<String, dynamic>>> listBackupCommits(String repoName,
    {bool force = false}) async {
  final dirPath = _getBackupDir(repoName);
  final dir = Directory(dirPath);

  if (force && await dir.exists()) {
    await dir.delete(recursive: true);
  }

  if (!await dir.exists()) {
    // Download
    print('Downloading backup for $repoName...');
    final zipUrl = '$_backupBaseUrl/backups/$repoName/download';
    final resp = await http.get(Uri.parse(zipUrl));
    if (resp.statusCode != 200) {
      throw Exception('Failed to download backup: ${resp.statusCode}');
    }

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

    // Cleanup zip
    if (await zipFile.exists()) {
      await zipFile.delete();
    }
  }

  // Check if it is a git repo (the parent repo)
  File? gitDir = File(p.join(dirPath, '.git'));
  print("gitDir=$gitDir");
  if (!gitDir.existsSync() &&
      !Directory(p.join(dirPath, '.git')).existsSync()) {
    print("case1");
    // Check subdirectories (maybe zip created a root folder)
    final subs = dir.listSync().whereType<Directory>().toList();
    print("subs=$subs");
    if (subs.length == 1) {
      final sub = subs.first;
      if (await Directory(p.join(sub.path, '.git')).exists()) {
        return _getCommitsFromDir(sub.path);
      }
    }
    throw Exception('No .git directory found in backup parent repo');
  }
  print("case2 ");
  return _getCommitsFromDir(dirPath);
}

Future<List<Map<String, dynamic>>> _getCommitsFromDir(String repoPath) async {
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
    var stackTrace = StackTrace.current;
    print('调用栈信息：');
    print(stackTrace);
    throw Exception('Git log failed fucked: ${result.stderr}');
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
    return repoDir;
  }
  final subs = Directory(repoDir).listSync().whereType<Directory>().toList();
  print("subs=$subs");
  if (subs.length == 1 &&
      await Directory(p.join(subs.first.path, '.git')).exists()) {
    return subs.first.path;
  }
  throw Exception('Parent repository not found');
}

Future<String> _findChildGitDir(String worktreePath) async {
  final dir = Directory(worktreePath);
  // Search for a subdirectory that looks like a git dir (contains config, HEAD, objects, refs)
  // Since it's a bare repo structure inside a folder
  final candidates = dir.listSync().whereType<Directory>();
  for (final d in candidates) {
    // Ignore .git of the worktree itself (if any, though worktree usually points to main .git)
    if (p.basename(d.path) == '.git') continue;

    if (await File(p.join(d.path, 'HEAD')).exists() &&
        await File(p.join(d.path, 'config')).exists() &&
        await Directory(p.join(d.path, 'objects')).exists() &&
        await Directory(p.join(d.path, 'refs')).exists()) {
      return d.path;
    }
  }
  throw Exception('Child git repository directory not found in snapshot');
}

Future<Map<String, dynamic>> getBackupChildGraph(
    String repoName, String commitId) async {
  final effectiveRepoPath = await _findEffectiveRepoPath(repoName);
  final shortSha = commitId.substring(0, 7);
  final worktreePath = p.join(Directory.systemTemp.path, 'gitbin_worktrees',
      '${repoName}_work_$shortSha');
  final worktreeDir = Directory(worktreePath);

  if (!await worktreeDir.parent.exists()) {
    await worktreeDir.parent.create(recursive: true);
  }

  // 1. Checkout parent commit to worktree
  if (!await worktreeDir.exists()) {
    print('Creating worktree for $commitId...');
    final res = await Process.run(
      'git',
      ['worktree', 'add', '-d', worktreePath, commitId],
      workingDirectory: effectiveRepoPath,
    );
    if (res.exitCode != 0) {
      await Process.run('git', ['worktree', 'prune'],
          workingDirectory: effectiveRepoPath);
      final res2 = await Process.run(
        'git',
        ['worktree', 'add', '-d', worktreePath, commitId],
        workingDirectory: effectiveRepoPath,
      );
      if (res2.exitCode != 0) {
        throw Exception(
            'Failed to create worktree: ${res.stderr} ${res2.stderr}');
      }
    }
  }

  // 2. Find the child repo directory (which is a bare-like folder)
  final childGitDir = await _findChildGitDir(worktreePath);

  // 3. Run git log on that child directory using --git-dir
  // Reusing logic from git_service.dart:getGraph but adapted for bare/git-dir
  return (await _getGraphFromGitDir(childGitDir)).toJson();
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

  final res = await Process.run('git', logArgs, stdoutEncoding: utf8);
  // Fallback encoding logic omitted for brevity, assume UTF8 for now or copy from git_service
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
    final res = await Process.run(
        'git', ['--git-dir=$gitDir', 'symbolic-ref', '--short', 'HEAD']);
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
  final effectiveRepoPath = await _findEffectiveRepoPath(repoName);
  final shortSha = commitId.substring(0, 7);
  final worktreePath = p.join(Directory.systemTemp.path, 'gitbin_worktrees',
      '${repoName}_work_$shortSha');
  print("worktreePath=$worktreePath");
  final worktreeDir = Directory(worktreePath);

  if (!await worktreeDir.parent.exists()) {
    await worktreeDir.parent.create(recursive: true);
  }

  if (!await worktreeDir.exists()) {
    final res = await Process.run(
      'git',
      ['worktree', 'add', '-d', worktreePath, commitId],
      workingDirectory: effectiveRepoPath,
    );
    if (res.exitCode != 0) {
      await Process.run('git', ['worktree', 'prune'],
          workingDirectory: effectiveRepoPath);
      await Process.run(
        'git',
        ['worktree', 'add', '-d', worktreePath, commitId],
        workingDirectory: effectiveRepoPath,
      );
    }
  }

  final childGitDir = await _findChildGitDir(worktreePath);

  // Find docx file in the HEAD of the child repo
  final res = await Process.run('git',
      ['--git-dir=$childGitDir', 'ls-tree', '-r', 'HEAD', '--name-only']);

  if (res.exitCode != 0) {
    throw Exception('Failed to list files in child repo: ${res.stderr}');
  }

  final files = (res.stdout as String)
      .split('\n')
      .where((l) => l.trim().toLowerCase().endsWith('.docx'))
      .toList();
  if (files.isEmpty) {
    throw Exception('No docx file found in child repo snapshot');
  }

  final docxPath = files.first.trim(); // e.g. "mydoc.docx"

  // Read content using git show
  final showRes = await Process.run(
      'git', ['--git-dir=$childGitDir', 'show', 'HEAD:$docxPath'],
      stdoutEncoding: null); // binary output

  if (showRes.exitCode != 0) {
    throw Exception('Failed to read docx: ${showRes.stderr}');
  }

  final docxBytes = showRes.stdout as List<int>;

  // Convert
  final tmp = await Directory.systemTemp.createTemp('backup_preview_');
  try {
    final inPath = p.join(tmp.path, 'temp.docx');
    await File(inPath).writeAsBytes(docxBytes);

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
