import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_protocol.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';

final _log = Logger('MIDISettings');

class MIDISettingsWidget extends StatefulWidget {
  final HMIServer? hmiServer;

  const MIDISettingsWidget({super.key, this.hmiServer});

  @override
  State<MIDISettingsWidget> createState() => _MIDISettingsWidgetState();
}

class _MIDISettingsWidgetState extends State<MIDISettingsWidget> {
  int _clockSource = 0; // 0=Internal, 1=MIDI, 2=Ableton Link
  bool _clockSend = false;
  int _snapshotPrgChOffset = 0; // 0=disabled, >0 = PC offset for snapshots
  StreamSubscription<MenuItemEvent>? _subscription;

  static const _clockSourceLabels = ['Internal', 'MIDI', 'Ableton Link'];

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
          case HMIProtocol.MENU_ID_MIDI_CLK_SOURCE:
            _clockSource = event.value as int;
            break;
          case HMIProtocol.MENU_ID_MIDI_CLK_SEND:
            _clockSend = event.value == 1;
            break;
          case HMIProtocol.MENU_ID_SNAPSHOT_PRGCH_OFFSET:
            _snapshotPrgChOffset = event.value as int;
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

  void _setClockSource(int value) {
    setState(() {
      _clockSource = value;
    });
    _log.info('Setting MIDI clock source to $value');
    widget.hmiServer?.setMidiClockSource(value);
  }

  void _setSnapshotPrgChOffset(int value) {
    setState(() {
      _snapshotPrgChOffset = value;
    });
    _log.info('Setting snapshot PC offset to $value');
    widget.hmiServer?.setSnapshotPrgChOffset(value);
  }

  void _toggleClockSend() {
    final newState = !_clockSend;
    setState(() {
      _clockSend = newState;
    });
    _log.info('Setting MIDI clock send to $newState');
    widget.hmiServer?.setMidiClockSend(newState);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Clock source
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Clock Source',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<int>(
                    segments: [
                      for (int i = 0; i < _clockSourceLabels.length; i++)
                        ButtonSegment(
                          value: i,
                          label: Text(_clockSourceLabels[i]),
                          icon: Icon(_getClockSourceIcon(i)),
                        ),
                    ],
                    selected: {_clockSource},
                    onSelectionChanged: (values) {
                      _setClockSource(values.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _getClockSourceDescription(_clockSource),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Clock send
          Card(
            child: SwitchListTile(
              title: const Text('Send MIDI Clock'),
              subtitle: const Text('Transmit clock to connected MIDI devices'),
              value: _clockSend,
              onChanged: (value) => _toggleClockSend(),
              secondary: Icon(
                Icons.output,
                color: _clockSend ? Colors.green : null,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Snapshot PC offset
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Snapshot PC Offset',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _snapshotPrgChOffset == 0
                        ? 'Disabled. Snapshots can only be switched via a dedicated MIDI channel.'
                        : 'Program changes >= $_snapshotPrgChOffset on the pedalboard channel will switch snapshots. '
                          'PC $_snapshotPrgChOffset = snapshot 1, PC ${_snapshotPrgChOffset + 1} = snapshot 2, etc.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.music_note, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            activeTrackColor: Colors.orange,
                            thumbColor: Colors.orange,
                            inactiveTrackColor: Colors.white24,
                            overlayColor: Colors.orange.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            value: _snapshotPrgChOffset.toDouble(),
                            min: 0,
                            max: 127,
                            divisions: 127,
                            label: _snapshotPrgChOffset == 0 ? 'Off' : '$_snapshotPrgChOffset',
                            onChanged: (value) {
                              setState(() {
                                _snapshotPrgChOffset = value.round();
                              });
                            },
                            onChangeEnd: (value) {
                              _setSnapshotPrgChOffset(value.round());
                            },
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          _snapshotPrgChOffset == 0 ? 'Off' : '$_snapshotPrgChOffset',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getClockSourceIcon(int source) {
    switch (source) {
      case 0:
        return Icons.speed;
      case 1:
        return Icons.piano;
      case 2:
        return Icons.link;
      default:
        return Icons.help;
    }
  }

  String _getClockSourceDescription(int source) {
    switch (source) {
      case 0:
        return 'Use internal clock. Tempo is controlled by the device.';
      case 1:
        return 'Sync to external MIDI clock. Connect a MIDI source.';
      case 2:
        return 'Sync via Ableton Link over the network.';
      default:
        return '';
    }
  }
}
