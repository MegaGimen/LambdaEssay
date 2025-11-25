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
  Map<String, dynamic> toJson() => {
        'id': id,
        'parents': parents,
        'refs': refs,
        'author': author,
        'date': date,
        'subject': subject,
      };
}

class Branch {
  final String name;
  final String head;
  Branch({required this.name, required this.head});
  Map<String, dynamic> toJson() => {'name': name, 'head': head};
}

class GraphResponse {
  final List<CommitNode> commits;
  final List<Branch> branches;
  final Map<String, List<String>> chains;
  GraphResponse(
      {required this.commits, required this.branches, required this.chains});
  Map<String, dynamic> toJson() => {
        'commits': commits.map((e) => e.toJson()).toList(),
        'branches': branches.map((e) => e.toJson()).toList(),
        'chains': chains,
      };
}
