import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';

final _log = Logger('Profiles');

class ProfilesWidget extends StatefulWidget {
  final HMIServer? hmiServer;

  const ProfilesWidget({super.key, this.hmiServer});

  @override
  State<ProfilesWidget> createState() => _ProfilesWidgetState();
}

class _ProfilesWidgetState extends State<ProfilesWidget> {
  List<String> _profiles = [];
  int _currentIndex = -1;
  StreamSubscription<ProfilesEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
    // Request profiles list on load
    widget.hmiServer?.getProfiles();
  }

  void _subscribe() {
    final hmi = widget.hmiServer;
    if (hmi == null) return;

    _subscription = hmi.onProfiles.listen((event) {
      setState(() {
        _profiles = event.profiles;
        _currentIndex = event.currentIndex;
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _loadProfile(int index) {
    _log.info('Loading profile $index');
    widget.hmiServer?.loadProfile(index);
    setState(() {
      _currentIndex = index;
    });
  }

  void _storeProfile(int index) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Store Profile'),
          content: Text('Store current settings to profile "${_profiles[index]}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                _log.info('Storing profile $index');
                widget.hmiServer?.storeProfile(index);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Profile "${_profiles[index]}" saved'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              child: const Text('Store'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Info card
        Card(
          margin: const EdgeInsets.all(16.0),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.blue),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Profiles store device settings like input/output gains, expression pedal modes, and system preferences.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Profiles list
        Expanded(
          child: _profiles.isEmpty
              ? const Center(child: Text('No profiles available'))
              : ListView.builder(
                  itemCount: _profiles.length,
                  itemBuilder: (context, index) {
                    final profile = _profiles[index];
                    final isSelected = index == _currentIndex;
                    return ListTile(
                      leading: Icon(
                        isSelected ? Icons.check_circle : Icons.person_outline,
                        color: isSelected ? Colors.green : null,
                      ),
                      title: Text(profile),
                      subtitle: Text('Profile ${index + 1}'),
                      selected: isSelected,
                      onTap: () => _loadProfile(index),
                      trailing: IconButton(
                        icon: const Icon(Icons.save),
                        onPressed: () => _storeProfile(index),
                        tooltip: 'Store current settings',
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
