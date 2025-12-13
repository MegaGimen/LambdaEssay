import '../models.dart';
import '../git_service.dart';
import '../backup_service.dart';
import 'dart:io';
import 'dart:convert';

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

  // 创建临时目录
  final tempDir = await Directory.systemTemp.createTemp('git_compare_');
  try {
    Directory.current = tempDir.path;
    await Process.run('git', ['init']);
    
    // 添加远程仓库
    await Process.run('git', ['remote', 'add', 'repoA', repoAPath]);
    await Process.run('git', ['remote', 'add', 'repoB', repoBPath]);
    
    await Process.run('git', ['fetch', '--all']);
    
    // 获取所有分支
    final branchesA = await _getAllBranches('repoA/');
    final branchesB = await _getAllBranches('repoB/');
    
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
    Directory.current = tempDir.parent.path;
    await tempDir.delete(recursive: true);
  }
  
  return result;
}

/// 比较两个分支的历史
Future<Map<String, dynamic>> _compareBranchHistory({
  required String branchName,
  required String commitA,
  required String commitB,
}) async {
  final result = <String, dynamic>{
    'branch': branchName,
    'commitA': commitA,
    'commitB': commitB,
    'comparison': <String, dynamic>{},
  };
  
  // 1. 找到共同祖先（merge base）
  final mergeBaseResult = await Process.run(
    'git',
    ['merge-base', 'repoA/$branchName', 'repoB/$branchName'],
  );
  
  String? mergeBase;
  if (mergeBaseResult.exitCode == 0) {
    mergeBase = mergeBaseResult.stdout.toString().trim();
  }
  
  if (mergeBase != null && mergeBase.isNotEmpty) {
    result['mergeBase'] = mergeBase;
    
    // 2. 比较从共同祖先到A分支的差异（OURS）
    final diffOurs = await Process.run(
      'git',
      ['diff', '--stat', mergeBase, 'repoA/$branchName'],
    );
    
    // 3. 比较从共同祖先到B分支的差异（THEIRS）
    final diffTheirs = await Process.run(
      'git',
      ['diff', '--stat', mergeBase, 'repoB/$branchName'],
    );
    
    // 4. 获取两个分支的历史差异
    final historyDiff = await Process.run(
      'git',
      ['log', '--graph', '--oneline', '--left-right', '--boundary', 
       'repoA/$branchName...repoB/$branchName'],
    );
    
    // 5. 获取冲突的文件列表（即两个分支都修改的文件）
    final conflictFiles = await Process.run(
      'git',
      ['diff', '--name-only', 'repoA/$branchName', 'repoB/$branchName'],
    );
    
    // 6. 获取提交数量和列表
    final commitsOurs = await Process.run(
      'git',
      ['rev-list', '$mergeBase..repoA/$branchName'],
    );
    
    final commitsTheirs = await Process.run(
      'git',
      ['rev-list', '$mergeBase..repoB/$branchName'],
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
        'files': await _getChangedFiles(mergeBase, 'repoA/$branchName'),
      },
      'theirs': {
        'stat': diffTheirs.exitCode == 0 ? diffTheirs.stdout.toString().trim() : '',
        'commitCount': commitsTheirs.exitCode == 0 
            ? commitsTheirs.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty).length 
            : 0,
        'commits': commitsTheirs.exitCode == 0 
            ? commitsTheirs.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty).toList()
            : [],
        'files': await _getChangedFiles(mergeBase, 'repoB/$branchName'),
      },
      'history': historyDiff.exitCode == 0 ? historyDiff.stdout.toString().trim() : '',
      'conflictFiles': conflictFiles.exitCode == 0 
          ? conflictFiles.stdout.toString().trim().split('\n').where((f) => f.isNotEmpty).toList()
          : [],
      'relationship': await _getBranchRelationship(mergeBase, 'repoA/$branchName', 'repoB/$branchName'),
    };
  } else {
    // 没有共同祖先，是完全不同的分支
    result['comparison'] = {
      'noCommonAncestor': true,
      'oursStat': await _getFullBranchStat('repoA/$branchName'),
      'theirsStat': await _getFullBranchStat('repoB/$branchName'),
      'history': await _getSeparateLogs('repoA/$branchName', 'repoB/$branchName'),
    };
  }
  
  return result;
}

/// 获取分支关系
Future<String> _getBranchRelationship(String base, String branchA, String branchB) async {
  // 检查A分支是否包含B分支
  final containsB = await Process.run(
    'git',
    ['merge-base', '--is-ancestor', branchB, branchA],
  );
  
  // 检查B分支是否包含A分支
  final containsA = await Process.run(
    'git',
    ['merge-base', '--is-ancestor', branchA, branchB],
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
Future<List<String>> _getChangedFiles(String base, String commit) async {
  final result = await Process.run(
    'git',
    ['diff', '--name-only', base, commit],
  );
  
  if (result.exitCode == 0) {
    return result.stdout.toString().trim().split('\n').where((f) => f.isNotEmpty).toList();
  }
  return [];
}

/// 获取分支的完整统计
Future<String> _getFullBranchStat(String branch) async {
  final result = await Process.run(
    'git',
    ['log', '--oneline', '--stat', '--no-merges', branch],
  );
  
  if (result.exitCode == 0) {
    final output = result.stdout.toString().trim();
    final lines = output.split('\n');
    return lines.length > 10 ? lines.sublist(0, 10).join('\n') + '\n...' : output;
  }
  return '';
}

/// 获取两个独立分支的日志
Future<String> _getSeparateLogs(String branchA, String branchB) async {
  final logA = await Process.run('git', ['log', '--oneline', '-5', branchA]);
  final logB = await Process.run('git', ['log', '--oneline', '-5', branchB]);
  
  return '仓库A的 $branchA:\n${logA.stdout.toString().trim()}\n\n仓库B的 $branchB:\n${logB.stdout.toString().trim()}';
}

/// 获取所有分支
Future<Map<String, Map<String, String>>> _getAllBranches(String remotePrefix) async {
  final branches = <String, Map<String, String>>{};
  
  try {
    final output = await Process.run(
      'git',
      ['for-each-ref', '--format=%(refname:short) %(objectname) %(contents:subject)', 
       'refs/remotes/$remotePrefix'],
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
    final output = await Process.run('git', ['branch', '-r']);
    for (final line in output.stdout.toString().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.contains('->') || !trimmed.startsWith(remotePrefix)) continue;
      
      final branchName = trimmed.substring(remotePrefix.length);
      final commitResult = await Process.run('git', ['rev-parse', trimmed]);
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
  // 1. Collect all commits
  final allCommits = <CommitNode>{};
  final byId = <String, CommitNode>{};

  for (final c in a.commits) {
    allCommits.add(c);
    byId[c.id] = c;
  }
  for (final c in b.commits) {
    if (!byId.containsKey(c.id)) {
      allCommits.add(c);
      byId[c.id] = c;
    }
  }

  // 2. Sort by date desc
  final sorted = allCommits.toList()
    ..sort((x, y) {
      return y.date.compareTo(x.date);
    });

  // 3. Assign rows
  final mapping = <String, int>{};
  for (var i = 0; i < sorted.length; i++) {
    mapping[sorted[i].id] = i;
  }

  return ComparisonResult(
    graphA: a,
    graphB: b,
    unifiedRowMapping: mapping,
    summary: summary,
    details: details,
  );
}
