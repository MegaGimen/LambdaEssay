import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
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

class EdgeInfo {
  final String child;
  final String parent;
  final List<String> branches;
  EdgeInfo({required this.child, required this.parent, required this.branches});
}

class GraphData {
  final List<CommitNode> commits;
  final List<Branch> branches;
  final Map<String, List<String>> chains;
  GraphData(
      {required this.commits, required this.branches, required this.chains});
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
      data = null;
    });
    try {
      await http.post(
        Uri.parse('http://localhost:8080/reset'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch}),
      );
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
  bool _rightPanActive = false;
  Offset? _rightPanLast;
  DateTime? _rightPanStart;
  Map<String, Color>? _branchColors;
  Map<String, List<String>>? _pairBranches;
  Size? _canvasSize;
  double _laneWidth = 120;
  double _rowHeight = 160;
  static const Duration _rightPanDelay = Duration(milliseconds: 200);

  void _resetView() {
    setState(() {
      _tc.value = Matrix4.identity();
      _hovered = null;
      _hoverPos = null;
      _hoverEdge = null;
    });
  }

  @override
  void didUpdateWidget(covariant _GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _branchColors = null;
      _pairBranches = null;
      _canvasSize = null;
      _hovered = null;
      _hoverPos = null;
      _hoverEdge = null;
      _tc.value = Matrix4.identity();
      _rightPanActive = false;
      _rightPanLast = null;
      _rightPanStart = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _branchColors ??= _assignBranchColors(widget.data.branches);
    _pairBranches ??= _buildPairBranches(widget.data);
    _canvasSize ??= _computeCanvasSize(widget.data);
    return Stack(
      children: [
        MouseRegion(
          onHover: (d) {
            final scene = _toScene(d.localPosition);
            final hit = _hitTest(scene, widget.data);
            EdgeInfo? ehit;
            if (hit == null) {
              ehit = _hitEdge(scene, widget.data);
            }
            setState(() {
              _hovered = hit;
              _hoverPos = d.localPosition;
              _hoverEdge = ehit;
            });
          },
          onExit: (_) {
            setState(() {
              _hovered = null;
              _hoverPos = null;
              _hoverEdge = null;
            });
          },
          child: Listener(
            onPointerDown: (e) {
              if (e.buttons & kSecondaryMouseButton != 0) {
                _rightPanStart = DateTime.now();
                _rightPanLast = e.localPosition;
                _rightPanActive = false;
              }
            },
            onPointerMove: (e) {
              if (e.buttons & kSecondaryMouseButton != 0 &&
                  _rightPanLast != null) {
                final now = DateTime.now();
                if (!_rightPanActive &&
                    _rightPanStart != null &&
                    now.difference(_rightPanStart!) >= _rightPanDelay) {
                  _rightPanActive = true;
                }
                if (_rightPanActive) {
                  final delta = e.localPosition - _rightPanLast!;
                  final m = _tc.value.clone();
                  m.translate(delta.dx, delta.dy);
                  _tc.value = m;
                  _rightPanLast = e.localPosition;
                }
              }
            },
            onPointerUp: (e) {
              _rightPanActive = false;
              _rightPanLast = null;
              _rightPanStart = null;
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
                constrained: false,
                boundaryMargin: const EdgeInsets.all(2000),
                child: SizedBox(
                  width: _canvasSize!.width,
                  height: _canvasSize!.height,
                  child: CustomPaint(
                    painter: GraphPainter(widget.data, _branchColors!,
                        _hoverEdgeKey(), _laneWidth, _rowHeight),
                    size: _canvasSize!,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          top: 80,
          child: Material(
            elevation: 2,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFDFDFD),
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(color: Color(0x22000000), blurRadius: 4)
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _resetView,
                        icon: const Icon(Icons.home),
                        label: const Text('返回主视角'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('间距调整',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('节点间距'),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 180,
                        child: Slider(
                          min: 40,
                          max: 160,
                          divisions: 24,
                          value: _rowHeight,
                          label: _rowHeight.round().toString(),
                          onChanged: (v) {
                            setState(() {
                              _rowHeight = v;
                              _canvasSize = _computeCanvasSize(widget.data);
                            });
                          },
                        ),
                      ),
                      Text(_rowHeight.round().toString()),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('分支间距'),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 180,
                        child: Slider(
                          min: 60,
                          max: 200,
                          divisions: 28,
                          value: _laneWidth,
                          label: _laneWidth.round().toString(),
                          onChanged: (v) {
                            setState(() {
                              _laneWidth = v;
                              _canvasSize = _computeCanvasSize(widget.data);
                            });
                          },
                        ),
                      ),
                      Text(_laneWidth.round().toString()),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('分支图例',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  for (final b in widget.data.branches)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: _branchColors![b.name]!,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(b.name),
                        ],
                      ),
                    ),
                  if (_hasUnknownEdges())
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                  color: Color(0xFF9E9E9E),
                                  shape: BoxShape.circle),
                            ),
                          ),
                          SizedBox(width: 6),
                          Text('其它'),
                        ],
                      ),
                    ),
                ],
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
        if (_hoverEdge != null && _hoverPos != null && _hovered == null)
          Positioned(
            left: _hoverPos!.dx + 12,
            top: _hoverPos!.dy + 12,
            child: Material(
              elevation: 2,
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFAFA),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 6)
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        '${_hoverEdge!.child.substring(0, 7)} → ${_hoverEdge!.parent.substring(0, 7)}'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _hoverEdge!.branches
                          .map((b) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: (_branchColors?[b] ??
                                          const Color(0xFF9E9E9E))
                                      .withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: _branchColors?[b] ??
                                          const Color(0xFF9E9E9E)),
                                ),
                                child: Text(b,
                                    style: const TextStyle(fontSize: 12)),
                              ))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  EdgeInfo? _hoverEdge;

  Offset _toScene(Offset p) {
    final inv = _tc.value.clone()..invert();
    return MatrixUtils.transformPoint(inv, p);
  }

  Size _computeCanvasSize(GraphData data) {
    final laneWidth = _laneWidth;
    final rowHeight = _rowHeight;
    final commits = data.commits;
    final laneOf = _laneOfByBranches(data);
    var maxLane = -1;
    for (final v in laneOf.values) {
      if (v > maxLane) maxLane = v;
    }
    if (maxLane < 0) maxLane = 0;
    final w = (maxLane + 1) * laneWidth + 400;
    final h = commits.length * rowHeight + 400;
    return Size(w.toDouble(), h.toDouble());
  }

  Map<String, Color> _assignBranchColors(List<Branch> branches) {
    final palette = GraphPainter.lanePalette;
    final map = <String, Color>{};
    for (var i = 0; i < branches.length; i++) {
      map[branches[i].name] = palette[i % palette.length];
    }
    return map;
  }

  Map<String, List<String>> _buildPairBranches(GraphData data) {
    final map = <String, List<String>>{};
    for (final entry in data.chains.entries) {
      final b = entry.key;
      final ids = entry.value;
      for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        final key = '$child|$parent';
        final list = map[key] ??= <String>[];
        if (!list.contains(b)) list.add(b);
      }
    }
    return map;
  }

  String? _hoverEdgeKey() {
    final e = _hoverEdge;
    if (e == null) return null;
    return '${e.child}|${e.parent}';
  }

  bool _hasUnknownEdges() {
    final names = widget.data.branches.map((b) => b.name).toSet();
    final byId = {for (final c in widget.data.commits) c.id: c};
    bool unknown = false;
    for (final c in widget.data.commits) {
      String? bn;
      // direct ref
      for (final r in c.refs) {
        if (names.contains(r)) {
          bn = r;
          break;
        }
        if (r.startsWith('origin/')) {
          final short = r.substring('origin/'.length);
          if (names.contains(short)) {
            bn = short;
            break;
          }
        }
      }
      // walk first-parents up to 100 steps
      var cur = c;
      var steps = 0;
      while (bn == null && cur.parents.isNotEmpty && steps < 100) {
        final p = byId[cur.parents.first];
        if (p == null) break;
        for (final r in p.refs) {
          if (names.contains(r)) {
            bn = r;
            break;
          }
          if (r.startsWith('origin/')) {
            final short = r.substring('origin/'.length);
            if (names.contains(short)) {
              bn = short;
              break;
            }
          }
        }
        cur = p;
        steps++;
      }
      if (bn == null) {
        unknown = true;
        break;
      }
    }
    return unknown;
  }

  CommitNode? _hitTest(Offset sceneP, GraphData data) {
    final laneWidth = _laneWidth;
    final rowHeight = _rowHeight;
    final commits = data.commits;
    final laneOf = _laneOfByBranches(data);
    final rowOf = <String, int>{};
    for (var i = 0; i < commits.length; i++) {
      rowOf[commits[i].id] = i;
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

  Map<String, int> _branchLane(List<Branch> branches) {
    final ordered = List<Branch>.from(branches);
    ordered.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });
    final map = <String, int>{};
    for (var i = 0; i < ordered.length; i++) {
      map[ordered[i].name] = i;
    }
    return map;
  }

  Map<String, int> _laneOfByBranches(GraphData data) {
    final laneOf = <String, int>{};
    final branchLane = _branchLane(data.branches);
    final orderedNames = branchLane.keys.toList()
      ..sort((a, b) {
        int pa = a == 'master' ? 0 : 1;
        int pb = b == 'master' ? 0 : 1;
        if (pa != pb) return pa - pb;
        return a.compareTo(b);
      });
    for (final name in orderedNames) {
      final lane = branchLane[name]!;
      final ids = data.chains[name] ?? const <String>[];
      for (final id in ids) {
        laneOf[id] ??= lane;
      }
    }
    for (final c in data.commits) {
      if (laneOf[c.id] != null) continue;
      int? lane;
      for (final p in c.parents) {
        final lp = laneOf[p];
        if (lp != null) {
          lane = lp;
          break;
        }
      }
      final laneVal = lane ?? branchLane.length;
      laneOf[c.id] = laneVal;
    }
    return laneOf;
  }

  EdgeInfo? _hitEdge(Offset sceneP, GraphData data) {
    final laneWidth = _laneWidth;
    final rowHeight = _rowHeight;
    final commits = data.commits;
    final laneOf = _laneOfByBranches(data);
    final rowOf = <String, int>{};
    for (var i = 0; i < commits.length; i++) {
      rowOf[commits[i].id] = i;
    }
    if (_pairBranches == null) return null;
    double best = double.infinity;
    EdgeInfo? bestInfo;
    for (final entry in _pairBranches!.entries) {
      final key = entry.key;
      final sp = key.split('|');
      if (sp.length != 2) continue;
      final child = sp[0];
      final parent = sp[1];
      if (!rowOf.containsKey(child) || !rowOf.containsKey(parent)) continue;
      final rowC = rowOf[child]!;
      final laneC = laneOf[child]!;
      final x = laneC * laneWidth + laneWidth / 2;
      final y = rowC * rowHeight + rowHeight / 2;
      final rowP = rowOf[parent]!;
      final laneP = laneOf[parent]!;
      final px = laneP * laneWidth + laneWidth / 2;
      final py = rowP * rowHeight + rowHeight / 2;
      final dLane = (laneC - laneP).abs();
      var bendBase = (dLane * 8.0).clamp(8.0, 24.0);
      bendBase += _obstacleCount(child, parent, laneOf, rowOf) * 16.0;
      final dir = laneC <= laneP ? 1.0 : -1.0;
      final c1 = Offset(x + dir * bendBase, (y + py) / 2);
      final c2 = Offset(px - dir * bendBase, (y + py) / 2);
      final d = _distToCubic(sceneP, Offset(x, y), c1, c2, Offset(px, py));
      if (d < best) {
        best = d;
        bestInfo =
            EdgeInfo(child: child, parent: parent, branches: entry.value);
      }
    }
    if (bestInfo != null && best <= 8.0) return bestInfo;
    return null;
  }

  double _distToCubic(Offset p, Offset a, Offset c1, Offset c2, Offset b) {
    const steps = 24;
    Offset prev = a;
    double minD = double.infinity;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final pt = _cubicPoint(a, c1, c2, b, t);
      final d = _distPointToSegment(p, prev, pt);
      if (d < minD) minD = d;
      prev = pt;
    }
    return minD;
  }

  Offset _cubicPoint(Offset a, Offset c1, Offset c2, Offset b, double t) {
    final mt = 1 - t;
    final x = mt * mt * mt * a.dx +
        3 * mt * mt * t * c1.dx +
        3 * mt * t * t * c2.dx +
        t * t * t * b.dx;
    final y = mt * mt * mt * a.dy +
        3 * mt * mt * t * c1.dy +
        3 * mt * t * t * c2.dy +
        t * t * t * b.dy;
    return Offset(x, y);
  }

  double _distPointToSegment(Offset p, Offset a, Offset b) {
    final abx = b.dx - a.dx;
    final aby = b.dy - a.dy;
    final apx = p.dx - a.dx;
    final apy = p.dy - a.dy;
    final ab2 = abx * abx + aby * aby;
    double t = ab2 == 0 ? 0 : (apx * abx + apy * aby) / ab2;
    if (t < 0)
      t = 0;
    else if (t > 1) t = 1;
    final cx = a.dx + t * abx;
    final cy = a.dy + t * aby;
    final dx = p.dx - cx;
    final dy = p.dy - cy;
    return math.sqrt(dx * dx + dy * dy);
  }

  int _obstacleCount(String child, String parent, Map<String, int> laneOf,
      Map<String, int> rowOf) {
    final rc = rowOf[child]!;
    final rp = rowOf[parent]!;
    final lc = laneOf[child]!;
    final lp = laneOf[parent]!;
    final rmin = math.min(rc, rp);
    final rmax = math.max(rc, rp);
    final lmin = math.min(lc, lp);
    final lmax = math.max(lc, lp);
    var cnt = 0;
    for (final e in rowOf.entries) {
      final id = e.key;
      if (id == child || id == parent) continue;
      final r = e.value;
      if (r <= rmin || r >= rmax) continue;
      final l = laneOf[id];
      if (l == null) continue;
      if (l >= lmin && l <= lmax) cnt++;
    }
    return cnt;
  }
}

class GraphPainter extends CustomPainter {
  final GraphData data;
  final Map<String, Color> branchColors;
  final String? hoverPairKey;
  final double laneWidth;
  final double rowHeight;
  static const double nodeRadius = 6;
  GraphPainter(this.data, this.branchColors, this.hoverPairKey, this.laneWidth,
      this.rowHeight);
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
    final laneOf = _laneOfByBranches({for (final c in commits) c.id: c});
    final rowOf = <String, int>{};
    final paintNode = Paint()..color = const Color(0xFF1976D2);
    final paintBorder = Paint()
      ..color = const Color(0xFF1976D2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final paintEdge = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final byId = {for (final c in commits) c.id: c};
    final colorMemo = _computeBranchColors(byId);
    // 构造来自分支链的父->子关系，以及对每个边对的出现次数
    final children = <String, List<String>>{}; // parent -> [child]
    final pairCount = <String, int>{};
    for (final entry in data.chains.entries) {
      final ids = entry.value;
      for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        (children[parent] ??= <String>[]).add(child);
        final key = '$child|$parent';
        pairCount[key] = (pairCount[key] ?? 0) + 1;
      }
    }

    for (var i = 0; i < commits.length; i++) {
      final c = commits[i];
      rowOf[c.id] = i;
    }

    // 绘制节点
    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2;
      final y = row * rowHeight + rowHeight / 2;
      final childIds = children[c.id] ?? const <String>[];
      final childColors =
          childIds.map((id) => _colorOfCommit(id, colorMemo)).toSet();
      final isSplit = childIds.length >= 2 && childColors.length >= 2;
      final r = isSplit ? nodeRadius * 1.6 : nodeRadius;
      canvas.drawCircle(Offset(x, y), r, paintNode);
      if (isSplit) {
        canvas.drawCircle(Offset(x, y), r, paintBorder);
      }
    }

    // 绘制来自分支链的边，避免父列表造成的重边
    final pairDrawn = <String, int>{};
    for (final entry in data.chains.entries) {
      final bname = entry.key;
      final bcolor = branchColors[bname] ?? const Color(0xFF9E9E9E);
      final ids = entry.value;
      for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        if (!rowOf.containsKey(child) || !rowOf.containsKey(parent)) continue;
        final rowC = rowOf[child]!;
        final laneC = laneOf[child]!;
        final x = laneC * laneWidth + laneWidth / 2;
        final y = rowC * rowHeight + rowHeight / 2;
        final rowP = rowOf[parent]!;
        final laneP = laneOf[parent]!;
        final px = laneP * laneWidth + laneWidth / 2;
        final py = rowP * rowHeight + rowHeight / 2;
        final key = '$child|$parent';
        final total = pairCount[key] ?? 1;
        final done = pairDrawn[key] ?? 0;
        pairDrawn[key] = done + 1;
        // 将并行边按顺序左右分开，靠得很近
        final midY = (y + py) / 2;
        final dLane = (laneC - laneP).abs();
        var bendBase = (dLane * 8.0).clamp(8.0, 24.0);
        bendBase += _obstacleCount(child, parent, laneOf, rowOf) * 16.0;
        final dir = laneC <= laneP ? 1.0 : -1.0;
        final spread = (done - (total - 1) / 2.0) * 3.0; // -..0..+
        final path = Path();
        path.moveTo(x, y);
        path.cubicTo(x + dir * (bendBase + spread), midY,
            px - dir * (bendBase + spread), midY, px, py);
        paintEdge.color = bcolor;
        paintEdge.strokeWidth =
            (hoverPairKey != null && hoverPairKey == key) ? 3.0 : 2.0;
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

  int _obstacleCount(String child, String parent, Map<String, int> laneOf,
      Map<String, int> rowOf) {
    final rc = rowOf[child]!;
    final rp = rowOf[parent]!;
    final lc = laneOf[child]!;
    final lp = laneOf[parent]!;
    final rmin = math.min(rc, rp);
    final rmax = math.max(rc, rp);
    final lmin = math.min(lc, lp);
    final lmax = math.max(lc, lp);
    var cnt = 0;
    for (final e in rowOf.entries) {
      final id = e.key;
      if (id == child || id == parent) continue;
      final r = e.value;
      if (r <= rmin || r >= rmax) continue;
      final l = laneOf[id];
      if (l == null) continue;
      if (l >= lmin && l <= lmax) cnt++;
    }
    return cnt;
  }

  Color _colorOfCommit(String id, Map<String, Color> memo) {
    return memo[id] ?? const Color(0xFF9E9E9E);
  }

  String? _branchOfRefs(List<String> refs) {
    final names = data.branches.map((b) => b.name).toSet();
    for (final r in refs) {
      if (names.contains(r)) return r;
    }
    return null;
  }

  Map<String, Color> _computeBranchColors(Map<String, CommitNode> byId) {
    final memo = <String, Color>{};
    // Branch priority: master first, then others by name
    final ordered = List<Branch>.from(data.branches);
    ordered.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });
    int idx = 0;
    for (final b in ordered) {
      final color =
          branchColors[b.name] ?? lanePalette[idx % lanePalette.length];
      idx++;
      var cur = byId[b.head];
      while (cur != null && memo[cur.id] == null) {
        memo[cur.id] = color;
        if (cur.parents.isEmpty) break;
        final next = byId[cur.parents.first];
        cur = next;
      }
    }
    return memo;
  }

  Map<String, int> _branchLane(List<Branch> branches) {
    final ordered = List<Branch>.from(branches);
    ordered.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });
    final map = <String, int>{};
    for (var i = 0; i < ordered.length; i++) {
      map[ordered[i].name] = i;
    }
    return map;
  }

  Map<String, int> _laneOfByBranches(Map<String, CommitNode> byId) {
    final laneOf = <String, int>{};
    final branchLane = _branchLane(data.branches);
    final orderedNames = branchLane.keys.toList()
      ..sort((a, b) {
        int pa = a == 'master' ? 0 : 1;
        int pb = b == 'master' ? 0 : 1;
        if (pa != pb) return pa - pb;
        return a.compareTo(b);
      });
    for (final name in orderedNames) {
      final lane = branchLane[name]!;
      final ids = data.chains[name] ?? const <String>[];
      for (final id in ids) {
        laneOf[id] ??= lane;
      }
    }
    for (final c in byId.values) {
      if (laneOf[c.id] != null) continue;
      int? lane;
      for (final p in c.parents) {
        final lp = laneOf[p];
        if (lp != null) {
          lane = lp;
          break;
        }
      }
      final laneVal = lane ?? branchLane.length;
      laneOf[c.id] = laneVal;
    }
    return laneOf;
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
