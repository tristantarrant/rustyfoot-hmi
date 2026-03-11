import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_protocol.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';

final _log = Logger('Bypass');

class BypassWidget extends StatefulWidget {
  final HMIServer? hmiServer;

  const BypassWidget({super.key, this.hmiServer});

  @override
  State<BypassWidget> createState() => _BypassWidgetState();
}

class _BypassWidgetState extends State<BypassWidget> {
  bool _quickBypass = false;
  bool _bypass1 = false;
  bool _bypass2 = false;
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
          case HMIProtocol.MENU_ID_QUICK_BYPASS:
            _quickBypass = event.value == 1;
            break;
          case HMIProtocol.MENU_ID_BYPASS1:
            _bypass1 = event.value == 1;
            break;
          case HMIProtocol.MENU_ID_BYPASS2:
            _bypass2 = event.value == 1;
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

  void _toggleQuickBypass() {
    final newState = !_quickBypass;
    setState(() {
      _quickBypass = newState;
    });
    _log.info('Setting quick bypass to $newState');
    widget.hmiServer?.setQuickBypass(newState);
  }

  void _toggleBypass1() {
    final newState = !_bypass1;
    setState(() {
      _bypass1 = newState;
    });
    _log.info('Setting bypass 1 to $newState');
    widget.hmiServer?.setBypass1(newState);
  }

  void _toggleBypass2() {
    final newState = !_bypass2;
    setState(() {
      _bypass2 = newState;
    });
    _log.info('Setting bypass 2 to $newState');
    widget.hmiServer?.setBypass2(newState);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Quick bypass - big button
          Expanded(
            flex: 2,
            child: Card(
              color: _quickBypass ? Colors.red.shade100 : null,
              child: InkWell(
                onTap: _toggleQuickBypass,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _quickBypass ? Icons.volume_off : Icons.volume_up,
                        size: 64,
                        color: _quickBypass ? Colors.red : Colors.green,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Quick Bypass',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _quickBypass ? 'BYPASSED' : 'ACTIVE',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: _quickBypass ? Colors.red : Colors.green,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Channel bypasses
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _buildChannelBypass(
                    'Input 1',
                    _bypass1,
                    _toggleBypass1,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildChannelBypass(
                    'Input 2',
                    _bypass2,
                    _toggleBypass2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelBypass(String label, bool bypassed, VoidCallback onTap) {
    return Card(
      color: bypassed ? Colors.orange.shade100 : null,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                bypassed ? Icons.volume_off : Icons.volume_up,
                size: 32,
                color: bypassed ? Colors.orange : Colors.green,
              ),
              const SizedBox(height: 8),
              Text(label),
              Text(
                bypassed ? 'BYPASS' : 'ACTIVE',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: bypassed ? Colors.orange : Colors.green,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
