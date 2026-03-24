import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/bank.dart';
import 'package:rustyfoot_hmi/banks.dart';
import 'package:rustyfoot_hmi/bypass.dart';
import 'package:rustyfoot_hmi/gpio_client.dart';
import 'package:rustyfoot_hmi/hmi_protocol.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';
import 'package:rustyfoot_hmi/midi_settings.dart';
import 'package:rustyfoot_hmi/pedalboards.dart';
import 'package:rustyfoot_hmi/profiles.dart';
import 'package:rustyfoot_hmi/qr.dart';
import 'package:rustyfoot_hmi/version.dart';
import 'package:rustyfoot_hmi/snapshots.dart';
import 'package:rustyfoot_hmi/tuner.dart';


const appName = 'Rustyfoot';
const accentColor = Colors.orange;
final log = Logger(appName);

void main() {
  _setupLogging();
  runApp(const UI());
}

void _setupLogging() {
  // Set log level based on build mode
  Logger.root.level = kDebugMode ? Level.ALL : Level.INFO;

  Logger.root.onRecord.listen((record) {
    // Skip noisy loggers
    if (record.loggerName == "term") return;

    // Map logging levels to severity for dart:developer
    final int level;
    switch (record.level.name) {
      case 'FINEST':
      case 'FINER':
      case 'FINE':
        level = 500; // DiagnosticLevel.debug
        break;
      case 'CONFIG':
      case 'INFO':
        level = 800; // DiagnosticLevel.info
        break;
      case 'WARNING':
        level = 900; // DiagnosticLevel.warning
        break;
      case 'SEVERE':
      case 'SHOUT':
        level = 1000; // DiagnosticLevel.error
        break;
      default:
        level = 800;
    }

    developer.log(
      record.message,
      time: record.time,
      level: level,
      name: record.loggerName,
      error: record.error,
      stackTrace: record.stackTrace,
    );
  });
}

class UI extends StatelessWidget {
  const UI({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: accentColor),
        useMaterial3: true,
      ),
      home: const PiEdeUI(title: appName),
    );
  }
}

class PiEdeUI extends StatefulWidget {
  const PiEdeUI({super.key, required this.title});

  final String title;

  @override
  State<PiEdeUI> createState() => _PiEdeUIState();
}

class _PiEdeUIState extends State<PiEdeUI> {
  final HMIServer hmiServer = HMIServer.init();
  final GPIOClient gpioClient = GPIOClient.init();
  final Widget qrWidget = Center(child: LocalAddressQRWidget());
  int _selectedWidget = 0;
  String _title = appName;

  // Bank state
  int _currentBankId = 1;
  String _currentBankName = 'All Pedalboards';

  // Active pedalboard index from HMI events
  int _activePedalboardIndex = 0;

  // Transport state (synced from HMI menu item events)
  double _bpm = 120.0;
  int _bpb = 4;

  @override
  void initState() {
    super.initState();
    _loadLastState();
    _subscribeToHmiEvents();
  }

  /// Load last bank and pedalboard from last.json
  Future<void> _loadLastState() async {
    final dataDir = Platform.environment['MOD_DATA_DIR'] ??
        '${Platform.environment['HOME']}/data';
    final lastFile = File('$dataDir/last.json');

    if (!await lastFile.exists()) {
      log.info('No last.json found');
      return;
    }

    try {
      final content = await lastFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final lastBank = json['bank'] as int? ?? -1;
      final lastPedalboard = json['pedalboard'] as String? ?? '';

      // Convert from last.json format (bank_id - 2) back to HMI bank ID
      final bankId = lastBank + 2;

      // Load banks to get the bank name and find pedalboard index
      final banks = await Bank.loadAll();
      if (!mounted) return;

      final bank = banks.where((b) => b.id == bankId).firstOrNull;
      final bankName = bank?.title ?? 'All Pedalboards';

      // Find pedalboard index within the bank
      int pedalboardIndex = 0;
      if (lastPedalboard.isNotEmpty && bank != null) {
        if (bankId > 1) {
          // User bank: find by bundle path
          final idx = bank.pedalboardBundles.indexOf(lastPedalboard);
          if (idx >= 0) pedalboardIndex = idx;
        } else {
          // "All Pedalboards": find by path in sorted pedalboard list
          final pedalboardsDir = Platform.environment['MOD_USER_PEDALBOARDS_DIR'] ??
              '${Platform.environment['HOME']}/.pedalboards';
          final dir = Directory(pedalboardsDir);
          if (dir.existsSync()) {
            final paths = dir.listSync(recursive: false)
                .map((e) => e.path)
                .where((p) => p.endsWith('.pedalboard'))
                .toList()
              ..sort();
            final idx = paths.indexOf(lastPedalboard);
            if (idx >= 0) pedalboardIndex = idx;
          }
        }
      }

      log.info('Restored last state: bank=$bankId ($bankName), pedalboard=$pedalboardIndex ($lastPedalboard)');

      setState(() {
        _currentBankId = bankId;
        _currentBankName = bankName;
        _activePedalboardIndex = pedalboardIndex;
      });
      hmiServer.setCurrentBank(bankId);
    } catch (e) {
      log.warning('Failed to load last state: $e');
    }
  }

  void _subscribeToHmiEvents() {
    hmiServer.onBankChange.listen((event) {
      log.info("Main: bank change event: bankId=${event.bankId}");
      _applyBankChange(event.bankId);
    });

    hmiServer.onPedalboardChange.listen((event) {
      log.info("Main: pedalboard change event: index=${event.index}");
      setState(() {
        _activePedalboardIndex = event.index;
        _selectedWidget = 0;
        _title = 'Pedalboards';
      });
    });

    hmiServer.onPedalboardLoad.listen((event) {
      log.info("Main: pedalboard load event: index=${event.index}, uri=${event.uri}");
      setState(() {
        _activePedalboardIndex = event.index;
        _selectedWidget = 0;
        _title = 'Pedalboards';
      });
    });

    hmiServer.onMenuItem.listen((event) {
      setState(() {
        switch (event.menuId) {
          case HMIProtocol.MENU_ID_TEMPO:
            _bpm = (event.value as num).toDouble();
            break;
          case HMIProtocol.MENU_ID_BEATS_PER_BAR:
            _bpb = event.value as int;
            break;
          case HMIProtocol.MENU_ID_PLAY_STATUS:
            break;
        }
      });
    });
  }

  Future<void> _applyBankChange(int bankId) async {
    final banks = await Bank.loadAll();
    if (!mounted) return;
    final bank = banks.where((b) => b.id == bankId).firstOrNull;
    final bankName = bank?.title ?? 'All Pedalboards';
    setState(() {
      _currentBankId = bankId;
      _currentBankName = bankName;
      _activePedalboardIndex = 0;
    });
  }

  void _onBankSelected(Bank bank) {
    setState(() {
      _currentBankId = bank.id;
      _currentBankName = bank.title;
      _activePedalboardIndex = 0;
      _selectedWidget = 0; // Switch back to pedalboards view
      _title = 'Pedalboards';
    });
    hmiServer.setCurrentBank(_currentBankId);
  }

  void _onPedalboard() {
    setState(() {
      _selectedWidget = 0;
      _title = 'Pedalboards';
    });
  }

  void _onBanks() {
    setState(() {
      _selectedWidget = 1;
      _title = 'Banks';
    });
  }

  void _onWiFi() {
    setState(() {
      _selectedWidget = 2;
      _title = 'Wi-Fi';
    });
  }

  void _onTuner() {
    setState(() {
      _selectedWidget = 3;
      _title = 'Tuner';
    });
  }

  void _onSnapshots() {
    setState(() {
      _selectedWidget = 4;
      _title = 'Snapshots';
    });
  }

  void _onBypass() {
    setState(() {
      _selectedWidget = 6;
      _title = 'Bypass';
    });
  }

  void _onMIDI() {
    setState(() {
      _selectedWidget = 7;
      _title = 'MIDI';
    });
  }

  void _onProfiles() {
    setState(() {
      _selectedWidget = 8;
      _title = 'Profiles';
    });
  }

  void _onPowerOff(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Power'),
          content: const Text('Shut down or restart the device?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              child: const Text('Exit to Shell'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _exitToShell();
              },
            ),
            TextButton(
              child: const Text('Restart'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _runPowerCommand('reboot');
              },
            ),
            TextButton(
              child: const Text('Shutdown'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _runPowerCommand('shutdown');
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _exitToShell() async {
    log.info('Exiting to shell');
    try {
      await Process.run('sudo', ['systemctl', 'stop', 'rustyfoot-hmi.service']);
    } catch (e) {
      log.warning('Failed to exit to shell: $e');
    }
  }

  Future<void> _runPowerCommand(String action) async {
    log.info(action);
    final args = action == 'reboot' ? ['reboot'] : ['shutdown', 'now'];
    try {
      await Process.run('sudo', args);
    } catch (e) {
      log.warning('Failed to $action: $e');
    }
  }

  Widget _buildBody() {
    switch (_selectedWidget) {
      case 0:
        return PedalboardsWidget(
          hmiServer: hmiServer,
          bankId: _currentBankId,
          activePedalboardIndex: _activePedalboardIndex,
          liveBpm: _bpm,
          liveBpb: _bpb,
          onPedalboardInfo: (name, bpm, bpb) {
            setState(() {
              _bpm = bpm;
              _bpb = bpb.toInt();
            });
          },
          onTransportChanged: (bpm, bpb) {
            setState(() {
              _bpm = bpm;
              _bpb = bpb;
            });
          },
        );
      case 1:
        return BanksWidget(
          selectedBankId: _currentBankId,
          onBankSelected: _onBankSelected,
        );
      case 2:
        return qrWidget;
      case 3:
        return TunerWidget(hmiServer: hmiServer);
      case 4:
        return SnapshotsWidget(hmiServer: hmiServer);
      case 5:
        return const Center(child: Text('Transport'));
      case 6:
        return BypassWidget(hmiServer: hmiServer);
      case 7:
        return MIDISettingsWidget(hmiServer: hmiServer);
      case 8:
        return ProfilesWidget(hmiServer: hmiServer);
      default:
        return const Center(child: Text('Unknown view'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: accentColor,
        toolbarHeight: 34,
        title: Text(_title),
        leading: Builder(
          builder: (context) {
            return IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () {
                Scaffold.of(context).openDrawer();
              },
            );
          },
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Center(
              child: Text(
                '$_currentBankName  [$gitCommit]',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      body: _buildBody(),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            ListTile(
              leading: const Icon(Icons.music_note),
              title: const Text('Pedalboards'),
              selected: _selectedWidget == 0,
              onTap: () {
                _onPedalboard();
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('Banks'),
              selected: _selectedWidget == 1,
              onTap: () {
                _onBanks();
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera),
              title: const Text('Snapshots'),
              selected: _selectedWidget == 4,
              onTap: () {
                _onSnapshots();
                Navigator.pop(context);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Tuner'),
              selected: _selectedWidget == 3,
              onTap: () {
                _onTuner();
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.volume_off),
              title: const Text('Bypass'),
              selected: _selectedWidget == 6,
              onTap: () {
                _onBypass();
                Navigator.pop(context);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.piano),
              title: const Text('MIDI'),
              selected: _selectedWidget == 7,
              onTap: () {
                _onMIDI();
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Profiles'),
              selected: _selectedWidget == 8,
              onTap: () {
                _onProfiles();
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.wifi),
              title: const Text('Wi-Fi'),
              selected: _selectedWidget == 2,
              onTap: () {
                _onWiFi();
                Navigator.pop(context);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.power_settings_new),
              title: const Text('Power'),
              onTap: () {
                Navigator.pop(context);
                _onPowerOff(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
