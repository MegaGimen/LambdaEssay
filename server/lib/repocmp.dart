import 'models.dart';
import 'git_service.dart';
import 'backup_service.dart';

class ComparisonResult {
  final GraphResponse graphA;
  final GraphResponse graphB;
  final Map<String, int> unifiedRowMapping;

  ComparisonResult({
    required this.graphA,
    required this.graphB,
    required this.unifiedRowMapping,
  });

  Map<String, dynamic> toJson() => {
        'graphA': graphA.toJson(),
        'graphB': graphB.toJson(),
        'unifiedRowMapping': unifiedRowMapping,
      };
}

Future<ComparisonResult> compareRepos(
    String repoName, String commitA, String commitB) async {
  // Fetch Graph A
  GraphResponse graphA;
  if (commitA == 'local') {
    throw Exception("Use compareReposWithLocal instead");
  } else {
    // It's a backup commit
    graphA = await getBackupGraph(repoName, commitA);
  }

  // Fetch Graph B
  GraphResponse graphB;
  if (commitB == 'local') {
    throw Exception("Use compareReposWithLocal instead");
  } else {
    graphB = await getBackupGraph(repoName, commitB);
  }

  return computeComparison(graphA, graphB);
}

Future<ComparisonResult> compareReposWithLocal(
    String repoName, String? localPath, String commitA, String commitB) async {
  
  GraphResponse graphA;
  if (commitA == 'local') {
    if (localPath == null) throw Exception("Local path required for local comparison");
    graphA = await getGraph(localPath, limit: 100); // Limit for performance?
  } else {
    graphA = await getBackupGraph(repoName, commitA);
  }

  GraphResponse graphB;
  if (commitB == 'local') {
    if (localPath == null) throw Exception("Local path required for local comparison");
    graphB = await getGraph(localPath, limit: 100);
  } else {
    graphB = await getBackupGraph(repoName, commitB);
  }

  return computeComparison(graphA, graphB);
}

ComparisonResult computeComparison(GraphResponse a, GraphResponse b) {
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
      // Simple string comparison for ISO dates works
      return y.date.compareTo(x.date);
    });

  // 3. Assign rows
  // Simple strategy: Just use the sorted index as the row.
  // This ensures that if a commit exists in both, it gets the same row index (because it's the same commit in the sorted list).
  // This is a naive topological sort but often sufficient for visual alignment of time-based graphs.
  final mapping = <String, int>{};
  for (var i = 0; i < sorted.length; i++) {
    mapping[sorted[i].id] = i;
  }

  return ComparisonResult(
    graphA: a,
    graphB: b,
    unifiedRowMapping: mapping,
  );
}
