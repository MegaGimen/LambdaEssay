import 'package:flutter/material.dart';
import 'models.dart';

class GraphPainter extends CustomPainter {
  final GraphData data;
  final Map<String, Color> branchColors;
  final String? hoverPairKey;
  final double laneWidth;
  final double rowHeight;
  final WorkingState? working;
  final Set<String> selectedNodes;
  final List<String>? identicalCommitIds;
  static const double nodeRadius = 6;

  GraphPainter(
    this.data,
    this.branchColors,
    this.hoverPairKey,
    this.laneWidth,
    this.rowHeight, {
    this.working,
    required this.selectedNodes,
    this.identicalCommitIds,
  });

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

    final children = <String, List<String>>{};
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

    String? currentHeadId;
    if (data.currentBranch != null) {
      for (final b in data.branches) {
        if (b.name == data.currentBranch) {
          currentHeadId = b.head;
          break;
        }
      }
    }

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

      if (c.id == currentHeadId) {
        final paintCurHead = Paint()
          ..color = Colors.green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0;
        canvas.drawCircle(Offset(x, y), r + 5, paintCurHead);
      }

      if (identicalCommitIds != null && identicalCommitIds!.contains(c.id)) {
        final paintIdent = Paint()
          ..color = Colors.purple
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.0;
        canvas.drawCircle(Offset(x, y), r + 8, paintIdent);
      }

      canvas.drawCircle(Offset(x, y), r, paintNode);
      if (isSplit) {
        canvas.drawCircle(Offset(x, y), r, paintBorder);
      }
      if (selectedNodes.contains(c.id)) {
        final paintSel = Paint()
          ..color = Colors.redAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0;
        canvas.drawCircle(Offset(x, y), r + 4, paintSel);
      }
    }

    final pairDrawn = <String, int>{};
    for (final entry in data.chains.entries) {
      final bname = entry.key;
      final bcolor = branchColors[bname] ?? const Color(0xFF9E9E9E);
      final ids = entry.value;
      for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        if (!rowOf.containsKey(child) || !rowOf.containsKey(parent)) continue;

        final childNodeCheck = byId[child];
        if (childNodeCheck != null &&
            !childNodeCheck.parents.contains(parent)) {
          continue;
        }

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
        final spread = (done - (total - 1) / 2.0) * 4.0;

        final path = Path();
        final sx = x + spread;
        final sy = y;
        final ex = px + spread;
        final ey = py;

        final childNode = byId[child];
        bool isMergeEdge = false;
        if (childNode != null && childNode.parents.length > 1) {
          if (childNode.parents[0] != parent) {
            isMergeEdge = true;
          }
        }

        if (laneC == laneP) {
          path.moveTo(sx, sy);
          path.lineTo(ex, ey);
        } else {
          if (isMergeEdge) {
            continue;
          } else {
            path.moveTo(ex, ey);
            path.lineTo(sx, ey);
            path.lineTo(sx, sy);
          }
        }

        paintEdge.color = bcolor;
        bool isCurrent = data.currentBranch == bname;
        bool isHover = hoverPairKey != null && hoverPairKey == key;

        paintEdge.strokeWidth = isCurrent ? 4.0 : (isHover ? 3.0 : 2.0);

        if (isCurrent) {
          bool isFirstParent = false;
          if (childNode != null && childNode.parents.isNotEmpty) {
            if (childNode.parents[0] == parent) {
              isFirstParent = true;
            }
          }

          if (isFirstParent) {
            final paintGlow = Paint()
              ..color = bcolor.withValues(alpha: 0.4)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 8.0
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
            canvas.drawPath(path, paintGlow);
          }
        }

        canvas.drawPath(path, paintEdge);
      }
    }

    for (final c in commits) {
      if (c.parents.isEmpty) continue;

      final rowC = rowOf[c.id];
      final laneC = laneOf[c.id];
      if (rowC == null || laneC == null) continue;

      final x = laneC * laneWidth + laneWidth / 2;
      final y = rowC * rowHeight + rowHeight / 2;

      final p0Id = c.parents[0];
      final key0 = '${c.id}|$p0Id';
      if (!pairDrawn.containsKey(key0)) {
        final rowP = rowOf[p0Id];
        final laneP = laneOf[p0Id];
        if (rowP != null && laneP != null) {
          final px = laneP * laneWidth + laneWidth / 2;
          final py = rowP * rowHeight + rowHeight / 2;

          final paintMain = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = _colorOfCommit(c.id, colorMemo);

          final path = Path();
          if (laneC == laneP) {
            path.moveTo(x, y);
            path.lineTo(px, py);
          } else {
            path.moveTo(px, py);
            path.lineTo(x, py);
            path.lineTo(x, y);
          }

          bool isCurrentBranch = false;
          if (data.currentBranch != null) {
            final branchColor = branchColors[data.currentBranch!];
            final nodeColor = _colorOfCommit(c.id, colorMemo);
            if (branchColor != null && nodeColor == branchColor) {
              isCurrentBranch = true;
            }
          }

          if (isCurrentBranch) {
            final paintGlow = Paint()
              ..color = _colorOfCommit(c.id, colorMemo).withValues(alpha: 0.4)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 8.0
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
            canvas.drawPath(path, paintGlow);
          }

          canvas.drawPath(path, paintMain);
        }
      }

      for (int i = 1; i < c.parents.length; i++) {
        final pId = c.parents[i];
        final rowP = rowOf[pId];
        final laneP = laneOf[pId];
        if (rowP == null || laneP == null) continue;

        final px = laneP * laneWidth + laneWidth / 2;
        final py = rowP * rowHeight + rowHeight / 2;

        final paintMerge = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = const Color(0xFF000000);

        final path = Path();
        path.moveTo(x, y);
        path.lineTo(px, py);
        canvas.drawPath(path, paintMerge);
      }
    }

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2 + 10;
      final y = row * rowHeight + rowHeight / 2;
      String msg = c.subject;
      if (msg.length > 10) {
        msg = '${msg.substring(0, 10)}...';
      }

      textPainter.text = TextSpan(
        style: const TextStyle(color: Colors.black, fontSize: 12),
        children: [
          TextSpan(text: '提交id：${c.id.substring(0, 7)}'),
          if (c.refs.isNotEmpty)
            TextSpan(
                text: ' [${c.refs.first}]',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          const TextSpan(text: '\n'),
          TextSpan(text: '提交信息：$msg'),
        ],
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x, y - textPainter.height / 2));
    }

    int maxLane = -1;
    for (final v in laneOf.values) {
      if (v > maxLane) maxLane = v;
    }
    if (maxLane < 0) maxLane = 0;
    final graphWidth = (maxLane + 1) * laneWidth;
    final graphHeight = commits.length * rowHeight;
    final borderPaint = Paint()
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Rect.fromLTWH(0, 0, graphWidth, graphHeight), borderPaint);

    if (working?.changed == true) {
      final overlayMargin = 40.0;
      final overlayWidth = 240.0;
      final overlayX = graphWidth + overlayMargin;
      double overlayHeight = graphHeight;
      if (commits.isEmpty) {
        overlayHeight = rowHeight;
      }
      canvas.drawRect(
        Rect.fromLTWH(overlayX, 0, overlayWidth, overlayHeight),
        borderPaint,
      );
      final baseId = working?.baseId;
      int row = 0;
      if (baseId != null && rowOf.containsKey(baseId)) {
        row = rowOf[baseId]!;
      }
      final cx = overlayX + overlayWidth / 2;
      final cy = row * rowHeight + rowHeight / 2;
      final paintCur = Paint()..color = const Color(0xFFD81B60);
      canvas.drawCircle(Offset(cx, cy), nodeRadius * 1.6, paintCur);
      final labelSpan = TextSpan(
        text: '当前状态',
        style: const TextStyle(color: Colors.black, fontSize: 12),
      );
      textPainter.text = labelSpan;
      textPainter.layout();
      textPainter.paint(canvas, Offset(cx + 10, cy - 8));
    }
  }

  Color _colorOfCommit(String id, Map<String, Color> memo) {
    return memo[id] ?? const Color(0xFF9E9E9E);
  }

  Map<String, Color> _computeBranchColors(Map<String, CommitNode> byId) {
    final memo = <String, Color>{};
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

  Map<String, int> _laneOfByBranches(Map<String, CommitNode> byId) {
    final laneOf = <String, int>{};
    final orderedBranches = List<Branch>.from(data.branches);
    orderedBranches.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });

    int nextFreeLane = 0;
    for (final b in orderedBranches) {
      var curId = b.head;
      if (laneOf.containsKey(curId)) continue;
      final currentBranchLane = nextFreeLane++;
      while (true) {
        if (laneOf.containsKey(curId)) break;
        laneOf[curId] = currentBranchLane;
        final node = byId[curId];
        if (node == null || node.parents.isEmpty) break;
        curId = node.parents.first;
      }
    }

    for (final c in data.commits) {
      if (!laneOf.containsKey(c.id)) {
        laneOf[c.id] = nextFreeLane++;
      }
      final currentLane = laneOf[c.id]!;
      for (int i = 0; i < c.parents.length; i++) {
        final pId = c.parents[i];
        if (laneOf.containsKey(pId)) continue;
        if (i == 0) {
          laneOf[pId] = currentLane;
        } else {
          laneOf[pId] = nextFreeLane++;
        }
      }
    }
    return laneOf;
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}

class SimpleGraphView extends StatefulWidget {
  final GraphData data;
  final bool readOnly;
  final Function(String)? onPreviewCommit;

  const SimpleGraphView({
    super.key,
    required this.data,
    this.readOnly = false,
    this.onPreviewCommit,
  });

  @override
  State<SimpleGraphView> createState() => _SimpleGraphViewState();
}

class _SimpleGraphViewState extends State<SimpleGraphView> {
  final TransformationController _tc = TransformationController();
  double _laneWidth = 120;
  double _rowHeight = 160;
  Size? _canvasSize;
  Map<String, Color>? _branchColors;
  final Set<String> _selectedNodes = {};

  @override
  Widget build(BuildContext context) {
    _canvasSize ??= _computeCanvasSize(widget.data);
    _branchColors ??= _assignBranchColors(widget.data.branches);

    return InteractiveViewer(
      transformationController: _tc,
      minScale: 0.2,
      maxScale: 4,
      constrained: false,
      boundaryMargin: const EdgeInsets.all(2000),
      child: GestureDetector(
        onTapUp: (d) {
          if (widget.readOnly && widget.onPreviewCommit != null) {
            final hit = _hitTest(d.localPosition, widget.data);
            if (hit != null) {
              widget.onPreviewCommit!(hit.id);
            }
          }
        },
        child: SizedBox(
          width: _canvasSize!.width,
          height: _canvasSize!.height,
          child: CustomPaint(
            painter: GraphPainter(
              widget.data,
              _branchColors!,
              null,
              _laneWidth,
              _rowHeight,
              working: null,
              selectedNodes: _selectedNodes,
            ),
            size: _canvasSize!,
          ),
        ),
      ),
    );
  }

  Size _computeCanvasSize(GraphData data) {
    final commits = data.commits;
    // Simplified estimation or we can reuse _laneOfByBranches logic but that's inside Painter.
    // For now, let's just make it large enough or access logic if possible.
    // Since GraphPainter calculates logic internally, we can't easily get it here without duplicating.
    // However, GraphPainter paints based on what it calculates.
    // We need size passed to CustomPaint.
    // Let's implement a simple estimation:
    return Size(2000, (commits.length + 5) * _rowHeight);
    // Ideally we should move _laneOfByBranches to a static helper or utility class.
  }

  Map<String, Color> _assignBranchColors(List<Branch> branches) {
    final colors = <String, Color>{};
    int i = 0;
    for (final b in branches) {
      colors[b.name] =
          GraphPainter.lanePalette[i % GraphPainter.lanePalette.length];
      i++;
    }
    return colors;
  }

  CommitNode? _hitTest(Offset localPos, GraphData data) {
    // Simple hit test for nodes
    // Need to duplicate layout logic?
    // Yes, layout logic is in Painter. This is why main.dart had it in State.
    // For now, let's skip precise hit testing for readOnly view if it's too complex to duplicate.
    // Or we can rely on row estimation: y / rowHeight.
    final row = ((localPos.dy - _rowHeight / 2) / _rowHeight).round();
    if (row >= 0 && row < data.commits.length) {
      // Ideally check X too, but row is good enough for simple list
      // GraphPainter uses: for (var i = 0; i < commits.length; i++) rowOf[c.id] = i;
      // So yes, row index maps to commits index.
      return data.commits[row];
    }
    return null;
  }
}
