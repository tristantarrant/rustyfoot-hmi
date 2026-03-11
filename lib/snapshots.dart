import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';

final _log = Logger('Snapshots');

class SnapshotsWidget extends StatefulWidget {
  final HMIServer? hmiServer;

  const SnapshotsWidget({super.key, this.hmiServer});

  @override
  State<SnapshotsWidget> createState() => _SnapshotsWidgetState();
}

class _SnapshotsWidgetState extends State<SnapshotsWidget> {
  List<Snapshot> _snapshots = [];
  int _currentIndex = -1;
  StreamSubscription<SnapshotsEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
    // Request snapshots list on load
    widget.hmiServer?.getSnapshots();
  }

  void _subscribe() {
    final hmi = widget.hmiServer;
    if (hmi == null) return;

    _subscription = hmi.onSnapshots.listen((event) {
      setState(() {
        _snapshots = event.snapshots;
        _currentIndex = event.currentIndex;
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _loadSnapshot(int index) {
    _log.info('Loading snapshot $index');
    widget.hmiServer?.loadSnapshot(index);
    setState(() {
      _currentIndex = index;
    });
  }

  void _saveSnapshot(int index) {
    _log.info('Saving snapshot $index');
    widget.hmiServer?.saveSnapshot(index);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Snapshot ${index + 1} saved'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _createSnapshot() {
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('New Snapshot'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Snapshot name',
              hintText: 'Enter snapshot name',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  widget.hmiServer?.saveSnapshotAs(name);
                  Navigator.pop(context);
                  // Refresh list
                  widget.hmiServer?.getSnapshots();
                }
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  void _deleteSnapshot(int index) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Snapshot'),
          content: Text('Delete snapshot "${_snapshots[index].name}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                widget.hmiServer?.deleteSnapshot(index);
                Navigator.pop(context);
                // Refresh list
                widget.hmiServer?.getSnapshots();
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _renameSnapshot(int index) {
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: _snapshots[index].name);
        return AlertDialog(
          title: const Text('Rename Snapshot'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Snapshot name',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  widget.hmiServer?.renameSnapshot(index, name);
                  Navigator.pop(context);
                  // Refresh list
                  widget.hmiServer?.getSnapshots();
                }
              },
              child: const Text('Rename'),
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
        Expanded(
          child: _snapshots.isEmpty
              ? const Center(child: Text('No snapshots'))
              : ListView.builder(
                  itemCount: _snapshots.length,
                  itemBuilder: (context, index) {
                    final snapshot = _snapshots[index];
                    final isSelected = index == _currentIndex;
                    return ListTile(
                      leading: Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        color: isSelected ? Colors.green : null,
                      ),
                      title: Text(snapshot.name),
                      subtitle: Text('Snapshot ${index + 1}'),
                      selected: isSelected,
                      onTap: () => _loadSnapshot(index),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          switch (value) {
                            case 'save':
                              _saveSnapshot(index);
                              break;
                            case 'rename':
                              _renameSnapshot(index);
                              break;
                            case 'delete':
                              _deleteSnapshot(index);
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'save',
                            child: Row(
                              children: [
                                Icon(Icons.save),
                                SizedBox(width: 8),
                                Text('Save'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                Icon(Icons.edit),
                                SizedBox(width: 8),
                                Text('Rename'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete),
                                SizedBox(width: 8),
                                Text('Delete'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton.icon(
            onPressed: _createSnapshot,
            icon: const Icon(Icons.add),
            label: const Text('New Snapshot'),
          ),
        ),
      ],
    );
  }
}
