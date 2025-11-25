import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const GitGraphApp());
}

class GitGraphApp extends StatelessWidget {
  const GitGraphApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Git Graph',
      theme: ThemeData.light(),
      home: const GraphPage(),
    );
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

class GraphData {
  final List<CommitNode> commits;
  final List<Branch> branches;
  GraphData({required this.commits, required this.branches});
  factory GraphData.fromJson(Map<String, dynamic> j) => GraphData(
        commits: ((j['commits'] as List).map(
          (e) => CommitNode.fromJson(e as Map<String, dynamic>),
        )).toList(),
        branches: ((j['branches'] as List).map(
          (e) => Branch.fromJson(e as Map<String, dynamic>),
        )).toList(),
      );
}

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});
  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  final TextEditingController pathCtrl = TextEditingController();
  final TextEditingController limitCtrl = TextEditingController(text: '500');
  GraphData? data;
  String? error;
  bool loading = false;

  Future<void> _load() async {
    final path = pathCtrl.text.trim();
    final limit = int.tryParse(limitCtrl.text.trim());
    if (path.isEmpty) {
      setState(() => error = '请输入本地仓库路径');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/graph'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repoPath': path, 'limit': limit}),
      );
      if (resp.statusCode != 200) {
        setState(() {
          error = '后端错误: ${resp.body}';
          loading = false;
        });
        return;
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final gd = GraphData.fromJson(j);
      setState(() {
        data = gd;
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Git Graph 可视化')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: pathCtrl,
                    decoration: const InputDecoration(
                      labelText: '本地仓库路径 c:\\path\\to\\repo',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: limitCtrl,
                    decoration: const InputDecoration(labelText: '最近提交数'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: loading ? null : _load,
                  child: const Text('加载'),
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: data == null
                ? const Center(child: Text('输入路径并点击加载'))
                : _GraphView(data: data!),
          ),
        ],
      ),
    );
  }
}

class _GraphView extends StatefulWidget {
  final GraphData data;
  const _GraphView({required this.data});
  @override
  State<_GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<_GraphView> {
  final TransformationController _tc = TransformationController();
  CommitNode? _hovered;
  Offset? _hoverPos;
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MouseRegion(
          onHover: (d) {
            final scene = _toScene(d.localPosition);
            final hit = _hitTest(scene, widget.data);
            setState(() {
              _hovered = hit;
              _hoverPos = d.localPosition;
            });
          },
          onExit: (_) {
            setState(() {
              _hovered = null;
              _hoverPos = null;
            });
          },
          child: GestureDetector(
            onTapUp: (d) {
              final scene = _toScene(d.localPosition);
              final hit = _hitTest(scene, widget.data);
              if (hit != null) {
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(hit.subject),
                    content: Text(
                        'commit ${hit.id}\n${hit.author}\n${hit.date}\nparents: ${hit.parents.join(', ')}'),
                  ),
                );
              }
            },
            child: InteractiveViewer(
              transformationController: _tc,
              minScale: 0.2,
              maxScale: 4,
              child: CustomPaint(
                painter: GraphPainter(widget.data),
                size: Size.infinite,
              ),
            ),
          ),
        ),
        if (_hovered != null && _hoverPos != null)
          Positioned(
            left: _hoverPos!.dx + 12,
            top: _hoverPos!.dy + 12,
            child: Material(
              elevation: 2,
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFAFA),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 6),
                  ],
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(color: Colors.black, fontSize: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_hovered!.subject),
                      const SizedBox(height: 4),
                      Text('${_hovered!.author}  ${_hovered!.date}'),
                      const SizedBox(height: 4),
                      Text('parents: ${_hovered!.parents.join(', ')}'),
                      Text('commit: ${_hovered!.id.substring(0, 7)}'),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Offset _toScene(Offset p) {
    final inv = _tc.value.clone()..invert();
    return MatrixUtils.transformPoint(inv, p);
  }

  CommitNode? _hitTest(Offset sceneP, GraphData data) {
    const laneWidth = GraphPainter.laneWidth;
    const rowHeight = GraphPainter.rowHeight;
    final commits = data.commits;
    final laneOf = <String, int>{};
    final activeLaneHead = <int, String>{};
    final rowOf = <String, int>{};
    for (var i = 0; i < commits.length; i++) {
      final c = commits[i];
      rowOf[c.id] = i;
      int? laneCandidate;
      for (final e in activeLaneHead.entries) {
        if (c.parents.contains(e.value)) {
          laneCandidate = e.key;
          break;
        }
      }
      final lane = laneCandidate ?? _firstFreeLane(activeLaneHead);
      laneOf[c.id] = lane;
      activeLaneHead[lane] = c.id;
      for (final e in activeLaneHead.entries.toList()) {
        if (c.parents.contains(e.value) && e.key != lane) {
          activeLaneHead.remove(e.key);
        }
      }
    }
    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2;
      final y = row * rowHeight + rowHeight / 2;
      final dx = sceneP.dx - x;
      final dy = sceneP.dy - y;
      if ((dx * dx + dy * dy) <=
          (GraphPainter.nodeRadius * GraphPainter.nodeRadius * 4)) {
        return c;
      }
    }
    return null;
  }

  int _firstFreeLane(Map<int, String> activeLaneHead) {
    var lane = 0;
    while (activeLaneHead.containsKey(lane)) {
      lane++;
    }
    return lane;
  }
}

class GraphPainter extends CustomPainter {
  final GraphData data;
  GraphPainter(this.data);
  static const double laneWidth = 80;
  static const double rowHeight = 50;
  static const double nodeRadius = 6;
  static const List<Color> lanePalette = [
    Color(0xFF1976D2),
    Color(0xFF2E7D32),
    Color(0xFF8E24AA),
    Color(0xFFD81B60),
    Color(0xFF00838F),
    Color(0xFF5D4037),
    Color(0xFF3949AB),
    Color(0xFFF9A825),
    Color(0xFF6D4C41),
    Color(0xFF1E88E5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final commits = data.commits;
    final laneOf = <String, int>{};
    final activeLaneHead = <int, String>{};
    final rowOf = <String, int>{};
    final paintNode = Paint();
    final paintEdge = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < commits.length; i++) {
      final c = commits[i];
      rowOf[c.id] = i;
      int? laneCandidate;
      for (final e in activeLaneHead.entries) {
        if (c.parents.contains(e.value)) {
          laneCandidate = e.key;
          break;
        }
      }
      final lane = laneCandidate ?? _firstFreeLane(activeLaneHead);
      laneOf[c.id] = lane;
      activeLaneHead[lane] = c.id;
      for (final e in activeLaneHead.entries.toList()) {
        if (c.parents.contains(e.value) && e.key != lane) {
          activeLaneHead.remove(e.key);
        }
      }
    }

    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2;
      final y = row * rowHeight + rowHeight / 2;
      paintNode.color = lanePalette[lane % lanePalette.length];
      canvas.drawCircle(Offset(x, y), nodeRadius, paintNode);
      for (final p in c.parents) {
        if (!rowOf.containsKey(p)) continue;
        final pr = rowOf[p]!;
        final pl = laneOf[p] ?? lane;
        final px = pl * laneWidth + laneWidth / 2;
        final py = pr * rowHeight + rowHeight / 2;
        final path = Path();
        path.moveTo(x, y);
        final midY = (y + py) / 2;
        path.cubicTo(x, midY, px, midY, px, py);
        paintEdge.color = lanePalette[pl % lanePalette.length];
        canvas.drawPath(path, paintEdge);
      }
    }

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2 + 10;
      final y = row * rowHeight + rowHeight / 2 - 8;
      final label = c.id.substring(0, 7) +
          (c.refs.isNotEmpty ? ' [' + c.refs.first + ']' : '');
      textPainter.text = TextSpan(
        text: label,
        style: const TextStyle(color: Colors.black, fontSize: 12),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x, y));
    }
  }

  int _chooseLane(CommitNode c, Map<int, String> activeLaneHead) {
    for (final entry in activeLaneHead.entries) {
      if (c.parents.contains(entry.value)) {
        return entry.key;
      }
    }
    var lane = 0;
    while (activeLaneHead.containsKey(lane)) {
      lane++;
    }
    return lane;
  }

  static int _chooseLaneStatic(CommitNode c, Map<int, String> activeLaneHead) {
    for (final entry in activeLaneHead.entries) {
      if (c.parents.contains(entry.value)) {
        return entry.key;
      }
    }
    var lane = 0;
    while (activeLaneHead.containsKey(lane)) {
      lane++;
    }
    return lane;
  }

  int _firstFreeLane(Map<int, String> activeLaneHead) {
    var lane = 0;
    while (activeLaneHead.containsKey(lane)) {
      lane++;
    }
    return lane;
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}
