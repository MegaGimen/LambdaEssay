import '../models.dart';
import '../git_service.dart';
import '../backup_service.dart';
import 'dart:io';
// import 'dart:convert';
import 'package:path/path.dart' as p;

/// 比较两个Git仓库的差异，包括分支历史
Future<Map<String, dynamic>> compareGitRepos({
  required String repoAPath,
  required String repoBPath,
}) async {
  final result = <String, dynamic>{
    'repoA': repoAPath,
    'repoB': repoBPath,
    'commonBranches': <String, dynamic>{},
    'onlyInA': <String>[],
    'onlyInB': <String>[],
    'summary': '',
  };

  if (!await Directory(repoAPath).exists() || !await Directory(repoBPath).exists()) {
    throw Exception('仓库路径不存在');
  }

  // 获取Git绝对路径
  final gitPath = p.absolute('git');

  // 创建临时目录
  final tempDir = await Directory.systemTemp.createTemp('git_compare_');
  try {
    // Directory.current = tempDir.path; // DO NOT CHANGE GLOBAL CWD
    final workingDir = tempDir.path;

    await Process.run(gitPath, ['init'], workingDirectory: workingDir);
    
    // 添加远程仓库
    await Process.run(gitPath, ['remote', 'add', 'repoA', repoAPath], workingDirectory: workingDir);
    await Process.run(gitPath, ['remote', 'add', 'repoB', repoBPath], workingDirectory: workingDir);
    
    await Process.run(gitPath, ['fetch', '--all'], workingDirectory: workingDir);
    
    // 获取所有分支
    final branchesA = await _getAllBranches('repoA/', gitPath, workingDir);
    final branchesB = await _getAllBranches('repoB/', gitPath, workingDir);
    
    final commonBranches = result['commonBranches'] as Map<String, dynamic>;
    final onlyInA = result['onlyInA'] as List<String>;
    final onlyInB = result['onlyInB'] as List<String>;
    
    for (final branch in {...branchesA.keys, ...branchesB.keys}) {
      final branchA = branchesA[branch];
      final branchB = branchesB[branch];
      
      if (branchA != null && branchB != null) {
        // 详细比较分支历史
        final branchComparison = await _compareBranchHistory(
          branchName: branch,
          commitA: branchA['commit']!,
          commitB: branchB['commit']!,
          gitPath: gitPath,
          workingDir: workingDir,
        );
        commonBranches[branch] = branchComparison;
      } else if (branchA != null) {
        onlyInA.add(branch);
      } else {
        onlyInB.add(branch);
      }
    }
    
    result['summary'] = _generateSummary(result);
    
  } finally {
    // Directory.current = tempDir.parent.path;
    await tempDir.delete(recursive: true);
  }
  
  return result;
}

/// 比较两个分支的历史
Future<Map<String, dynamic>> _compareBranchHistory({
  required String branchName,
  required String commitA,
  required String commitB,
  required String gitPath,
  required String workingDir,
}) async {
  final result = <String, dynamic>{
    'branch': branchName,
    'commitA': commitA,
    'commitB': commitB,
    'comparison': <String, dynamic>{},
  };
  
  // 1. 找到共同祖先（merge base）
  final mergeBaseResult = await Process.run(
    gitPath,
    ['merge-base', 'repoA/$branchName', 'repoB/$branchName'],
    workingDirectory: workingDir,
  );
  
  String? mergeBase;
  if (mergeBaseResult.exitCode == 0) {
    mergeBase = mergeBaseResult.stdout.toString().trim();
  }
  
  if (mergeBase != null && mergeBase.isNotEmpty) {
    result['mergeBase'] = mergeBase;
    
    // 2. 比较从共同祖先到A分支的差异（OURS）
    final diffOurs = await Process.run(
      gitPath,
      ['diff', '--stat', mergeBase, 'repoA/$branchName'],
      workingDirectory: workingDir,
    );
    
    // 3. 比较从共同祖先到B分支的差异（THEIRS）
    final diffTheirs = await Process.run(
      gitPath,
      ['diff', '--stat', mergeBase, 'repoB/$branchName'],
      workingDirectory: workingDir,
    );
    
    // 4. 获取两个分支的历史差异
    final historyDiff = await Process.run(
      gitPath,
      ['log', '--graph', '--oneline', '--left-right', '--boundary', 
       'repoA/$branchName...repoB/$branchName'],
      workingDirectory: workingDir,
    );
    
    // 5. 获取冲突的文件列表（即两个分支都修改的文件）
    final conflictFiles = await Process.run(
      gitPath,
      ['diff', '--name-only', 'repoA/$branchName', 'repoB/$branchName'],
      workingDirectory: workingDir,
    );
    
    // 6. 获取提交数量和列表
    final commitsOurs = await Process.run(
      gitPath,
      ['rev-list', '$mergeBase..repoA/$branchName'],
      workingDirectory: workingDir,
    );
    
    final commitsTheirs = await Process.run(
      gitPath,
      ['rev-list', '$mergeBase..repoB/$branchName'],
      workingDirectory: workingDir,
    );
    
    result['comparison'] = {
      'mergeBase': mergeBase,
      'ours': {
        'stat': diffOurs.exitCode == 0 ? diffOurs.stdout.toString().trim() : '',
        'commitCount': commitsOurs.exitCode == 0 
            ? commitsOurs.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty).length 
            : 0,
        'commits': commitsOurs.exitCode == 0 
            ? commitsOurs.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty).toList()
            : [],
        'files': await _getChangedFiles(mergeBase, 'repoA/$branchName', gitPath, workingDir),
      },
      'theirs': {
        'stat': diffTheirs.exitCode == 0 ? diffTheirs.stdout.toString().trim() : '',
        'commitCount': commitsTheirs.exitCode == 0 
            ? commitsTheirs.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty).length 
            : 0,
        'commits': commitsTheirs.exitCode == 0 
            ? commitsTheirs.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty).toList()
            : [],
        'files': await _getChangedFiles(mergeBase, 'repoB/$branchName', gitPath, workingDir),
      },
      'history': historyDiff.exitCode == 0 ? historyDiff.stdout.toString().trim() : '',
      'conflictFiles': conflictFiles.exitCode == 0 
          ? conflictFiles.stdout.toString().trim().split('\n').where((f) => f.isNotEmpty).toList()
          : [],
      'relationship': await _getBranchRelationship(mergeBase, 'repoA/$branchName', 'repoB/$branchName', gitPath, workingDir),
    };
  } else {
    // 没有共同祖先，是完全不同的分支
    result['comparison'] = {
      'noCommonAncestor': true,
      'oursStat': await _getFullBranchStat('repoA/$branchName', gitPath, workingDir),
      'theirsStat': await _getFullBranchStat('repoB/$branchName', gitPath, workingDir),
      'history': await _getSeparateLogs('repoA/$branchName', 'repoB/$branchName', gitPath, workingDir),
    };
  }
  
  return result;
}

/// 获取分支关系
Future<String> _getBranchRelationship(String base, String branchA, String branchB, String gitPath, String workingDir) async {
  // 检查A分支是否包含B分支
  final containsB = await Process.run(
    gitPath,
    ['merge-base', '--is-ancestor', branchB, branchA],
    workingDirectory: workingDir,
  );
  
  // 检查B分支是否包含A分支
  final containsA = await Process.run(
    gitPath,
    ['merge-base', '--is-ancestor', branchA, branchB],
    workingDirectory: workingDir,
  );
  
  if (containsB.exitCode == 0) {
    return '$branchA 包含 $branchB 的所有提交';
  } else if (containsA.exitCode == 0) {
    return '$branchB 包含 $branchA 的所有提交';
  } else {
    return '两个分支有分叉，需要合并';
  }
}

/// 获取从base到commit之间修改的文件
Future<List<String>> _getChangedFiles(String base, String commit, String gitPath, String workingDir) async {
  final result = await Process.run(
    gitPath,
    ['diff', '--name-only', base, commit],
    workingDirectory: workingDir,
  );
  
  if (result.exitCode == 0) {
    return result.stdout.toString().trim().split('\n').where((f) => f.isNotEmpty).toList();
  }
  return [];
}

/// 获取分支的完整统计
Future<String> _getFullBranchStat(String branch, String gitPath, String workingDir) async {
  final result = await Process.run(
    gitPath,
    ['log', '--oneline', '--stat', '--no-merges', branch],
    workingDirectory: workingDir,
  );
  
  if (result.exitCode == 0) {
    final output = result.stdout.toString().trim();
    final lines = output.split('\n');
    return lines.length > 10 ? lines.sublist(0, 10).join('\n') + '\n...' : output;
  }
  return '';
}

/// 获取两个独立分支的日志
Future<String> _getSeparateLogs(String branchA, String branchB, String gitPath, String workingDir) async {
  final logA = await Process.run(gitPath, ['log', '--oneline', '-5', branchA], workingDirectory: workingDir);
  final logB = await Process.run(gitPath, ['log', '--oneline', '-5', branchB], workingDirectory: workingDir);
  
  return '仓库A的 $branchA:\n${logA.stdout.toString().trim()}\n\n仓库B的 $branchB:\n${logB.stdout.toString().trim()}';
}

/// 获取所有分支
Future<Map<String, Map<String, String>>> _getAllBranches(String remotePrefix, String gitPath, String workingDir) async {
  final branches = <String, Map<String, String>>{};
  
  try {
    final output = await Process.run(
      gitPath,
      ['for-each-ref', '--format=%(refname:short) %(objectname) %(contents:subject)', 
       'refs/remotes/$remotePrefix'],
       workingDirectory: workingDir,
    );
    
    for (final line in output.stdout.toString().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      
      final parts = trimmed.split(' ');
      if (parts.length >= 3) {
        final fullRef = parts[0];
        if (fullRef.startsWith(remotePrefix)) {
          final branchName = fullRef.substring(remotePrefix.length);
          branches[branchName] = {
            'commit': parts[1],
            'message': parts.sublist(2).join(' '),
            'full_ref': fullRef,
          };
        }
      }
    }
  } catch (e) {
    // 回退到branch -r
    final output = await Process.run(gitPath, ['branch', '-r'], workingDirectory: workingDir);
    for (final line in output.stdout.toString().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.contains('->') || !trimmed.startsWith(remotePrefix)) continue;
      
      final branchName = trimmed.substring(remotePrefix.length);
      final commitResult = await Process.run(gitPath, ['rev-parse', trimmed], workingDirectory: workingDir);
      if (commitResult.exitCode == 0) {
        branches[branchName] = {
          'commit': commitResult.stdout.toString().trim(),
          'message': '',
          'full_ref': trimmed,
        };
      }
    }
  }
  
  return branches;
}

/// 生成摘要
String _generateSummary(Map<String, dynamic> result) {
  final buffer = StringBuffer();
  final commonBranches = result['commonBranches'] as Map<String, dynamic>;
  final onlyInA = result['onlyInA'] as List<String>;
  final onlyInB = result['onlyInB'] as List<String>;
  
  buffer.writeln('Git仓库分支历史比较');
  buffer.writeln('=' * 60);
  buffer.writeln('仓库A: ${result['repoA']}');
  buffer.writeln('仓库B: ${result['repoB']}');
  buffer.writeln();
  buffer.writeln('分支统计:');
  buffer.writeln('  - 共同分支: ${commonBranches.length} 个');
  buffer.writeln('  - 只在仓库A: ${onlyInA.length} 个');
  buffer.writeln('  - 只在仓库B: ${onlyInB.length} 个');
  buffer.writeln();
  
  if (commonBranches.isNotEmpty) {
    for (final entry in commonBranches.entries) {
      final branch = entry.key;
      final info = entry.value as Map<String, dynamic>;
      final comparison = info['comparison'] as Map<String, dynamic>;
      
      buffer.writeln('分支: $branch');
      buffer.writeln('-' * 40);
      buffer.writeln('仓库A提交: ${info['commitA']}');
      buffer.writeln('仓库B提交: ${info['commitB']}');
      buffer.writeln();
      
      if (comparison.containsKey('noCommonAncestor')) {
        buffer.writeln('⚠️ 警告: 没有共同祖先，是完全独立的分支');
        buffer.writeln('仓库A修改统计:');
        buffer.writeln(comparison['oursStat']);
        buffer.writeln();
        buffer.writeln('仓库B修改统计:');
        buffer.writeln(comparison['theirsStat']);
      } else {
        buffer.writeln('共同祖先: ${comparison['mergeBase']}');
        buffer.writeln();
        
        // 显示OURS和THEIRS
        final ours = comparison['ours'] as Map<String, dynamic>;
        final theirs = comparison['theirs'] as Map<String, dynamic>;
        
        buffer.writeln('OURS (从共同祖先到仓库A的修改):');
        buffer.writeln('  提交数量: ${ours['commitCount']}');
        if ((ours['stat'] as String).isNotEmpty) {
          buffer.writeln('  文件修改: ${ours['stat']}');
        }
        if ((ours['files'] as List).isNotEmpty) {
          buffer.writeln('  修改的文件:');
          for (final file in ours['files'] as List) {
            buffer.writeln('    - $file');
          }
        }
        buffer.writeln();
        
        buffer.writeln('THEIRS (从共同祖先到仓库B的修改):');
        buffer.writeln('  提交数量: ${theirs['commitCount']}');
        if ((theirs['stat'] as String).isNotEmpty) {
          buffer.writeln('  文件修改: ${theirs['stat']}');
        }
        if ((theirs['files'] as List).isNotEmpty) {
          buffer.writeln('  修改的文件:');
          for (final file in theirs['files'] as List) {
            buffer.writeln('    - $file');
          }
        }
        buffer.writeln();
        
        // 分支关系
        buffer.writeln('分支关系: ${comparison['relationship']}');
        buffer.writeln();
        
        // 冲突文件
        final conflictFiles = comparison['conflictFiles'] as List;
        if (conflictFiles.isNotEmpty) {
          buffer.writeln('⚠️ 潜在冲突文件 (两个分支都修改了):');
          for (final file in conflictFiles) {
            buffer.writeln('  - $file');
          }
          buffer.writeln();
        }
        
        // 历史图
        if ((comparison['history'] as String).isNotEmpty) {
          buffer.writeln('提交历史图:');
          buffer.writeln(comparison['history']);
        }
      }
      
      buffer.writeln('=' * 60);
      buffer.writeln();
    }
  }
  
  if (onlyInA.isNotEmpty) {
    buffer.writeln('只在仓库A中的分支:');
    for (final branch in onlyInA) {
      buffer.writeln('  - $branch');
    }
    buffer.writeln();
  }
  
  if (onlyInB.isNotEmpty) {
    buffer.writeln('只在仓库B中的分支:');
    for (final branch in onlyInB) {
      buffer.writeln('  - $branch');
    }
  }
  
  return buffer.toString();
}

class ComparisonResult {
  final GraphResponse graphA;
  final GraphResponse graphB;
  final Map<String, int> unifiedRowMapping;
  final String summary;
  final Map<String, dynamic> details;

  ComparisonResult({
    required this.graphA,
    required this.graphB,
    required this.unifiedRowMapping,
    this.summary = '',
    this.details = const {},
  });

  Map<String, dynamic> toJson() => {
        'graphA': graphA.toJson(),
        'graphB': graphB.toJson(),
        'unifiedRowMapping': unifiedRowMapping,
        'summary': summary,
        'details': details,
      };
}

Future<ComparisonResult> compareReposWithLocal(
    String repoName, String? localPath, String commitA, String commitB) async {
  
  GraphResponse graphA;
  String pathA;
  if (commitA == 'local') {
    if (localPath == null) throw Exception("Local path required for local comparison");
    pathA = localPath;
    graphA = await getGraph(localPath, limit: 100);
  } else {
    pathA = await getSnapshotPath(repoName, commitA);
    graphA = await getBackupGraph(repoName, commitA);
  }

  GraphResponse graphB;
  String pathB;
  if (commitB == 'local') {
    if (localPath == null) throw Exception("Local path required for local comparison");
    pathB = localPath;
    graphB = await getGraph(localPath, limit: 100);
  } else {
    pathB = await getSnapshotPath(repoName, commitB);
    graphB = await getBackupGraph(repoName, commitB);
  }

  // Run the detailed git comparison
  String summary = '';
  Map<String, dynamic> details = {};
  try {
    details = await compareGitRepos(repoAPath: pathA, repoBPath: pathB);
    summary = details['summary'] as String;
  } catch (e) {
    print('Detailed comparison failed: $e');
    summary = '无法生成详细对比: $e';
  }

  return computeComparison(graphA, graphB, summary, details);
}

ComparisonResult computeComparison(GraphResponse a, GraphResponse b, String summary, Map<String, dynamic> details) {
  final ordered = _buildUnifiedOrder(a, b);
  final mapping = <String, int>{};
  for (var i = 0; i < ordered.length; i++) {
    mapping[ordered[i].id] = i;
  }

  return ComparisonResult(
    graphA: a,
    graphB: b,
    unifiedRowMapping: mapping,
    summary: summary,
    details: details,
  );
}

List<CommitNode> _buildUnifiedOrder(GraphResponse a, GraphResponse b) {
  final byId = <String, CommitNode>{};
  for (final c in a.commits) {
    byId[c.id] = c;
  }
  for (final c in b.commits) {
    byId.putIfAbsent(c.id, () => c);
  }

  final adj = <String, Set<String>>{};
  final indeg = <String, int>{};
  for (final id in byId.keys) {
    adj[id] = <String>{};
    indeg[id] = 0;
  }

  void addEdge(String from, String to) {
    if (from == to) return;
    final set = adj[from]!;
    if (set.add(to)) {
      indeg[to] = (indeg[to] ?? 0) + 1;
    }
  }

  for (var i = 0; i + 1 < a.commits.length; i++) {
    addEdge(a.commits[i].id, a.commits[i + 1].id);
  }
  for (var i = 0; i + 1 < b.commits.length; i++) {
    addEdge(b.commits[i].id, b.commits[i + 1].id);
  }

  int compareId(String x, String y) {
    final dx = byId[x]?.date ?? '';
    final dy = byId[y]?.date ?? '';
    final d = dy.compareTo(dx);
    if (d != 0) return d;
    return y.compareTo(x);
  }

  final remaining = <String>{...byId.keys};
  final zero = remaining.where((id) => indeg[id] == 0).toList()..sort(compareId);
  final ordered = <CommitNode>[];

  while (remaining.isNotEmpty) {
    if (zero.isEmpty) {
      final rest = remaining.toList()..sort(compareId);
      zero.add(rest.first);
    }
    final id = zero.removeAt(0);
    if (!remaining.remove(id)) {
      continue;
    }
    ordered.add(byId[id]!);
    for (final next in adj[id]!) {
      indeg[next] = (indeg[next] ?? 0) - 1;
      if (indeg[next] == 0) {
        zero.add(next);
      }
    }
    zero.sort(compareId);
  }

  return ordered;
}
