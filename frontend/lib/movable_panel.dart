import 'dart:math' as math;

import 'package:flutter/material.dart';

class MovableResizablePanel extends StatelessWidget {
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

  Offset _clampOffset(Offset value, Size panelSize) {
    final scaledW = panelSize.width * scale;
    final scaledH = panelSize.height * scale;
    final maxDx = math.max(0.0, parentSize.width - scaledW);
    final maxDy = math.max(0.0, parentSize.height - scaledH);
    return Offset(
      value.dx.clamp(0.0, maxDx),
      value.dy.clamp(0.0, maxDy),
    );
  }

  Size _clampSize(Size value) {
    final viewportMaxW = parentSize.width.isFinite && parentSize.width > 0
        ? parentSize.width / scale
        : maxSize.width;
    final viewportMaxH = parentSize.height.isFinite && parentSize.height > 0
        ? parentSize.height / scale
        : maxSize.height;

    final effectiveMaxW = math.max(minSize.width, math.min(maxSize.width, viewportMaxW));
    final effectiveMaxH = math.max(minSize.height, math.min(maxSize.height, viewportMaxH));

    return Size(
      value.width.clamp(minSize.width, effectiveMaxW),
      value.height.clamp(minSize.height, effectiveMaxH),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clampedSize = _clampSize(size);
    final clampedOffset = _clampOffset(offset, clampedSize);

    return Transform.translate(
      offset: clampedOffset,
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.topLeft,
        child: Material(
          elevation: elevation,
          borderRadius: borderRadius,
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: borderRadius,
            child: SizedBox(
              width: clampedSize.width,
              height: clampedSize.height,
              child: DecoratedBox(
                decoration: BoxDecoration(color: backgroundColor),
                child: Stack(
                  children: [
                    Column(
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (d) {
                            final delta = Offset(
                              d.delta.dx * scale,
                              d.delta.dy * scale,
                            );
                            onOffsetChanged(
                              _clampOffset(clampedOffset + delta, clampedSize),
                            );
                          },
                          child: SizedBox(
                            height: 24,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.max,
                                children: [
                                  const Icon(Icons.drag_indicator, size: 18),
                                  if (title != null) ...[
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        title!,
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
                            padding: contentPadding,
                            child: child,
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      right: 0,
                      top: 24,
                      bottom: cornerHandleSize,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) {
                          final nextSize = _clampSize(
                            Size(
                              clampedSize.width + d.delta.dx,
                              clampedSize.height,
                            ),
                          );
                          onSizeChanged(nextSize);
                          onOffsetChanged(_clampOffset(clampedOffset, nextSize));
                        },
                        child: SizedBox(width: handleThickness),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: cornerHandleSize,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) {
                          final nextSize = _clampSize(
                            Size(
                              clampedSize.width,
                              clampedSize.height + d.delta.dy,
                            ),
                          );
                          onSizeChanged(nextSize);
                          onOffsetChanged(_clampOffset(clampedOffset, nextSize));
                        },
                        child: SizedBox(height: handleThickness),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) {
                          final nextSize = _clampSize(
                            Size(
                              clampedSize.width + d.delta.dx,
                              clampedSize.height + d.delta.dy,
                            ),
                          );
                          onSizeChanged(nextSize);
                          onOffsetChanged(_clampOffset(clampedOffset, nextSize));
                        },
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
