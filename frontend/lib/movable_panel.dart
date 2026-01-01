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
    this.contentPadding = const EdgeInsets.all(12),
    this.backgroundColor = Colors.white,
    this.title,
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
    return Size(
      value.width.clamp(minSize.width, maxSize.width),
      value.height.clamp(minSize.height, maxSize.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clampedOffset = _clampOffset(offset, size);

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
              width: size.width,
              height: size.height,
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
                            onOffsetChanged(_clampOffset(offset + delta, size));
                          },
                          child: SizedBox(
                            height: 28,
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
                                        overflow: TextOverflow.ellipsis,
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
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) {
                          final nextSize = _clampSize(
                            Size(
                              size.width + d.delta.dx,
                              size.height + d.delta.dy,
                            ),
                          );
                          onSizeChanged(nextSize);
                          onOffsetChanged(_clampOffset(offset, nextSize));
                        },
                        child: const SizedBox(
                          width: 22,
                          height: 22,
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

