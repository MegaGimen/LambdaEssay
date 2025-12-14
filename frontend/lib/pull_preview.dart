import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'graph_view.dart';

class PullPreviewPage extends StatefulWidget {
  final String repoName;
  final String username;
  final String token;
  final String type; // rebase, branch, force

  const PullPreviewPage({
    super.key,
    required this.repoName,
    required this.username,
    required this.token,
    required this.type,
  });

  @override
  State<PullPreviewPage> createState() => _PullPreviewPageState();
}

class _PullPreviewPageState extends State<PullPreviewPage> {
  bool _loading = true;
  bool _cancelLoading = false;
  String? _error;
  
  GraphData? _current;
  GraphData? _target;
  GraphData? _result;
  Map<String, int>? _rowMapping;
  bool _hasConflicts = false;
  List<String> _conflictingFiles = [];

  final TransformationController _tc = TransformationController();
  // ignore: unused_field
  bool _graphHovering = false;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    try {
      final url = 'http://localhost:8080/pull/preview';
      final resp = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoName': widget.repoName,
          'username': widget.username,
          'token': widget.token,
          'type': widget.type,
        }),
      );

      if (resp.statusCode != 200) {
        throw Exception(jsonDecode(resp.body)['error']);
      }

      final data = jsonDecode(resp.body);
      
      setState(() {
        _current = GraphData.fromJson(data['current']);
        _target = GraphData.fromJson(data['target']);
        if (data['result'] != null) {
          _result = GraphData.fromJson(data['result']);
        }
        if (data['rowMapping'] != null) {
          _rowMapping = (data['rowMapping'] as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, v as int));
        }
        _hasConflicts = data['hasConflicts'] == true;
        _conflictingFiles = (data['conflictingFiles'] as List?)?.cast<String>() ?? [];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _onCancel() async {
    setState(() {
      _cancelLoading = true;
    });
    try {
      final url = 'http://localhost:8080/pull/cancel';
      await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoName': widget.repoName,
        }),
      );
    } catch (e) {
      print('Cancel failed: $e');
    } finally {
      if (mounted) {
        Navigator.pop(context, false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Pull Preview: ${widget.type.toUpperCase()}'),
      ),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('Error: $_error', style: const TextStyle(color: Colors.red)))
                  : Column(
                      children: [
                        if (_hasConflicts)
                          Container(
                            color: Colors.red.shade100,
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              children: [
                                const Icon(Icons.warning, color: Colors.red),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '检测到冲突！以下文件存在冲突：\n${_conflictingFiles.join(", ")}',
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(child: _buildGraphCol('当前本地 (Current)', _current!)),
                              const VerticalDivider(width: 1),
                              Expanded(child: _buildGraphCol('远程目标 (Target)', _target!)),
                              if (_result != null) ...[
                                 const VerticalDivider(width: 1),
                                 Expanded(child: _buildGraphCol('预览结果 (Result)', _result!)),
                              ]
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton(
                                onPressed: _cancelLoading ? null : _onCancel,
                                child: const Text('取消'),
                              ),
                              const SizedBox(width: 16),
                              ElevatedButton(
                                onPressed: _cancelLoading ? null : () => Navigator.pop(context, true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _hasConflicts ? Colors.orange : Colors.blue,
                                ),
                                child: Text(_hasConflicts ? '存在冲突 (仍要尝试)' : '确认操作'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
          if (_cancelLoading)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      '正在恢复状态...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGraphCol(String title, GraphData data) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: MouseRegion(
            onEnter: (_) => setState(() => _graphHovering = true),
            onExit: (_) => setState(() => _graphHovering = false),
            child: SimpleGraphView(
              data: data,
              readOnly: true,
              transformationController: _tc,
              customRowMapping: _rowMapping,
              showCurrentHead: false,
              showLegend: true,
            ),
          ),
        ),
      ],
    );
  }
}
