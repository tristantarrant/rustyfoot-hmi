import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';

final _log = Logger('Tuner');

class TunerWidget extends StatefulWidget {
  final HMIServer? hmiServer;

  const TunerWidget({super.key, this.hmiServer});

  @override
  State<TunerWidget> createState() => _TunerWidgetState();
}

class _TunerWidgetState extends State<TunerWidget> {
  bool _tunerActive = false;
  String _note = '-';
  double _frequency = 0;
  int _cents = 0;
  StreamSubscription<TunerEvent>? _tunerSubscription;

  @override
  void initState() {
    super.initState();
    _subscribeToTuner();
  }

  void _subscribeToTuner() {
    final hmi = widget.hmiServer;
    if (hmi == null) return;

    _tunerSubscription = hmi.onTuner.listen((event) {
      setState(() {
        _frequency = event.frequency;
        _note = event.note;
        _cents = event.cents;
      });
    });
  }

  @override
  void dispose() {
    _tunerSubscription?.cancel();
    // Turn off tuner when leaving
    if (_tunerActive) {
      widget.hmiServer?.tunerOff();
    }
    super.dispose();
  }

  void _toggleTuner() {
    final hmi = widget.hmiServer;
    if (hmi == null) return;

    setState(() {
      _tunerActive = !_tunerActive;
    });

    if (_tunerActive) {
      hmi.tunerOn();
      _log.info('Tuner turned on');
    } else {
      hmi.tunerOff();
      _log.info('Tuner turned off');
      // Reset display
      setState(() {
        _note = '-';
        _frequency = 0;
        _cents = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Tuner display
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _buildTunerDisplay(),
            ),
          ),
        ),
        // Controls
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _toggleTuner,
                icon: Icon(_tunerActive ? Icons.stop : Icons.play_arrow),
                label: Text(_tunerActive ? 'Stop' : 'Start'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _tunerActive ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTunerDisplay() {
    final isInTune = _cents.abs() < 5;
    final noteColor = !_tunerActive
        ? Colors.grey
        : _note == '?'
            ? Colors.grey
            : isInTune
                ? Colors.green
                : Colors.white;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Cents indicator
        _buildCentsIndicator(),
        const SizedBox(height: 24),
        // Note display
        Text(
          _note,
          style: TextStyle(
            fontSize: 120,
            fontWeight: FontWeight.bold,
            color: noteColor,
          ),
        ),
        const SizedBox(height: 8),
        // Frequency display
        Text(
          _frequency > 0 ? '${_frequency.toStringAsFixed(1)} Hz' : '',
          style: TextStyle(
            fontSize: 24,
            color: Colors.grey.shade400,
          ),
        ),
        const SizedBox(height: 8),
        // Cents display
        Text(
          _tunerActive && _note != '?' && _note != '-'
              ? '${_cents > 0 ? '+' : ''}$_cents cents'
              : '',
          style: TextStyle(
            fontSize: 20,
            color: isInTune ? Colors.green : Colors.orange,
          ),
        ),
      ],
    );
  }

  Widget _buildCentsIndicator() {
    return SizedBox(
      width: 300,
      height: 60,
      child: CustomPaint(
        painter: _CentsIndicatorPainter(
          cents: _cents,
          isActive: _tunerActive && _note != '?' && _note != '-',
        ),
      ),
    );
  }
}

class _CentsIndicatorPainter extends CustomPainter {
  final int cents;
  final bool isActive;

  _CentsIndicatorPainter({required this.cents, required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    // Draw background track
    final trackPaint = Paint()
      ..color = Colors.grey.shade800
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - 10, size.width, 20),
        const Radius.circular(10),
      ),
      trackPaint,
    );

    // Draw center marker
    final centerPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.fill;

    canvas.drawRect(
      Rect.fromLTWH(centerX - 2, centerY - 20, 4, 40),
      centerPaint,
    );

    // Draw tick marks
    final tickPaint = Paint()
      ..color = Colors.grey.shade600
      ..style = PaintingStyle.fill;

    for (int i = -4; i <= 4; i++) {
      if (i == 0) continue;
      final x = centerX + (i * size.width / 10);
      canvas.drawRect(
        Rect.fromLTWH(x - 1, centerY - 8, 2, 16),
        tickPaint,
      );
    }

    // Draw indicator needle
    if (isActive) {
      // Clamp cents to visible range (-50 to +50)
      final clampedCents = cents.clamp(-50, 50);
      final needleX = centerX + (clampedCents / 50 * size.width / 2);

      final isInTune = cents.abs() < 5;
      final needlePaint = Paint()
        ..color = isInTune ? Colors.green : Colors.orange
        ..style = PaintingStyle.fill;

      // Draw needle as triangle
      final path = Path()
        ..moveTo(needleX, centerY - 25)
        ..lineTo(needleX - 8, centerY + 15)
        ..lineTo(needleX + 8, centerY + 15)
        ..close();

      canvas.drawPath(path, needlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CentsIndicatorPainter oldDelegate) {
    return oldDelegate.cents != cents || oldDelegate.isActive != isActive;
  }
}
