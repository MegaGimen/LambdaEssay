import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'visualize.dart'; // For VisualizeDocxPage
import 'graph_view.dart'; // For SimpleGraphView

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final TextEditingController _repoCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;
  bool _loading = false;
  String? _error;

  List<CommitNode> _commits = [];
  final Map<String, GraphData> _graphs = {};

  static const String backupBase = 'http://localhost:8080';

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
    final repo = _repoCtrl.text.trim();
    if (repo.isEmpty) {
      setState(() => _error = '请输入仓库名称');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _commits = [];
      _graphs.clear();
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

  Future<void> _ensureGraph(String repo, String sha) async {
    if (_graphs.containsKey(sha)) return;
    final url = '$backupBase/backup/graph';
    final resp = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'repoName': repo, 'commitId': sha}),
    );
    if (resp.statusCode != 200) {
      throw Exception('加载图失败: ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final gd = GraphData.fromJson(j);
    setState(() {
      _graphs[sha] = gd;
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

  @override
  Widget build(BuildContext context) {
    final repo = _repoCtrl.text.trim();
    final commits = _filtered();
    return Scaffold(
      appBar: AppBar(title: const Text('历史备份预览')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _repoCtrl,
                    decoration: const InputDecoration(labelText: '仓库名称'),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _loading ? null : _loadBackups,
                  child: const Text('加载备份'),
                ),
                const SizedBox(width: 8),
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
                    itemCount: commits.length,
                    itemBuilder: (ctx, i) {
                      final c = commits[i];
                      final sha = c.id;
                      final hasGraph = _graphs.containsKey(sha);
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
                                  OutlinedButton(
                                    onPressed: repo.isEmpty
                                        ? null
                                        : () => _previewDoc(repo, sha),
                                    child: const Text('预览docx'),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton(
                                    onPressed: repo.isEmpty
                                        ? null
                                        : () async {
                                            try {
                                              await _ensureGraph(repo, sha);
                                            } catch (e) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(SnackBar(
                                                      content:
                                                          Text('加载图失败: $e')));
                                            }
                                          },
                                    child: Text(hasGraph ? '已加载' : '加载图'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (hasGraph)
                                SizedBox(
                                  height: 600,
                                  child: SimpleGraphView(
                                    data: _graphs[sha]!,
                                    readOnly: true,
                                    onPreviewCommit: (commitId) async {
                                      await _previewDoc(repo, commitId);
                                    },
                                  ),
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
