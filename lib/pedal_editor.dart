import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/file_parameter_widget.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';
import 'package:rustyfoot_hmi/pedal.dart';

final _log = Logger('PedalEditor');

class PedalEditorWidget extends StatefulWidget {
  final Pedal pedal;
  final HMIServer? hmiServer;
  final VoidCallback onBack;

  const PedalEditorWidget({
    super.key,
    required this.pedal,
    this.hmiServer,
    required this.onBack,
  });

  @override
  State<PedalEditorWidget> createState() => _PedalEditorWidgetState();
}

class _PedalEditorWidgetState extends State<PedalEditorWidget> {
  String? _selectedPortSymbol;

  void _selectPort(String? symbol) {
    setState(() {
      _selectedPortSymbol = _selectedPortSymbol == symbol ? null : symbol;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pedal = widget.pedal;
    final ports = pedal.controlPorts ?? [];
    final fileParams = pedal.fileParameters ?? [];

    // Filter to only show input control ports (not outputs)
    final inputPorts = ports.where((p) => !p.isOutput).toList();

    final hasFileParams = fileParams.isNotEmpty;
    final hasControlPorts = inputPorts.isNotEmpty;

    return Column(
      children: [
        // Header
        _buildHeader(pedal),
        const Divider(height: 1),
        // Parameters list
        Expanded(
          child: !hasFileParams && !hasControlPorts
              ? const Center(child: Text('No editable parameters'))
              : ListView(
                  children: [
                    // File parameters section
                    if (hasFileParams) ...[
                      _buildSectionHeader('Files'),
                      ...fileParams.map((param) => FileParameterWidget(
                        parameter: param,
                        onFileSelected: (path) => _onFileSelected(param, path),
                      )),
                    ],
                    // Control ports section
                    if (hasControlPorts) ...[
                      if (hasFileParams) _buildSectionHeader('Parameters'),
                      ...inputPorts.map((port) => _buildParameterTile(port)),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).primaryColor,
        ),
      ),
    );
  }

  void _onFileSelected(FileParameter param, String path) {
    setState(() {
      param.currentPath = path;
    });
    _sendFileParameterChange(param.uri, path);
  }

  void _savePedalboard() {
    final hmiServer = widget.hmiServer;
    if (hmiServer != null) {
      hmiServer.savePedalboard();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pedalboard saved'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Widget _buildHeader(Pedal pedal) {
    Widget thumbnail;
    if (pedal.thumbnailPath != null && File(pedal.thumbnailPath!).existsSync()) {
      thumbnail = Image.file(
        File(pedal.thumbnailPath!),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
      );
    } else {
      thumbnail = Container(
        width: 48,
        height: 48,
        color: Colors.grey.shade300,
        child: const Icon(Icons.extension),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onBack,
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: thumbnail,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pedal.label ?? pedal.instanceName,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                if (pedal.brand != null)
                  Text(
                    pedal.brand!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _savePedalboard,
            tooltip: 'Save pedalboard',
          ),
        ],
      ),
    );
  }

  Widget _buildParameterTile(ControlPort port) {
    if (port.isEnumeration && port.scalePoints.isNotEmpty) {
      return _buildEnumerationParameter(port);
    } else if (port.isToggled) {
      return _buildToggleParameter(port);
    } else if (port.isTrigger) {
      return _buildTriggerParameter(port);
    } else {
      return _buildSliderParameter(port);
    }
  }

  Widget _buildEnumerationParameter(ControlPort port) {
    // Find the current scale point (closest match)
    ScalePoint? currentPoint;
    for (final sp in port.scalePoints) {
      if (sp.value == port.currentValue) {
        currentPoint = sp;
        break;
      }
    }
    // Fallback: find closest value
    if (currentPoint == null && port.scalePoints.isNotEmpty) {
      currentPoint = port.scalePoints.reduce((a, b) =>
          (a.value - port.currentValue).abs() < (b.value - port.currentValue).abs() ? a : b);
    }

    return ListTile(
      title: Text(port.name),
      trailing: DropdownButton<double>(
        value: currentPoint?.value,
        items: port.scalePoints.map((sp) {
          return DropdownMenuItem<double>(
            value: sp.value,
            child: Text(sp.label),
          );
        }).toList(),
        onChanged: (value) {
          if (value != null) {
            setState(() {
              _selectedPortSymbol = null;
              port.currentValue = value;
            });
            _sendParameterChange(port.symbol, value);
          }
        },
      ),
    );
  }

  Widget _buildSliderParameter(ControlPort port) {
    final isSelected = _selectedPortSymbol == port.symbol;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectPort(port.symbol),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: isSelected
            ? Theme.of(context).primaryColor.withValues(alpha: 0.08)
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(port.name, style: Theme.of(context).textTheme.bodyMedium),
                Text(
                  port.isInteger
                      ? port.currentValue.round().toString()
                      : port.currentValue.toStringAsFixed(2),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            Slider(
              value: port.currentValue.clamp(port.minimum, port.maximum),
              min: port.minimum,
              max: port.maximum,
              divisions: port.isInteger
                  ? (port.maximum - port.minimum).round()
                  : null,
              onChanged: isSelected
                  ? (value) {
                      setState(() {
                        port.currentValue =
                            port.isInteger ? value.roundToDouble() : value;
                      });
                    }
                  : null,
              onChangeEnd: isSelected
                  ? (value) {
                      _sendParameterChange(port.symbol, value);
                    }
                  : null,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  port.isInteger
                      ? port.minimum.round().toString()
                      : port.minimum.toStringAsFixed(1),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Text(
                  port.isInteger
                      ? port.maximum.round().toString()
                      : port.maximum.toStringAsFixed(1),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleParameter(ControlPort port) {
    final isOn = port.currentValue >= 0.5;

    return SwitchListTile(
      title: Text(port.name),
      value: isOn,
      onChanged: (value) {
        setState(() {
          _selectedPortSymbol = null;
          port.currentValue = value ? 1.0 : 0.0;
        });
        _sendParameterChange(port.symbol, port.currentValue);
      },
    );
  }

  Widget _buildTriggerParameter(ControlPort port) {
    return ListTile(
      title: Text(port.name),
      trailing: ElevatedButton(
        onPressed: () {
          setState(() { _selectedPortSymbol = null; });
          _sendParameterChange(port.symbol, 1.0);
          // Triggers reset to 0 after being triggered
          Future.delayed(const Duration(milliseconds: 100), () {
            _sendParameterChange(port.symbol, 0.0);
          });
        },
        child: const Text('Trigger'),
      ),
    );
  }

  void _sendParameterChange(String portSymbol, double value) {
    final pedal = widget.pedal;
    // The instance name might have angle brackets, remove them
    var instance = pedal.instanceName;
    if (instance.startsWith('<')) {
      instance = instance.substring(1);
    }
    if (instance.endsWith('>')) {
      instance = instance.substring(0, instance.length - 1);
    }

    _log.info('Setting parameter: $instance/$portSymbol = $value');

    final hmiServer = widget.hmiServer;
    if (hmiServer != null) {
      hmiServer.setParameter(instance, portSymbol, value);
    } else {
      _log.warning('No HMI server available to send parameter change');
    }
  }

  void _sendFileParameterChange(String paramUri, String path) {
    final pedal = widget.pedal;
    // The instance name might have angle brackets, remove them
    var instance = pedal.instanceName;
    if (instance.startsWith('<')) {
      instance = instance.substring(1);
    }
    if (instance.endsWith('>')) {
      instance = instance.substring(0, instance.length - 1);
    }

    _log.info('Setting file parameter: $instance/$paramUri = $path');

    final hmiServer = widget.hmiServer;
    if (hmiServer != null) {
      hmiServer.setFileParameter(instance, paramUri, path);
    } else {
      _log.warning('No HMI server available to send file parameter change');
    }
  }
}
