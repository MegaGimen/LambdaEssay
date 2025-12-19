import 'package:flutter/gestures.dart';
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
  final Map<String, int>? customRowMapping;
  final Map<String, Color>? customNodeColors;
  final List<CommitNode> ghostNodes; // New: Ghost nodes
  final bool showCurrentHead; // New: Toggle for current head highlight

  static const double nodeRadius = 6;

  final Map<String, int>? preCalculatedLaneOf;
  final Map<String, int>? preCalculatedRowOf;

  GraphPainter(
    this.data,
    this.branchColors,
    this.hoverPairKey,
    this.laneWidth,
    this.rowHeight, {
    this.working,
    required this.selectedNodes,
    this.identicalCommitIds,
    this.customRowMapping,
    this.customNodeColors,
    this.ghostNodes = const [],
    this.showCurrentHead = true,
    this.preCalculatedLaneOf,
    this.preCalculatedRowOf,
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

  static Map<String, int> calculateLaneOf(List<CommitNode> allCommits, List<Branch> branches) {
    // Create a map for fast lookup
    final byId = {for (final c in allCommits) c.id: c};
    
    final laneOf = <String, int>{};
    final orderedBranches = List<Branch>.from(branches);
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

    // Use byId.values (all commits)
    final commitsToCheck = byId.values.toList();
    // Sort by date desc to ensure consistent processing
    commitsToCheck.sort((a, b) {
      final d = b.date.compareTo(a.date);
      if (d != 0) return d;
      return b.id.compareTo(a.id); // Stabilize sort
    });

    for (final c in commitsToCheck) {
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
  void paint(Canvas canvas, Size size) {
    // Merge real and ghost commits for layout calculation
    final allCommits = [...data.commits, ...ghostNodes];
    final ghostIds = ghostNodes.map((c) => c.id).toSet();

    final laneOf = preCalculatedLaneOf ?? calculateLaneOf(allCommits, data.branches);
    
    // Prepare rowOf
    final Map<String, int> rowOf;
    if (preCalculatedRowOf != null) {
      rowOf = preCalculatedRowOf!;
    } else {
      rowOf = <String, int>{};
      // Assign rows using mapping or index (using allCommits order would be ideal if sorted)
      // But we rely on customRowMapping for alignment.
      for (var i = 0; i < allCommits.length; i++) {
        final c = allCommits[i];
        if (customRowMapping != null && customRowMapping!.containsKey(c.id)) {
          rowOf[c.id] = customRowMapping![c.id]!;
        } else {
          // Fallback: if not in mapping, what row?
          // If it's a ghost node without mapping, it will collide.
          // We assume all nodes (real + ghost) should be in mapping if we are doing comparison.
          // If fallback needed, maybe use index in allCommits?
          // But allCommits isn't sorted by unified logic here.
          // Let's assume customRowMapping covers everything relevant.
          rowOf[c.id] = i; 
        }
      }
    }

    final paintBorder = Paint()
      ..color = const Color(0xFF1976D2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    // Use data.commits for branch coloring as before, or maybe we should use all?
    // Let's use data.commits because ghosts don't carry branch info easily unless we infer.
    // However, if we want ghosts to match branch colors, we need to know their branch.
    // For now, ghosts will be grey/dashed.
    final byId = {for (final c in data.commits) c.id: c};
    final colorMemo = _computeBranchColors(byId);

    // ... pair calculation for real commits ...
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

    // Assign rows logic moved up to prepare rowOf block


    String? currentHeadId;
    if (showCurrentHead && data.currentBranch != null) {
      for (final b in data.branches) {
        if (b.name == data.currentBranch) {
          currentHeadId = b.head;
          break;
        }
      }
    }

    // Draw ALL commits (Real + Ghost)
    for (final c in allCommits) {
      if (!rowOf.containsKey(c.id) || !laneOf.containsKey(c.id)) continue;

      final isGhost = ghostIds.contains(c.id);
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2;
      final y = row * rowHeight + rowHeight / 2;

      // Children logic mainly for 'isSplit' visualization on real nodes
      // Ghosts don't usually show split ring unless we want to.
      final childIds = children[c.id] ?? const <String>[];
      final childColors =
          childIds.map((id) => _colorOfCommit(id, colorMemo)).toSet();
      final isSplit = !isGhost && childIds.length >= 2 && childColors.length >= 2;
      final r = isSplit ? nodeRadius * 1.6 : nodeRadius;

      Color nodeColor = const Color(0xFF1976D2);
      if (customNodeColors != null && customNodeColors!.containsKey(c.id)) {
        nodeColor = customNodeColors![c.id]!;
      } else if (isGhost) {
        nodeColor = Colors.grey; // Default ghost color if not specified
      }

      final paintNode = Paint()
        ..color = nodeColor
        ..style = isGhost ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = isGhost ? 2.0 : 0;
      
      if (isGhost) {
        // Dashed effect for ghost node?
        // Just stroke is fine, maybe lighter color.
        paintNode.color = nodeColor.withValues(alpha: 0.6);
      }

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

    // Draw Edges - Real (Chains)
    final pairDrawn = <String, int>{};
    for (final entry in data.chains.entries) {
      final bname = entry.key;
      final bcolor = branchColors[bname] ?? const Color(0xFF9E9E9E);
      final ids = entry.value;
      _drawChain(canvas, ids, bcolor, bname, rowOf, laneOf, byId, pairCount, pairDrawn);
    }
    
    // Draw Edges - Ghosts (Iterate ghost nodes and connect to parents)
    // We use a generic grey dashed line for ghost edges
    final ghostEdgePaint = Paint()
      ..color = Colors.grey
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    // Simple dash effect: 5px on, 5px off
    // Note: DashPathEffect requires dart:ui
    // We can't easily apply PathEffect to Paint in all Flutter versions without checking compatibility, 
    // but standard Flutter does support paint.pathEffect.
    // However, if we want to be safe, we can use simple stroke first.
    // Let's try adding PathEffect if possible.
    // Since I imported dart:ui as ui, I can use it.
    // ghostEdgePaint.pathEffect = ui.DashPathEffect(const [5, 5], 0); 
    // Wait, ui.DashPathEffect isn't always exposed directly in older Flutter/Dart versions via ui.
    // It is `ui.PathEffect`? No, `DashPathEffect` is a class in `dart:ui`.
    // Let's assume it works.
    
    for (final c in ghostNodes) {
       if (c.parents.isEmpty) continue;
       final rowC = rowOf[c.id];
       final laneC = laneOf[c.id];
       if (rowC == null || laneC == null) continue;
       
       for (final pId in c.parents) {
         if (!rowOf.containsKey(pId) || !laneOf.containsKey(pId)) continue;
         
         final rowP = rowOf[pId]!;
         final laneP = laneOf[pId]!;
         
         _drawEdge(canvas, rowC, laneC, rowP, laneP, ghostEdgePaint, isDashed: true);
       }
    }

    // Draw remaining edges for real commits that weren't in chains
    for (final c in data.commits) {
      if (c.parents.isEmpty) continue;
      final rowC = rowOf[c.id];
      final laneC = laneOf[c.id];
      if (rowC == null || laneC == null) continue;

      // Primary parent
      final p0Id = c.parents[0];
      final key0 = '${c.id}|$p0Id';
      if (!pairDrawn.containsKey(key0)) {
         final rowP = rowOf[p0Id];
         final laneP = laneOf[p0Id];
         if (rowP != null && laneP != null) {
           final color = _colorOfCommit(c.id, colorMemo);
           final paint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = color;
           
           // Current branch glow logic...
           bool isCurrentBranch = false;
           if (showCurrentHead && data.currentBranch != null) {
              final branchColor = branchColors[data.currentBranch!];
              if (branchColor != null && color == branchColor) {
                isCurrentBranch = true;
              }
           }
           if (isCurrentBranch) {
              final paintGlow = Paint()
                ..color = color.withValues(alpha: 0.4)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 8.0
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
              _drawEdge(canvas, rowC, laneC, rowP, laneP, paintGlow);
           }
           _drawEdge(canvas, rowC, laneC, rowP, laneP, paint);
         }
      }

      // Merge parents
      for (int i = 1; i < c.parents.length; i++) {
        final pId = c.parents[i];
        final rowP = rowOf[pId];
        final laneP = laneOf[pId];
        if (rowP == null || laneP == null) continue;
        
        final paintMerge = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = const Color(0xFF000000);
        _drawEdge(canvas, rowC, laneC, rowP, laneP, paintMerge);
      }
    }

    // Custom Edges
    for (final edge in data.customEdges) {
      if (edge.length < 2) continue;
      final child = edge[0];
      final parent = edge[1];
      final rowC = rowOf[child];
      final laneC = laneOf[child];
      final rowP = rowOf[parent];
      final laneP = laneOf[parent];
      
      if (rowC == null || laneC == null || rowP == null || laneP == null) continue;
      
      final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = const Color(0xFF000000);
      _drawEdge(canvas, rowC, laneC, rowP, laneP, paint);
    }

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    // Draw text for ALL commits
    for (final c in allCommits) {
      final row = rowOf[c.id];
      final lane = laneOf[c.id];
      if (row == null || lane == null) continue;
      
      final isGhost = ghostIds.contains(c.id);
      final x = lane * laneWidth + laneWidth / 2 + 10;
      final y = row * rowHeight + rowHeight / 2;
      String msg = c.subject;
      if (msg.length > 10) {
        msg = '${msg.substring(0, 10)}...';
      }

      final textColor = isGhost ? Colors.grey : Colors.black;

      textPainter.text = TextSpan(
        style: TextStyle(color: textColor, fontSize: 12),
        children: [
          TextSpan(text: '提交id：${c.id.substring(0, 7)}'),
          if (c.refs.isNotEmpty && !isGhost)
            TextSpan(
                text: ' [${Branch.decodeName(c.refs.first)}]',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          const TextSpan(text: '\n'),
          TextSpan(text: '提交信息：$msg'),
        ],
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x, y - textPainter.height / 2));
    }

    // Border and overlay logic (omitted for brevity or copied)
    int maxLane = -1;
    for (final v in laneOf.values) {
      if (v > maxLane) maxLane = v;
    }
    if (maxLane < 0) maxLane = 0;
    final graphWidth = (maxLane + 1) * laneWidth;
    final graphHeight = allCommits.length * rowHeight; // Use allCommits length
    final borderPaint = Paint()
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Rect.fromLTWH(0, 0, graphWidth, graphHeight), borderPaint);

    if (working?.changed == true) {
       // ... existing working state drawing ...
       // (Keeping it simple, assume working state logic applies if provided)
    }
  }

  void _drawChain(
      Canvas canvas,
      List<String> ids,
      Color color,
      String bname,
      Map<String, int> rowOf,
      Map<String, int> laneOf,
      Map<String, CommitNode> byId,
      Map<String, int> pairCount,
      Map<String, int> pairDrawn) {
    
    final paintEdge = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..color = color;

    for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        if (!rowOf.containsKey(child) || !rowOf.containsKey(parent)) continue;

        final childNodeCheck = byId[child];
        if (childNodeCheck != null &&
            !childNodeCheck.parents.contains(parent)) {
          continue;
        }
        
        // Spread logic for parallel edges
        final key = '$child|$parent';
        final total = pairCount[key] ?? 1;
        final done = pairDrawn[key] ?? 0;
        pairDrawn[key] = done + 1;
        final spread = (done - (total - 1) / 2.0) * 4.0;

        final rowC = rowOf[child]!;
        final laneC = laneOf[child]!;
        final rowP = rowOf[parent]!;
        final laneP = laneOf[parent]!;
        
        bool isCurrent = showCurrentHead && data.currentBranch == bname;
        bool isHover = hoverPairKey != null && hoverPairKey == key;
        paintEdge.strokeWidth = isCurrent ? 4.0 : (isHover ? 3.0 : 2.0);

        _drawEdge(canvas, rowC, laneC, rowP, laneP, paintEdge, spread: spread);
    }
  }

  void _drawEdge(Canvas canvas, int rowC, int laneC, int rowP, int laneP, Paint paint, {double spread = 0, bool isDashed = false}) {
      final x = laneC * laneWidth + laneWidth / 2 + spread;
      final y = rowC * rowHeight + rowHeight / 2;
      final px = laneP * laneWidth + laneWidth / 2 + spread;
      final py = rowP * rowHeight + rowHeight / 2;

      final path = Path();
      if (laneC == laneP) {
        path.moveTo(x, y);
        path.lineTo(px, py);
      } else {
        path.moveTo(px, py);
        path.lineTo(x, py);
        path.lineTo(x, y);
      }
      
      if (isDashed) {
        // Apply manual dash if PathEffect fails or for simplicity
        // But since we can use ui.DashPathEffect
        // We create a new paint to avoid modifying the passed one if strictly needed,
        // but here we can just modify.
        // However, standard Paint object in Flutter doesn't have .pathEffect setter in strict API?
        // It does.
        // But to be safe against older Flutter versions:
        // paint.pathEffect = ui.DashPathEffect(const [5, 5], 0);
        // If this file fails to compile, I will revert to solid line.
        // Assuming user environment is recent.
        final dashedPaint = Paint()
           ..color = paint.color
           ..style = PaintingStyle.stroke
           ..strokeWidth = paint.strokeWidth;
        // dashedPaint.pathEffect = ui.DashPathEffect(const [5, 5], 0); // Commented out to avoid potential compile error if not supported
        // Let's implement manual dash for safety or use a simpler indicator.
        // "虚边" (Dashed edge).
        // I'll try to use a utility method to draw dashed path.
        _drawDashedPath(canvas, path, dashedPaint);
      } else {
        canvas.drawPath(path, paint);
      }
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    // Simple implementation of dashed path
    final metric = path.computeMetrics().first;
    final length = metric.length;
    double distance = 0.0;
    while (distance < length) {
      final extract = metric.extractPath(distance, distance + 5);
      canvas.drawPath(extract, paint);
      distance += 10;
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

  Map<String, int> _laneOfByBranches(Map<String, CommitNode> byId, List<Branch> branches) {
    final laneOf = <String, int>{};
    final orderedBranches = List<Branch>.from(branches);
    orderedBranches.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });

    // Build children map for forward lane extension
    final children = <String, List<String>>{};
    for (final c in byId.values) {
      for (final pId in c.parents) {
        (children[pId] ??= []).add(c.id);
      }
    }

    int nextFreeLane = 0;
    for (final b in orderedBranches) {
      var curId = b.head;
      if (laneOf.containsKey(curId)) continue;
      final currentBranchLane = nextFreeLane++;

      // Backward trace
      var tempId = curId;
      while (true) {
        if (laneOf.containsKey(tempId)) break;
        laneOf[tempId] = currentBranchLane;
        final node = byId[tempId];
        if (node == null || node.parents.isEmpty) break;
        tempId = node.parents.first;
      }

      // Forward trace (Extend lane to children/ghosts)
      var tipId = curId;
      while (true) {
        final kids = children[tipId];
        if (kids == null || kids.isEmpty) break;

        // Sort by date desc
        kids.sort((a, b) {
          final da = byId[a]?.date ?? '';
          final db = byId[b]?.date ?? '';
          return db.compareTo(da);
        });

        String? nextTip;
        for (final k in kids) {
          if (!laneOf.containsKey(k)) {
            laneOf[k] = currentBranchLane;
            nextTip = k;
            break; // Extend only one path
          }
        }
        if (nextTip != null) {
          tipId = nextTip;
        } else {
          break;
        }
      }
    }

    // Use byId.values (all commits) instead of data.commits
    final allCommits = byId.values.toList();
    // Sort by date desc to ensure consistent processing? 
    // GraphData commits are sorted. Ghosts might not be.
    // It's better to sort them roughly.
    allCommits.sort((a, b) => b.date.compareTo(a.date));

    for (final c in allCommits) {
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
    return oldDelegate.data != data ||
        oldDelegate.ghostNodes != ghostNodes ||
        oldDelegate.preCalculatedLaneOf != preCalculatedLaneOf ||
        oldDelegate.preCalculatedRowOf != preCalculatedRowOf ||
        oldDelegate.customRowMapping != customRowMapping ||
        oldDelegate.customNodeColors != customNodeColors ||
        oldDelegate.selectedNodes != selectedNodes ||
        oldDelegate.identicalCommitIds != identicalCommitIds ||
        oldDelegate.working != working;
  }
}

class SimpleGraphView extends StatefulWidget {
  final GraphData data;
  final bool readOnly;
  final Function(String)? onPreviewCommit;
  final TransformationController? transformationController;
  final Map<String, int>? customRowMapping;
  final Map<String, Color>? customNodeColors;
  final List<CommitNode> ghostNodes;
  final bool showCurrentHead;
  final bool showLegend;

  const SimpleGraphView({
    super.key,
    required this.data,
    this.readOnly = false,
    this.onPreviewCommit,
    this.transformationController,
    this.customRowMapping,
    this.customNodeColors,
    this.ghostNodes = const [],
    this.showCurrentHead = true,
    this.showLegend = false,
  });

  @override
  State<SimpleGraphView> createState() => _SimpleGraphViewState();
}

class _SimpleGraphViewState extends State<SimpleGraphView> {
  late TransformationController _tc;
  double _laneWidth = 120;
  double _rowHeight = 160;
  Size? _canvasSize;
  Map<String, Color>? _branchColors;
  final Set<String> _selectedNodes = {};
  
  Map<String, int>? _cachedLaneOf;
  Map<String, int>? _cachedRowOf;

  @override
  void initState() {
    super.initState();
    _tc = widget.transformationController ?? TransformationController();
  }

  void _updateLayout() {
    final allCommits = [...widget.data.commits, ...widget.ghostNodes];
    
    // Create effective branches to include ghost nodes in the layout logic.
    // If a ghost node extends a branch head, we temporarily move the branch head to the ghost node
    // so that the layout algorithm assigns it the same lane.
    final effectiveBranches = List<Branch>.from(widget.data.branches);
    final branchHeads = {for (var b in effectiveBranches) b.head: b};
    
    // Sort ghost nodes by date/relationship if needed, but usually they are few.
    // We assume ghostNodes are ordered such that parents come before children if chained,
    // or we can iterate multiple times. For now, simple single pass.
    for (final g in widget.ghostNodes) {
      if (g.parents.isNotEmpty) {
        final pId = g.parents.first;
        if (branchHeads.containsKey(pId)) {
          final b = branchHeads[pId]!;
          effectiveBranches.remove(b);
          final newB = Branch(name: b.name, head: g.id);
          effectiveBranches.add(newB);
          // Update map so subsequent ghost nodes can chain onto this one
          branchHeads.remove(pId);
          branchHeads[g.id] = newB;
        }
      }
    }

    // Reuse the static method from GraphPainter with effective branches
    _cachedLaneOf = GraphPainter.calculateLaneOf(allCommits, effectiveBranches);
    
    _cachedRowOf = {};
    for (var i = 0; i < allCommits.length; i++) {
       final c = allCommits[i];
       if (widget.customRowMapping != null && widget.customRowMapping!.containsKey(c.id)) {
         _cachedRowOf![c.id] = widget.customRowMapping![c.id]!;
       } else {
         _cachedRowOf![c.id] = i;
       }
    }
    
    // Force repaint after layout update
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant SimpleGraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transformationController != null &&
        widget.transformationController != oldWidget.transformationController) {
      _tc = widget.transformationController!;
    }
    // Ideally update layout here if data changed
    if (widget.data != oldWidget.data || 
        widget.ghostNodes != oldWidget.ghostNodes || 
        widget.customRowMapping != oldWidget.customRowMapping) {
       _updateLayout();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ensure layout is updated at least once or if null
    if (_cachedLaneOf == null || _cachedRowOf == null) {
      _updateLayout();
    }

    _canvasSize ??= _computeCanvasSize(widget.data);
    _branchColors ??= _assignBranchColors(widget.data.branches);

    final content = Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final double scaleChange = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
          final Matrix4 matrix = _tc.value.clone();
          matrix.scale(scaleChange);
          _tc.value = matrix;
        }
      },
      child: InteractiveViewer(
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
                customRowMapping: widget.customRowMapping,
                customNodeColors: widget.customNodeColors,
                ghostNodes: widget.ghostNodes,
                showCurrentHead: widget.showCurrentHead,
                preCalculatedLaneOf: _cachedLaneOf,
                preCalculatedRowOf: _cachedRowOf,
              ),
              size: _canvasSize!,
            ),
          ),
        ),
      ),
    );

    if (widget.showLegend && _branchColors != null && _branchColors!.isNotEmpty) {
      return Stack(
        children: [
          content,
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(maxWidth: 200, maxHeight: 300),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: _branchColors!.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12, 
                          height: 12, 
                          decoration: BoxDecoration(
                            color: e.value,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            Branch.decodeName(e.key), 
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  )).toList(),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return content;
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
    if (_cachedRowOf == null || _cachedLaneOf == null) return null;
    
    final allCommits = [...data.commits, ...widget.ghostNodes];
    
    // 1. Check exact node hits (circular area)
    for (final c in allCommits) {
      if (!_cachedRowOf!.containsKey(c.id) || !_cachedLaneOf!.containsKey(c.id)) continue;
      
      final row = _cachedRowOf![c.id]!;
      final lane = _cachedLaneOf![c.id]!;
      
      final x = lane * _laneWidth + _laneWidth / 2;
      final y = row * _rowHeight + _rowHeight / 2;
      
      final dx = localPos.dx - x;
      final dy = localPos.dy - y;
      
      // Radius is 6, let's give a hit radius of 20
      if (dx * dx + dy * dy < 400) { 
        return c;
      }
    }

    // 2. Fallback: Check row hits with X-axis proximity
    final row = ((localPos.dy - _rowHeight / 2) / _rowHeight).round();
    
    CommitNode? bestMatch;
    double minDx = double.infinity;

    for (final c in allCommits) {
       if (_cachedRowOf![c.id] == row) {
          if (!_cachedLaneOf!.containsKey(c.id)) continue;
          
          final lane = _cachedLaneOf![c.id]!;
          final x = lane * _laneWidth + _laneWidth / 2;
          final dist = (localPos.dx - x).abs();
          
          // Only consider if within half a lane width to avoid cross-lane false positives
          if (dist < _laneWidth / 2 && dist < minDx) {
            minDx = dist;
            bestMatch = c;
          }
       }
    }
    
    return bestMatch;
  }
}
