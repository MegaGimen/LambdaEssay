import 'dart:async';

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
  final String? upstream;
  Branch({required this.name, required this.head, this.upstream});
  Map<String, dynamic> toJson() =>
      {'name': name, 'head': head, 'upstream': upstream};

  static String encodeName(String text) {
    StringBuffer sb = StringBuffer();
    for (int i = 0; i < text.runes.length; i++) {
      int charCode = text.runes.elementAt(i);
      if (charCode > 127) {
        sb.write('_u${charCode.toRadixString(16).padLeft(4, '0')}');
      } else if (charCode == 32) {
        // Replace space with dash for Gitea/Git compatibility
        sb.write('-');
      } else {
        sb.write(String.fromCharCode(charCode));
      }
    }
    return sb.toString();
  }

  static String decodeName(String text) {
    try {
      return text.replaceAllMapped(RegExp(r'_u([0-9a-fA-F]{4})'), (match) {
        return String.fromCharCode(int.parse(match.group(1)!, radix: 16));
      });
    } catch (e) {
      return text;
    }
  }

  String get displayName => decodeName(name);
}

class GraphResponse {
  final List<CommitNode> commits;
  final List<Branch> branches;
  final List<Branch> remoteBranches;
  final Map<String, List<String>> chains;
  final String? currentBranch;
  final List<List<String>> customEdges;
  GraphResponse(
      {required this.commits,
      required this.branches,
      this.remoteBranches = const [],
      required this.chains,
      this.currentBranch,
      this.customEdges = const []});
  Map<String, dynamic> toJson() => {
        'commits': commits.map((e) => e.toJson()).toList(),
        'branches': branches.map((e) => e.toJson()).toList(),
        'remoteBranches': remoteBranches.map((e) => e.toJson()).toList(),
        'chains': chains,
        'currentBranch': currentBranch,
        'customEdges': customEdges,
      };
}
