import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_protocol.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';

final _log = Logger('Transport');

class TransportWidget extends StatefulWidget {
  final HMIServer? hmiServer;

  const TransportWidget({super.key, this.hmiServer});

  @override
  State<TransportWidget> createState() => _TransportWidgetState();
}

class _TransportWidgetState extends State<TransportWidget> {
  double _tempo = 120.0;
  int _beatsPerBar = 4;
  bool _playing = false;
  StreamSubscription<MenuItemEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    final hmi = widget.hmiServer;
    if (hmi == null) return;

    _subscription = hmi.onMenuItem.listen((event) {
      setState(() {
        switch (event.menuId) {
          case HMIProtocol.MENU_ID_TEMPO:
            _tempo = (event.value as num).toDouble();
            break;
          case HMIProtocol.MENU_ID_BEATS_PER_BAR:
            _beatsPerBar = event.value as int;
            break;
          case HMIProtocol.MENU_ID_PLAY_STATUS:
            _playing = event.value == 1;
            break;
        }
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _setTempo(double value) {
    setState(() {
      _tempo = value;
    });
  }

  void _commitTempo() {
    _log.info('Setting tempo to $_tempo BPM');
    widget.hmiServer?.setTempo(_tempo);
  }

  void _setBeatsPerBar(int value) {
    setState(() {
      _beatsPerBar = value;
    });
    _log.info('Setting beats per bar to $value');
    widget.hmiServer?.setBeatsPerBar(value);
  }

  void _togglePlay() {
    final newState = !_playing;
    setState(() {
      _playing = newState;
    });
    _log.info('Setting play status to $newState');
    widget.hmiServer?.setPlayStatus(newState);
  }

  void _tapTempo() {
    // Simple tap tempo implementation
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTap != null) {
      final diff = now - _lastTap!;
      if (diff > 200 && diff < 2000) {
        // Valid tap interval (30-300 BPM range)
        final bpm = 60000.0 / diff;
        _tapTempos.add(bpm);
        if (_tapTempos.length > 4) {
          _tapTempos.removeAt(0);
        }
        // Average the last taps
        final avgBpm = _tapTempos.reduce((a, b) => a + b) / _tapTempos.length;
        setState(() {
          _tempo = avgBpm.roundToDouble();
        });
        widget.hmiServer?.setTempo(_tempo);
      }
    }
    _lastTap = now;
  }

  int? _lastTap;
  final List<double> _tapTempos = [];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tempo display
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                children: [
                  Text(
                    '${_tempo.toStringAsFixed(1)} BPM',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  Slider(
                    value: _tempo.clamp(20, 280),
                    min: 20,
                    max: 280,
                    divisions: 260,
                    label: _tempo.toStringAsFixed(0),
                    onChanged: _setTempo,
                    onChangeEnd: (_) => _commitTempo(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Beats per bar
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Beats per bar'),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 2, label: Text('2')),
                      ButtonSegment(value: 3, label: Text('3')),
                      ButtonSegment(value: 4, label: Text('4')),
                      ButtonSegment(value: 6, label: Text('6')),
                    ],
                    selected: {_beatsPerBar},
                    onSelectionChanged: (values) {
                      _setBeatsPerBar(values.first);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Transport controls
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ElevatedButton.icon(
                      onPressed: _togglePlay,
                      icon: Icon(_playing ? Icons.stop : Icons.play_arrow, size: 32),
                      label: Text(_playing ? 'Stop' : 'Play', style: const TextStyle(fontSize: 20)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _playing ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ElevatedButton.icon(
                      onPressed: _tapTempo,
                      icon: const Icon(Icons.touch_app, size: 32),
                      label: const Text('Tap', style: TextStyle(fontSize: 20)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
