import 'package:flutter/material.dart';

class DraggableResizableWindow extends StatefulWidget {
  final Widget child;
  final Rect rect;
  final ValueChanged<Rect> onRectChanged;
  final double minWidth;
  final double minHeight;
  final double scale;

  const DraggableResizableWindow({
    Key? key,
    required this.child,
    required this.rect,
    required this.onRectChanged,
    this.minWidth = 100,
    this.minHeight = 60,
    this.scale = 1.0,
  }) : super(key: key);

  @override
  State<DraggableResizableWindow> createState() =>
      _DraggableResizableWindowState();
}

class _DraggableResizableWindowState extends State<DraggableResizableWindow> {
  // Resize handle size
  static const double _handleSize = 10.0;
  static const double _handleHitSize = 20.0; // Larger area for hit testing

  void _handleDrag(DragUpdateDetails details) {
    // Directly shift the rect by the drag delta.
    // Adjusted by scale factor to ensure sync movement.
    widget.onRectChanged(widget.rect.shift(details.delta / widget.scale));
  }

  void _handleResize(DragUpdateDetails details, Alignment alignment) {
    double dx = details.delta.dx / widget.scale;
    double dy = details.delta.dy / widget.scale;

    double newLeft = widget.rect.left;
    double newTop = widget.rect.top;
    double newWidth = widget.rect.width;
    double newHeight = widget.rect.height;

    // Horizontal resizing
    if (alignment.x == 1) {
      // Right side
      newWidth += dx;
    } else if (alignment.x == -1) {
      // Left side
      newLeft += dx;
      newWidth -= dx;
    }

    // Vertical resizing
    if (alignment.y == 1) {
      // Bottom side
      newHeight += dy;
    } else if (alignment.y == -1) {
      // Top side
      newTop += dy;
      newHeight -= dy;
    }

    // Min width constraints
    if (newWidth < widget.minWidth) {
      if (alignment.x == -1) {
        // If dragging left side, clamp left to right - minWidth
        newLeft = widget.rect.right - widget.minWidth;
      }
      newWidth = widget.minWidth;
    }

    // Min height constraints
    if (newHeight < widget.minHeight) {
      if (alignment.y == -1) {
        // If dragging top side, clamp top to bottom - minHeight
        newTop = widget.rect.bottom - widget.minHeight;
      }
      newHeight = widget.minHeight;
    }

    widget.onRectChanged(Rect.fromLTWH(newLeft, newTop, newWidth, newHeight));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Content with GestureDetector for dragging the window itself
        Positioned.fill(
          child: GestureDetector(
            onPanUpdate: _handleDrag,
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.topLeft,
              child: SizedBox(
                // We use a fixed size container inside FittedBox so that
                // the content renders at a "normal" size and then gets scaled.
                // However, FittedBox with child: widget.child works by scaling widget.child
                // to fit the available space (widget.rect).
                // If we just wrap widget.child, it will be scaled.
                child: widget.child,
              ),
            ),
          ),
        ),

        // 8 Resize Handles
        // Corners
        _buildPositionedHandle(Alignment.topLeft),
        _buildPositionedHandle(Alignment.topRight),
        _buildPositionedHandle(Alignment.bottomLeft),
        _buildPositionedHandle(Alignment.bottomRight),
        // Sides
        _buildPositionedHandle(Alignment.topCenter),
        _buildPositionedHandle(Alignment.bottomCenter),
        _buildPositionedHandle(Alignment.centerLeft),
        _buildPositionedHandle(Alignment.centerRight),
      ],
    );
  }

  Widget _buildPositionedHandle(Alignment alignment) {
    // Calculate position relative to the container edges
    // We want the handle center to be at the edge/corner.
    // So we offset by half the hit size.
    final offset = -_handleHitSize / 2;

    return Positioned(
      left: alignment.x == -1 ? offset : (alignment.x == 1 ? null : 0),
      right: alignment.x == 1 ? offset : (alignment.x == -1 ? null : 0),
      top: alignment.y == -1 ? offset : (alignment.y == 1 ? null : 0),
      bottom: alignment.y == 1 ? offset : (alignment.y == -1 ? null : 0),
      child: Center( // Center needed for the side handles if we set left=0,right=0
        child: GestureDetector(
          onPanUpdate: (details) => _handleResize(details, alignment),
          child: MouseRegion(
            cursor: _getCursorForAlignment(alignment),
            child: Container(
              // Hit area
              width: _handleHitSize,
              height: _handleHitSize,
              color: Colors.transparent, // Transparent hit area
              alignment: Alignment.center,
              child: Container(
                // Visual handle
                width: _handleSize,
                height: _handleSize,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.black54, width: 1),
                  shape: BoxShape.rectangle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
  
  MouseCursor _getCursorForAlignment(Alignment alignment) {
    if (alignment == Alignment.topLeft || alignment == Alignment.bottomRight) {
      return SystemMouseCursors.resizeUpLeftDownRight;
    }
    if (alignment == Alignment.topRight || alignment == Alignment.bottomLeft) {
      return SystemMouseCursors.resizeUpRightDownLeft;
    }
    if (alignment == Alignment.topCenter || alignment == Alignment.bottomCenter) {
      return SystemMouseCursors.resizeUpDown;
    }
    if (alignment == Alignment.centerLeft || alignment == Alignment.centerRight) {
      return SystemMouseCursors.resizeLeftRight;
    }
    return SystemMouseCursors.basic;
  }
}
