import 'package:flutter/material.dart';
import 'package:rustyfoot_hmi/file_types.dart';
import 'package:rustyfoot_hmi/pedal.dart';

/// Widget for selecting a file for a file parameter
class FileParameterWidget extends StatelessWidget {
  final FileParameter parameter;
  final void Function(String path)? onFileSelected;

  const FileParameterWidget({
    super.key,
    required this.parameter,
    this.onFileSelected,
  });

  @override
  Widget build(BuildContext context) {
    final currentFileName = parameter.currentPath != null
        ? parameter.currentPath!.split('/').last
        : '(none)';

    return ListTile(
      title: Text(parameter.label),
      subtitle: Text(
        currentFileName,
        style: TextStyle(
          color: parameter.currentPath != null
              ? Theme.of(context).textTheme.bodySmall?.color
              : Colors.grey,
          fontStyle: parameter.currentPath != null
              ? FontStyle.normal
              : FontStyle.italic,
        ),
      ),
      trailing: const Icon(Icons.folder_open),
      onTap: () => _showFilePicker(context),
    );
  }

  void _showFilePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => _FilePickerSheet(
          parameter: parameter,
          scrollController: scrollController,
          onFileSelected: (path) {
            Navigator.of(context).pop();
            onFileSelected?.call(path);
          },
        ),
      ),
    );
  }
}

class _FilePickerSheet extends StatefulWidget {
  final FileParameter parameter;
  final ScrollController scrollController;
  final void Function(String path) onFileSelected;

  const _FilePickerSheet({
    required this.parameter,
    required this.scrollController,
    required this.onFileSelected,
  });

  @override
  State<_FilePickerSheet> createState() => _FilePickerSheetState();
}

class _FilePickerSheetState extends State<_FilePickerSheet> {
  List<FileInfo>? _files;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    try {
      final files = await FileTypes.listFiles(widget.parameter.fileTypes);
      if (mounted) {
        setState(() {
          _files = files;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Select ${widget.parameter.label}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'File types: ${widget.parameter.fileTypes.join(", ")}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // File list
        Expanded(
          child: _buildContent(),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Error loading files:\n$_error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }

    final files = _files ?? [];

    if (files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text(
                'No files found',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Upload files to the device to see them here.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: widget.scrollController,
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final isSelected = file.path == widget.parameter.currentPath;

        return ListTile(
          leading: Icon(
            _getFileIcon(file),
            color: isSelected ? Theme.of(context).primaryColor : null,
          ),
          title: Text(
            file.name,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
          subtitle: Text(
            file.fileType.label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: isSelected
              ? Icon(Icons.check, color: Theme.of(context).primaryColor)
              : null,
          onTap: () => widget.onFileSelected(file.path),
        );
      },
    );
  }

  IconData _getFileIcon(FileInfo file) {
    switch (file.fileType.id) {
      case 'audiosample':
        return Icons.audiotrack;
      case 'sf2':
      case 'sfz':
        return Icons.piano;
      case 'cabsim':
      case 'ir':
        return Icons.speaker;
      case 'aidadspmodel':
      case 'nammodel':
        return Icons.memory;
      case 'midifile':
        return Icons.music_note;
      default:
        return Icons.insert_drive_file;
    }
  }
}
