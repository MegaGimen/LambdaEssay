import 'dart:math' as math;

import 'package:flutter/material.dart';

class MovableResizablePanel extends StatefulWidget {
  final Offset offset;
  final Size size;
  final Size parentSize;
  final double scale;
  final ValueChanged<Offset> onOffsetChanged;
  final ValueChanged<Size> onSizeChanged;
  final Size minSize;
  final Size maxSize;
  final double elevation;
  final BorderRadius borderRadius;
  final EdgeInsets contentPadding;
  final Color backgroundColor;
  final Widget child;
  final String? title;
  final double handleThickness;
  final double cornerHandleSize;

  const MovableResizablePanel({
    super.key,
    required this.offset,
    required this.size,
    required this.parentSize,
    required this.onOffsetChanged,
    required this.onSizeChanged,
    required this.child,
    this.scale = 1.0,
    this.minSize = const Size(200, 120),
    this.maxSize = const Size(1200, 900),
    this.elevation = 4,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.contentPadding = const EdgeInsets.all(8),
    this.backgroundColor = Colors.white,
    this.title,
    this.handleThickness = 12,
    this.cornerHandleSize = 20,
  });

  @override
  State<MovableResizablePanel> createState() => _MovableResizablePanelState();
}

class _MovableResizablePanelState extends State<MovableResizablePanel> {
  Offset? _dragStartGlobal;
  Offset? _dragStartOffset;

  Offset? _resizeStartGlobal;
  Size? _resizeStartSize;

  Offset _clampOffset(Offset value, Size panelSize) {
    final scaledW = panelSize.width * widget.scale;
    final scaledH = panelSize.height * widget.scale;
    final maxDx = math.max(0.0, widget.parentSize.width - scaledW);
    final maxDy = math.max(0.0, widget.parentSize.height - scaledH);
    return Offset(
      value.dx.clamp(0.0, maxDx),
      value.dy.clamp(0.0, maxDy),
    );
  }

  Size _clampSize(Size value) {
    final viewportMaxW =
        widget.parentSize.width.isFinite && widget.parentSize.width > 0
            ? widget.parentSize.width / widget.scale
            : widget.maxSize.width;
    final viewportMaxH =
        widget.parentSize.height.isFinite && widget.parentSize.height > 0
            ? widget.parentSize.height / widget.scale
            : widget.maxSize.height;

    final effectiveMaxW =
        math.max(widget.minSize.width, math.min(widget.maxSize.width, viewportMaxW));
    final effectiveMaxH =
        math.max(widget.minSize.height, math.min(widget.maxSize.height, viewportMaxH));

    return Size(
      value.width.clamp(widget.minSize.width, effectiveMaxW),
      value.height.clamp(widget.minSize.height, effectiveMaxH),
    );
  }

  void _startDrag(DragStartDetails d, Offset clampedOffset) {
    _dragStartGlobal = d.globalPosition;
    _dragStartOffset = clampedOffset;
  }

  void _updateDrag(DragUpdateDetails d, Size clampedSize) {
    final startG = _dragStartGlobal;
    final startO = _dragStartOffset;
    if (startG == null || startO == null) return;
    final nextOffset = _clampOffset(startO + (d.globalPosition - startG), clampedSize);
    widget.onOffsetChanged(nextOffset);
  }

  void _endDrag() {
    _dragStartGlobal = null;
    _dragStartOffset = null;
  }

  void _startResize(DragStartDetails d, Size clampedSize) {
    _resizeStartGlobal = d.globalPosition;
    _resizeStartSize = clampedSize;
  }

  void _updateResize(DragUpdateDetails d, Offset clampedOffset, Size clampedSize,
      {bool x = false, bool y = false}) {
    final startG = _resizeStartGlobal;
    final startS = _resizeStartSize;
    if (startG == null || startS == null) return;

    final s = widget.scale == 0 ? 1.0 : widget.scale;
    final deltaGlobal = d.globalPosition - startG;

    final nextSize = _clampSize(
      Size(
        x ? (startS.width + deltaGlobal.dx / s) : startS.width,
        y ? (startS.height + deltaGlobal.dy / s) : startS.height,
      ),
    );

    widget.onSizeChanged(nextSize);
    widget.onOffsetChanged(_clampOffset(clampedOffset, nextSize));
  }

  void _endResize() {
    _resizeStartGlobal = null;
    _resizeStartSize = null;
  }

  @override
  Widget build(BuildContext context) {
    final clampedSize = _clampSize(widget.size);
    final clampedOffset = _clampOffset(widget.offset, clampedSize);

    return Transform.translate(
      offset: clampedOffset,
      child: Transform.scale(
        scale: widget.scale,
        alignment: Alignment.topLeft,
        child: Material(
          elevation: widget.elevation,
          borderRadius: widget.borderRadius,
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: SizedBox(
              width: clampedSize.width,
              height: clampedSize.height,
              child: DecoratedBox(
                decoration: BoxDecoration(color: widget.backgroundColor),
                child: Stack(
                  children: [
                    Column(
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) => _startDrag(d, clampedOffset),
                          onPanUpdate: (d) => _updateDrag(d, clampedSize),
                          onPanEnd: (_) => _endDrag(),
                          child: SizedBox(
                            height: 24,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.max,
                                children: [
                                  const Icon(Icons.drag_indicator, size: 18),
                                  if (widget.title != null) ...[
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        widget.title!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        softWrap: false,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ] else
                                    const Spacer(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: widget.contentPadding,
                            child: widget.child,
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      right: 0,
                      top: 24,
                      bottom: widget.cornerHandleSize,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => _startResize(d, clampedSize),
                        onPanUpdate: (d) =>
                            _updateResize(d, clampedOffset, clampedSize, x: true),
                        onPanEnd: (_) => _endResize(),
                        child: SizedBox(width: widget.handleThickness),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: widget.cornerHandleSize,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => _startResize(d, clampedSize),
                        onPanUpdate: (d) =>
                            _updateResize(d, clampedOffset, clampedSize, y: true),
                        onPanEnd: (_) => _endResize(),
                        child: SizedBox(height: widget.handleThickness),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => _startResize(d, clampedSize),
                        onPanUpdate: (d) =>
                            _updateResize(d, clampedOffset, clampedSize, x: true, y: true),
                        onPanEnd: (_) => _endResize(),
                        child: const SizedBox(
                          width: 20,
                          height: 20,
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(Icons.open_in_full, size: 14),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
