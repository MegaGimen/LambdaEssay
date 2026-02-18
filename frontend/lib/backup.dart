import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'graph_view.dart'; // For SimpleGraphView

class BackupPage extends StatefulWidget {
  final String projectName;
  final String repoPath;
  final String token;
  const BackupPage({
    super.key,
    required this.projectName,
    required this.repoPath,
    required this.token,
  });
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _loading = false;
  String? _error;
  bool _graphHovering = false;

  List<CommitNode> _commits = [];
  // Store comparison results for each backup commit vs local
  final Map<String, ComparisonData> _comparisons = {};
  final TransformationController _sharedTc = TransformationController();
  double _uiScale = 1.0;

  static const String backupBase = 'http://localhost:8080';

  @override
  void initState() {
    super.initState();
    // _sharedTc.addListener(_onScaleChanged);
    _loadBackups();
  }

  @override
  void dispose() {
    // _sharedTc.removeListener(_onScaleChanged);
    _sharedTc.dispose();
    super.dispose();
  }

  Future<void> _loadBackups() async {
    final repo = widget.projectName;
    if (repo.isEmpty) {
      setState(() => _error = '项目名称为空');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _commits = [];
      _comparisons.clear();
    });
    try {
      final url = '$backupBase/backup/commits';
        print("The token here is ${widget.token}");
      final resp = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repoName': repo,"token":widget.token}),
      );
      if (resp.statusCode != 200) {
        throw Exception('加载备份失败: ${resp.body}');
      }

      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (j['commits'] as List?) ?? const [];
      final bool cacheHit = j['cacheHit'] == true;
      
      if (cacheHit && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前本地备份已经是最新版 (Cache Hit)')),
        );
      }

      final commits = list
          .map((e) => CommitNode.fromJson(e as Map<String, dynamic>))
          .toList();
      commits.sort((a, b) => b.date.compareTo(a.date));
      setState(() {
        _commits = commits;
        _loading = false;
      });
      for (final c in commits) {
        _ensureComparison(repo, c.id).catchError((e) {
          debugPrint('Failed to load comparison for ${c.id}: $e');
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _ensureComparison(String repo, String sha) async {
    if (_comparisons.containsKey(sha)) return;
    // Call the compare_repos API to get aligned graphs
    final url = '$backupBase/compare_repos';
    final resp = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'repoName': repo,
        'commitA': sha, // Backup commit
        'commitB': 'local', // Local state
        'localPath': widget.repoPath,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('加载对比失败: ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final gA = GraphData.fromJson(j['graphA']);
    final gB = GraphData.fromJson(j['graphB']);
    final rawMapping = j['unifiedRowMapping'] as Map<String, dynamic>;
    final mapping = rawMapping.map((k, v) => MapEntry(k, v as int));
    final summary = j['summary'] as String? ?? '';
    final details = j['details'] as Map<String, dynamic>? ?? {};

    final colors = _computeNodeColors(details);

    // Compute ghosts
    final commitsA = gA.commits.map((c) => c.id).toSet();
    final commitsB = gB.commits.map((c) => c.id).toSet();

    final ghostsA = gB.commits.where((c) => !commitsA.contains(c.id)).toList();
    final ghostsB = gA.commits.where((c) => !commitsB.contains(c.id)).toList();

    if (!mounted) return;
    setState(() {
      _comparisons[sha] =
          ComparisonData(gA, gB, mapping, summary, colors, ghostsA, ghostsB);
    });
  }

  Map<String, Color> _computeNodeColors(Map<String, dynamic> details) {
    final colors = <String, Color>{};
    if (details.isEmpty) return colors;

    final commonBranches = details['commonBranches'] as Map<String, dynamic>?;
    if (commonBranches != null) {
      for (final branchEntry in commonBranches.entries) {
        final info = branchEntry.value as Map<String, dynamic>;
        final comparison = info['comparison'] as Map<String, dynamic>;

        if (comparison.containsKey('ours')) {
          final ours = comparison['ours'] as Map<String, dynamic>;
          final commits = ours['commits'] as List?;
          if (commits != null) {
            for (final id in commits) {
              colors[id.toString()] =
                  Colors.green.shade300; // Unique to A (Backup)
            }
          }
        }

        if (comparison.containsKey('theirs')) {
          final theirs = comparison['theirs'] as Map<String, dynamic>;
          final commits = theirs['commits'] as List?;
          if (commits != null) {
            for (final id in commits) {
              colors[id.toString()] =
                  Colors.blue.shade300; // Unique to B (Local)
            }
          }
        }
      }
    }
    return colors;
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.projectName;
    final commits = _commits;
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          if (keys.contains(LogicalKeyboardKey.controlLeft) ||
              keys.contains(LogicalKeyboardKey.controlRight)) {
            final dy = event.scrollDelta.dy;
            final double delta = dy > 0 ? -0.1 : 0.1;
            final newValue = (_uiScale + delta).clamp(0.5, 2.0);
            setState(() {
              _uiScale = newValue;
            });
          }
        }
      },
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaleFactor: _uiScale),
        child: Stack(
          children: [
            Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF000A3F),
            foregroundColor: Colors.white,
            title: Text('历史备份预览: $repo'),
            actions: [
              SizedBox(
                width: 150,
                child: Slider(
                  value: _uiScale.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  onChanged: (value) {
                    setState(() {
                      _uiScale = value;
                    });
                  },
                ),
              ),
              IconButton(
            onPressed: () {
              _sharedTc.value = Matrix4.identity();
            },
            tooltip: '返回主视角',
            icon: const Icon(Icons.center_focus_strong),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: commits.isEmpty
                ? Center(
                    child: _loading
                        ? const CircularProgressIndicator()
                        : const Text('无数据'))
                : ListView.builder(
                    physics: _graphHovering
                        ? const NeverScrollableScrollPhysics()
                        : const ClampingScrollPhysics(),
                    itemCount: commits.length,
                    itemBuilder: (ctx, i) {
                      final c = commits[i];
                      final sha = c.id;
                      final comparison = _comparisons[sha];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: ExpansionTile(
                          title: Text('时间: ${c.date}',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (comparison != null)
                                    Column(
                                      children: [
                                        Center(
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              // Backup Graph
                                              Column(
                                                children: [
                                                  const Text("备份版本"),
                                                  Container(
                                                    width: 500,
                                                    height: 500,
                                                    decoration: BoxDecoration(
                                                      border: Border.all(
                                                          color: Colors.black),
                                                    ),
                                                    child: MouseRegion(
                                                      onEnter: (_) => setState(() =>
                                                          _graphHovering = true),
                                                      onExit: (_) => setState(() =>
                                                          _graphHovering = false),
                                                      child: SimpleGraphView(
                                                        data: comparison.graphA,
                                                        readOnly: true,
                                                        onPreviewCommit: null,
                                                        transformationController:
                                                            _sharedTc,
                                                        customRowMapping:
                                                            comparison.mapping,
                                                        customNodeColors:
                                                            comparison.colors,
                                                        ghostNodes:
                                                            comparison.ghostsA,
                                                        showCurrentHead: false,
                                                        totalRows: comparison.mapping.length,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(width: 20),
                                              // Local Graph
                                              Column(
                                                children: [
                                                  const Text("当前本地状态"),
                                                  Container(
                                                    width: 500,
                                                    height: 500,
                                                    decoration: BoxDecoration(
                                                      border: Border.all(
                                                          color: Colors.black),
                                                    ),
                                                    child: MouseRegion(
                                                      onEnter: (_) => setState(() =>
                                                          _graphHovering = true),
                                                      onExit: (_) => setState(() =>
                                                          _graphHovering = false),
                                                      child: SimpleGraphView(
                                                        data: comparison.graphB,
                                                        readOnly: true,
                                                        transformationController:
                                                            _sharedTc,
                                                        customRowMapping:
                                                            comparison.mapping,
                                                        customNodeColors:
                                                            comparison.colors,
                                                        ghostNodes:
                                                            comparison.ghostsB,
                                                        showCurrentHead: false,
                                                        totalRows: comparison.mapping.length,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    )
                                  else
                                    const SizedBox(
                                      height: 100,
                                      child: Center(
                                          child: CircularProgressIndicator()),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
        if (_loading)
          const Opacity(
            opacity: 0.5,
            child: ModalBarrier(dismissible: false, color: Colors.black),
          ),
        if (_loading)
          const Center(child: CircularProgressIndicator()),
      ],
    ),),);
  }
}

class ComparisonData {
  final GraphData graphA;
  final GraphData graphB;
  final Map<String, int> mapping;
  final String summary;
  final Map<String, Color> colors;
  final List<CommitNode> ghostsA;
  final List<CommitNode> ghostsB;
  ComparisonData(this.graphA, this.graphB, this.mapping, this.summary,
      this.colors, this.ghostsA, this.ghostsB);
}
