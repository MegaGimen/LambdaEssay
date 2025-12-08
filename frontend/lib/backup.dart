import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'visualize.dart'; // For VisualizeDocxPage
import 'graph_view.dart'; // For SimpleGraphView

class BackupPage extends StatefulWidget {
  final String projectName;
  final String repoPath;
  const BackupPage({
    super.key,
    required this.projectName,
    required this.repoPath,
  });
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final TextEditingController _authorCtrl = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;
  bool _loading = false;
  String? _error;
  bool _graphHovering = false;

  List<CommitNode> _commits = [];
  // Store comparison results for each backup commit vs local
  final Map<String, ComparisonData> _comparisons = {};
  final TransformationController _sharedTc = TransformationController();

  bool _compareMode = false;
  final Set<String> _selectedCommits = {};

  static const String backupBase = 'http://localhost:8080';

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _startDate = d);
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _endDate = d);
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
      final resp = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repoName': repo, 'force': false}),
      );
      if (resp.statusCode != 200) {
        throw Exception('加载备份失败: ${resp.body}');
      }

      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (j['commits'] as List?) ?? const [];
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

  List<CommitNode> _filtered() {
    return _commits.where((c) {
      if (_authorCtrl.text.isNotEmpty) {
        if (!c.author.toLowerCase().contains(_authorCtrl.text.toLowerCase())) {
          return false;
        }
      }
      if (_startDate != null) {
        final d = DateTime.tryParse(c.date);
        if (d != null && d.isBefore(_startDate!)) return false;
      }
      if (_endDate != null) {
        final d = DateTime.tryParse(c.date);
        if (d != null && d.isAfter(_endDate!.add(const Duration(days: 1)))) {
          return false;
        }
      }
      return true;
    }).toList();
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

    if (!mounted) return;
    setState(() {
      _comparisons[sha] = ComparisonData(gA, gB, mapping);
    });
  }

  Future<void> _previewDoc(String repo, String sha) async {
    try {
      final url = '$backupBase/backup/preview';
      final resp = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repoName': repo, 'commitId': sha}),
      );
      if (resp.statusCode != 200) {
        throw Exception('预览失败: ${resp.body}');
      }
      final bytes = resp.bodyBytes;
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VisualizeDocxPage(
            initialBytes: bytes,
            title: '预览: ${sha.substring(0, 7)}',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('预览失败: $e')));
    }
  }

  Future<void> _compareTwoCommits() async {
    if (_selectedCommits.length != 2) return;
    final ids = _selectedCommits.toList();
    final cA = ids[0];
    final cB = ids[1];

    setState(() => _loading = true);
    try {
      final resp = await http.post(
        Uri.parse('$backupBase/compare_repos'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoName': widget.projectName,
          'commitA': cA,
          'commitB': cB,
          'localPath': widget.repoPath,
        }),
      );

      setState(() => _loading = false);
      if (resp.statusCode != 200) {
        throw Exception('对比失败: ${resp.body}');
      }

      final j = jsonDecode(resp.body);
      final gA = GraphData.fromJson(j['graphA']);
      final gB = GraphData.fromJson(j['graphB']);
      final rawMapping = j['unifiedRowMapping'] as Map<String, dynamic>;
      final mapping = rawMapping.map((k, v) => MapEntry(k, v as int));

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CompareResultPage(
            graphA: gA,
            graphB: gB,
            rowMapping: mapping,
            title: '对比: ${cA.substring(0, 7)} vs ${cB.substring(0, 7)}',
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.projectName;
    final commits = _filtered();
    return Scaffold(
      appBar: AppBar(
        title: Text('历史备份预览: $repo'),
        actions: [
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
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _authorCtrl,
                    decoration: const InputDecoration(labelText: '作者筛选'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _pickStart,
                  child: Text(
                    _startDate == null
                        ? '起始时间'
                        : _startDate!.toIso8601String().substring(0, 10),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _pickEnd,
                  child: Text(
                    _endDate == null
                        ? '结束时间'
                        : _endDate!.toIso8601String().substring(0, 10),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _compareMode = !_compareMode;
                      _selectedCommits.clear();
                    });
                  },
                  icon: Icon(_compareMode ? Icons.close : Icons.compare_arrows),
                  label: Text(_compareMode ? '退出对比' : '仓库比较'),
                ),
                if (_compareMode && _selectedCommits.length == 2) ...[
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _compareTwoCommits,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                    child: const Text('开始比较'),
                  ),
                ],
              ],
            ),
          ),
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
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (_compareMode)
                                    Checkbox(
                                      value: _selectedCommits.contains(sha),
                                      onChanged: (v) {
                                        setState(() {
                                          if (v == true) {
                                            if (_selectedCommits.length >= 2) return;
                                            _selectedCommits.add(sha);
                                          } else {
                                            _selectedCommits.remove(sha);
                                          }
                                        });
                                      },
                                    ),
                                  Text(
                                    '${c.id.substring(0, 7)}  ${c.subject}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(width: 12),
                                  Text('作者: ${c.author}'),
                                  const SizedBox(width: 12),
                                  Text('时间: ${c.date}'),
                                  const Spacer(),
                                  const SizedBox(width: 8),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (comparison != null)
                                Center(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      // Backup Graph
                                      Column(
                                        children: [
                                          const Text("备份版本"),
                                          Container(
                                            width: 500,
                                            height: 500,
                                            decoration: BoxDecoration(
                                              border: Border.all(color: Colors.black),
                                            ),
                                            child: MouseRegion(
                                              onEnter: (_) => setState(() => _graphHovering = true),
                                              onExit: (_) => setState(() => _graphHovering = false),
                                              child: SimpleGraphView(
                                                data: comparison.graphA,
                                                readOnly: true,
                                                onPreviewCommit: null,
                                                transformationController: _sharedTc,
                                                customRowMapping: comparison.mapping,
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
                                              border: Border.all(color: Colors.black),
                                            ),
                                            child: MouseRegion(
                                              onEnter: (_) => setState(() => _graphHovering = true),
                                              onExit: (_) => setState(() => _graphHovering = false),
                                              child: SimpleGraphView(
                                                data: comparison.graphB,
                                                readOnly: true,
                                                transformationController: _sharedTc,
                                                customRowMapping: comparison.mapping,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                )
                              else
                                const SizedBox(
                                  height: 100,
                                  child: Center(child: CircularProgressIndicator()),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class CompareResultPage extends StatefulWidget {
  final GraphData graphA;
  final GraphData graphB;
  final Map<String, int> rowMapping;
  final String title;

  const CompareResultPage({
    super.key,
    required this.graphA,
    required this.graphB,
    required this.rowMapping,
    required this.title,
  });

  @override
  State<CompareResultPage> createState() => _CompareResultPageState();
}

class _CompareResultPageState extends State<CompareResultPage> {
  final TransformationController _tc = TransformationController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(
                children: [
                  const Text("Commit A"),
                  Container(
                    width: 600,
                    height: 800,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black),
                    ),
                    child: SimpleGraphView(
                      data: widget.graphA,
                      readOnly: true,
                      transformationController: _tc,
                      customRowMapping: widget.rowMapping,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 20),
              Column(
                children: [
                  const Text("Commit B"),
                  Container(
                    width: 600,
                    height: 800,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black),
                    ),
                    child: SimpleGraphView(
                      data: widget.graphB,
                      readOnly: true,
                      transformationController: _tc,
                      customRowMapping: widget.rowMapping,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ComparisonData {
  final GraphData graphA;
  final GraphData graphB;
  final Map<String, int> mapping;
  ComparisonData(this.graphA, this.graphB, this.mapping);
}
