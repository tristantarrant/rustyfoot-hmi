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
