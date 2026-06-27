import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A semantics-free swatch tile rendered entirely with [CustomPaint].
///
/// These deliberately expose no text or icon so Scout must rely on geometry,
/// keys, or ancestor context rather than visible labels.
class PaintedSwatch extends StatelessWidget {
  const PaintedSwatch({super.key, required this.seed, this.label});

  final int seed;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SwatchPainter(seed),
      child: label == null
          ? const SizedBox.expand()
          : Center(
              child: Text(
                label!,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.seed);

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final hue = (seed * 47) % 360;
    final base = HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.55).toColor();
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [base, base.withValues(alpha: 0.4)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Offset.zero & size);
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(12),
    );
    canvas.drawRRect(rrect, paint);

    final dot = Paint()..color = Colors.white.withValues(alpha: 0.25);
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(
        Offset(size.width * (0.2 + i * 0.2), size.height * 0.7),
        4 + (seed % 3),
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter oldDelegate) => oldDelegate.seed != seed;
}

/// A radial gauge painter used by the custom-painted dashboard.
class GaugePainter extends CustomPainter {
  GaugePainter({required this.value, required this.color});

  final double value; // 0..1
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    const startAngle = math.pi * 0.75;
    const sweep = math.pi * 1.5;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.2);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweep,
      false,
      track,
    );

    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweep * value.clamp(0.0, 1.0),
      false,
      progress,
    );
  }

  @override
  bool shouldRepaint(GaugePainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color;
}

/// A simple bar-chart painter (no semantics) for the dashboard screen.
class BarChartPainter extends CustomPainter {
  BarChartPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxValue = values.reduce(math.max);
    final barWidth = size.width / (values.length * 1.6);
    final gap = barWidth * 0.6;
    final paint = Paint()..color = color;

    for (var i = 0; i < values.length; i++) {
      final normalized = maxValue == 0 ? 0.0 : values[i] / maxValue;
      final barHeight = normalized * (size.height - 8);
      final left = gap / 2 + i * (barWidth + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - barHeight, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(BarChartPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
