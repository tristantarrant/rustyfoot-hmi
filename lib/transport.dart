import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_protocol.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';

final _log = Logger('Transport');

typedef TransportChangeCallback = void Function(double bpm, int bpb);

class TransportWidget extends StatefulWidget {
  final HMIServer? hmiServer;
  final String pedalboardName;
  final double initialBpm;
  final int initialBpb;
  final bool initialPlaying;
  final VoidCallback? onPedalboardTap;
  final TransportChangeCallback? onTransportChanged;

  const TransportWidget({
    super.key,
    this.hmiServer,
    this.pedalboardName = '',
    this.initialBpm = 120.0,
    this.initialBpb = 4,
    this.initialPlaying = false,
    this.onPedalboardTap,
    this.onTransportChanged,
  });

  @override
  State<TransportWidget> createState() => _TransportWidgetState();
}

class _TransportWidgetState extends State<TransportWidget> {
  late double _tempo;
  late int _beatsPerBar;
  late bool _playing;
  late double _savedTempo;
  late int _savedBpb;
  StreamSubscription<MenuItemEvent>? _subscription;
  final ScrollController _bpbScrollController = ScrollController();

  bool get _modified => _tempo != _savedTempo || _beatsPerBar != _savedBpb;

  @override
  void initState() {
    super.initState();
    _tempo = widget.initialBpm;
    _beatsPerBar = widget.initialBpb;
    _playing = widget.initialPlaying;
    _savedTempo = widget.initialBpm;
    _savedBpb = widget.initialBpb;
    _subscribe();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBpb());
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

  void _scrollToBpb() {
    if (!_bpbScrollController.hasClients) return;
    // Each segment is roughly 40px wide; center the selected one
    const segmentWidth = 40.0;
    final targetOffset = (_beatsPerBar - 1) * segmentWidth -
        (_bpbScrollController.position.viewportDimension / 2) +
        (segmentWidth / 2);
    _bpbScrollController.animateTo(
      targetOffset.clamp(0.0, _bpbScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _bpbScrollController.dispose();
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
    widget.onTransportChanged?.call(_tempo, _beatsPerBar);
  }

  void _setBeatsPerBar(int value) {
    setState(() {
      _beatsPerBar = value;
    });
    _log.info('Setting beats per bar to $value');
    widget.hmiServer?.setBeatsPerBar(value);
    widget.onTransportChanged?.call(_tempo, _beatsPerBar);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBpb());
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
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTap != null) {
      final diff = now - _lastTap!;
      if (diff > 200 && diff < 2000) {
        final bpm = 60000.0 / diff;
        _tapTempos.add(bpm);
        if (_tapTempos.length > 4) {
          _tapTempos.removeAt(0);
        }
        final avgBpm = _tapTempos.reduce((a, b) => a + b) / _tapTempos.length;
        setState(() {
          _tempo = avgBpm.roundToDouble();
        });
        widget.hmiServer?.setTempo(_tempo);
        widget.onTransportChanged?.call(_tempo, _beatsPerBar);
      }
    }
    _lastTap = now;
  }

  void _save() {
    _log.info('Saving pedalboard');
    widget.hmiServer?.savePedalboard();
    setState(() {
      _savedTempo = _tempo;
      _savedBpb = _beatsPerBar;
    });
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
          // Pedalboard name header
          if (widget.pedalboardName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: widget.onPedalboardTap,
                      child: Row(
                        children: [
                          const Icon(Icons.arrow_back, size: 18),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.pedalboardName,
                              style: Theme.of(context).textTheme.titleMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_modified)
                    FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save, size: 18),
                      label: const Text('Save'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                ],
              ),
            ),

          // Tempo display
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
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

          // Beats per bar
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Beats per bar'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _bpbScrollController,
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<int>(
                        segments: List.generate(16, (i) {
                          final v = i + 1;
                          return ButtonSegment(value: v, label: Text('$v'));
                        }),
                        selected: {_beatsPerBar.clamp(1, 16)},
                        onSelectionChanged: (values) {
                          _setBeatsPerBar(values.first);
                        },
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 4),

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
