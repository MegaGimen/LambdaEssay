class CommitNode {
  final String id;
  final List<String> parents;
  final List<String> refs;
  final String author;
  final String date;
  final String subject;
  CommitNode({
    required this.id,
    required this.parents,
    required this.refs,
    required this.author,
    required this.date,
    required this.subject,
  });
  factory CommitNode.fromJson(Map<String, dynamic> j) => CommitNode(
        id: j['id'],
        parents: (j['parents'] as List).cast<String>(),
        refs: (j['refs'] as List).cast<String>(),
        author: j['author'],
        date: j['date'],
        subject: j['subject'],
      );
}

class Branch {
  final String name;
  final String head;
  Branch({required this.name, required this.head});
  factory Branch.fromJson(Map<String, dynamic> j) =>
      Branch(name: j['name'], head: j['head']);
}

class EdgeInfo {
  final String child;
  final String parent;
  final List<String> branches;
  final bool isMerge;
  EdgeInfo({
    required this.child,
    required this.parent,
    required this.branches,
    this.isMerge = false,
  });
}

class GraphData {
  final List<CommitNode> commits;
  final List<Branch> branches;
  final Map<String, List<String>> chains;
  final String? currentBranch;
  final List<List<String>> customEdges;
  GraphData({
    required this.commits,
    required this.branches,
    required this.chains,
    this.currentBranch,
    this.customEdges = const [],
  });
  factory GraphData.fromJson(Map<String, dynamic> j) => GraphData(
        commits: ((j['commits'] as List).map(
          (e) => CommitNode.fromJson(e as Map<String, dynamic>),
        )).toList(),
        branches: ((j['branches'] as List).map(
          (e) => Branch.fromJson(e as Map<String, dynamic>),
        )).toList(),
        chains: (j['chains'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as List).cast<String>()),
        ),
        currentBranch: j['currentBranch'],
        customEdges: (j['customEdges'] as List?)
                ?.map((e) => (e as List).cast<String>())
                .toList() ??
            [],
      );
}

class WorkingState {
  final bool changed;
  final String? baseId;
  WorkingState({required this.changed, this.baseId});
}
