import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/hmi_protocol.dart';

final log = Logger('HMIServer');

/// Event emitted when a bank change command is received
class BankChangeEvent {
  final int bankId;
  BankChangeEvent(this.bankId);
}

/// Event emitted when a pedalboard change command is received
class PedalboardChangeEvent {
  final int index;
  PedalboardChangeEvent(this.index);
}

/// Event emitted when a pedalboard load command is received
class PedalboardLoadEvent {
  final int index;
  final String uri;
  PedalboardLoadEvent(this.index, this.uri);
}

/// Event emitted when tuner data is received
class TunerEvent {
  final double frequency;
  final String note;
  final int cents;

  TunerEvent(this.frequency, this.note, this.cents);

  /// Returns true if the tuner has a valid reading
  bool get isValid => note != '?';
}

/// Snapshot data
class Snapshot {
  final int index;
  final String name;

  Snapshot(this.index, this.name);
}

/// Event emitted when snapshots list is received
class SnapshotsEvent {
  final int currentIndex;
  final List<Snapshot> snapshots;

  SnapshotsEvent(this.currentIndex, this.snapshots);
}

/// Event emitted when a menu item value changes
class MenuItemEvent {
  final int menuId;
  final dynamic value;

  MenuItemEvent(this.menuId, this.value);
}

/// Event emitted when profiles list is received
class ProfilesEvent {
  final int currentIndex;
  final List<String> profiles;

  ProfilesEvent(this.currentIndex, this.profiles);
}

/// Event emitted when a file parameter current value is received
class FileParamEvent {
  final String instance;
  final String paramUri;
  final String path;

  FileParamEvent(this.instance, this.paramUri, this.path);
}

class HMIServer {
  late ServerSocket serverSocket;
  final List<Socket> _clients = [];
  final Map<Socket, List<int>> _buffers = {};

  // Current bank ID for pedalboard loading
  int _currentBankId = 1;

  // Stream controllers for events
  final _bankChangeController = StreamController<BankChangeEvent>.broadcast();
  final _pedalboardChangeController = StreamController<PedalboardChangeEvent>.broadcast();
  final _pedalboardLoadController = StreamController<PedalboardLoadEvent>.broadcast();
  final _tunerController = StreamController<TunerEvent>.broadcast();
  final _snapshotsController = StreamController<SnapshotsEvent>.broadcast();
  final _menuItemController = StreamController<MenuItemEvent>.broadcast();
  final _profilesController = StreamController<ProfilesEvent>.broadcast();
  final _fileParamController = StreamController<FileParamEvent>.broadcast();
  final _pedalboardClearController = StreamController<void>.broadcast();
  final _pedalboardReloadController = StreamController<void>.broadcast();

  /// Stream of bank change events
  Stream<BankChangeEvent> get onBankChange => _bankChangeController.stream;

  /// Stream of pedalboard change events
  Stream<PedalboardChangeEvent> get onPedalboardChange => _pedalboardChangeController.stream;

  /// Stream of pedalboard load events
  Stream<PedalboardLoadEvent> get onPedalboardLoad => _pedalboardLoadController.stream;

  /// Stream of pedalboard list reload events
  Stream<void> get onPedalboardReload => _pedalboardReloadController.stream;

  /// Stream of tuner events
  Stream<TunerEvent> get onTuner => _tunerController.stream;

  /// Stream of snapshots events
  Stream<SnapshotsEvent> get onSnapshots => _snapshotsController.stream;

  /// Stream of menu item events
  Stream<MenuItemEvent> get onMenuItem => _menuItemController.stream;

  /// Stream of profiles events
  Stream<ProfilesEvent> get onProfiles => _profilesController.stream;

  /// Stream of file parameter events
  Stream<FileParamEvent> get onFileParam => _fileParamController.stream;

  /// Stream of pedalboard clear events
  Stream<void> get onPedalboardClear => _pedalboardClearController.stream;

  HMIServer.init({int port = 9898}) {
    ServerSocket.bind(InternetAddress.anyIPv4, port).then((value) {
      serverSocket = value;
      log.info("Server is running at <${serverSocket.address.toString()}:${serverSocket.port}>");
      serverSocket.listen(
        (client) {
          handleNewClient(client);
        },
        onDone: () {
          serverSocket.close();
          log.info("Server closed.");
        },
      );
    });
  }

  void handleNewClient(Socket client) {
    final clientAddress = "${client.remoteAddress}:${client.remotePort}";
    log.info("<$clientAddress> connected.");
    _clients.add(client);
    _buffers[client] = [];

    client.listen(
      (data) {
        _buffers[client]!.addAll(data);
        _processBuffer(client);
      },
      onDone: () {
        _clients.remove(client);
        _buffers.remove(client);
        client.close();
        log.info("<$clientAddress> disconnected.");
      },
      onError: (error) {
        log.warning("<$clientAddress> error: $error");
        _clients.remove(client);
        _buffers.remove(client);
        client.close();
      },
    );
  }

  void _processBuffer(Socket client) {
    final buffer = _buffers[client]!;

    // Process all complete messages (null-terminated)
    while (true) {
      final nullIndex = buffer.indexOf(0);
      if (nullIndex == -1) break;

      // Extract the message
      final messageBytes = buffer.sublist(0, nullIndex);
      buffer.removeRange(0, nullIndex + 1);

      final message = String.fromCharCodes(messageBytes).trim();
      if (message.isNotEmpty) {
        _handleMessage(client, message);
      }
    }
  }

  void _handleMessage(Socket client, String message) {
    log.info("Received: $message");

    final parts = message.split(' ');
    if (parts.isEmpty) return;

    final command = parts[0];
    final args = parts.sublist(1);

    switch (command) {
      case HMIProtocol.CMD_PING:
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_GUI_CONNECTED:
        log.info("GUI connected notification received");
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_GUI_DISCONNECTED:
        log.info("GUI disconnected notification received");
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_PEDALBOARD_CLEAR:
        log.info("Pedalboard clear");
        _pedalboardClearController.add(null);
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_BANK_CHANGE:
        _handleBankChange(client, args);
        break;

      case HMIProtocol.CMD_PEDALBOARD_CHANGE:
        _handlePedalboardChange(client, args);
        break;

      case HMIProtocol.CMD_PEDALBOARD_RELOAD_LIST:
        log.info("Pedalboard list reload requested");
        _pedalboardReloadController.add(null);
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_PEDALBOARD_LOAD:
        _handlePedalboardLoad(client, args);
        break;

      case HMIProtocol.CMD_PEDALBOARD_NAME_SET:
        _handlePedalboardNameSet(client, args);
        break;

      case HMIProtocol.CMD_TUNER:
        _handleTuner(client, args);
        break;

      case HMIProtocol.CMD_SNAPSHOTS:
        _handleSnapshots(client, args);
        break;

      case HMIProtocol.CMD_MENU_ITEM_CHANGE:
        _handleMenuItemChange(client, args);
        break;

      case HMIProtocol.CMD_PROFILE_LOAD:
        _handleProfileLoad(client, args);
        break;

      case HMIProtocol.CMD_FILE_PARAM_CURRENT:
        _handleFileParamCurrent(client, args);
        break;

      case HMIProtocol.CMD_INITIAL_STATE:
        log.info("Initial state received");
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_DUO_BOOT:
        log.info("Boot notification received");
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_SNAPSHOT_NAME_SET:
        log.info("Snapshot name set: ${args.join(' ')}");
        _sendResponse(client, 0);
        break;

      case HMIProtocol.CMD_RESPONSE:
        log.fine("Response received: ${args.join(' ')}");
        break;

      default:
        log.warning("Unknown command: $command");
        _sendResponse(client, -1);
    }
  }

  void _handleBankChange(Socket client, List<String> args) {
    if (args.isEmpty) {
      log.warning("Bank change: missing bank ID argument");
      _sendResponse(client, -1);
      return;
    }

    final bankId = int.tryParse(args[0]);
    if (bankId == null) {
      log.warning("Bank change: invalid bank ID '${args[0]}'");
      _sendResponse(client, -1);
      return;
    }

    log.info("Bank change to: $bankId");
    _currentBankId = bankId;
    _bankChangeController.add(BankChangeEvent(bankId));
    _sendResponse(client, 0);
  }

  void _handlePedalboardChange(Socket client, List<String> args) {
    if (args.isEmpty) {
      log.warning("Pedalboard change: missing index argument");
      _sendResponse(client, -1);
      return;
    }

    final index = int.tryParse(args[0]);
    if (index == null) {
      log.warning("Pedalboard change: invalid index '${args[0]}'");
      _sendResponse(client, -1);
      return;
    }

    log.info("Pedalboard change to index: $index");
    _pedalboardChangeController.add(PedalboardChangeEvent(index));
    _sendResponse(client, 0);
  }

  void _handlePedalboardLoad(Socket client, List<String> args) {
    if (args.length < 2) {
      log.warning("Pedalboard load: missing arguments");
      _sendResponse(client, -1);
      return;
    }

    final index = int.tryParse(args[0]);
    if (index == null) {
      log.warning("Pedalboard load: invalid index '${args[0]}'");
      _sendResponse(client, -1);
      return;
    }

    final uri = args[1];
    log.info("Pedalboard load: index=$index, uri=$uri");
    _pedalboardLoadController.add(PedalboardLoadEvent(index, uri));
    _sendResponse(client, 0);
  }

  void _handlePedalboardNameSet(Socket client, List<String> args) {
    if (args.isEmpty) {
      log.warning("Pedalboard name set: missing name argument");
      _sendResponse(client, -1);
      return;
    }

    final name = args.join(' ');
    log.info("Pedalboard name set: $name");
    // Could emit an event here if needed
    _sendResponse(client, 0);
  }

  void _handleTuner(Socket client, List<String> args) {
    if (args.length < 3) {
      log.warning("Tuner: missing arguments");
      _sendResponse(client, -1);
      return;
    }

    final frequency = double.tryParse(args[0]) ?? 0;
    final note = args[1];
    final cents = int.tryParse(args[2]) ?? 0;

    log.fine("Tuner: freq=$frequency, note=$note, cents=$cents");
    _tunerController.add(TunerEvent(frequency, note, cents));
    _sendResponse(client, 0);
  }

  void _handleSnapshots(Socket client, List<String> args) {
    // Format: ssg current_index name1 name2 name3 ...
    if (args.isEmpty) {
      log.warning("Snapshots: missing arguments");
      _sendResponse(client, -1);
      return;
    }

    final currentIndex = int.tryParse(args[0]) ?? 0;
    final snapshots = <Snapshot>[];
    for (int i = 1; i < args.length; i++) {
      snapshots.add(Snapshot(i - 1, Uri.decodeComponent(args[i])));
    }

    log.info("Snapshots: current=$currentIndex, count=${snapshots.length}");
    _snapshotsController.add(SnapshotsEvent(currentIndex, snapshots));
    _sendResponse(client, 0);
  }

  void _handleMenuItemChange(Socket client, List<String> args) {
    // Format: c menu_id value
    if (args.length < 2) {
      log.warning("Menu item change: missing arguments");
      _sendResponse(client, -1);
      return;
    }

    final menuId = int.tryParse(args[0]);
    if (menuId == null) {
      log.warning("Menu item change: invalid menu_id '${args[0]}'");
      _sendResponse(client, -1);
      return;
    }

    // Value can be int or float depending on menu item
    dynamic value;
    if (args[1].contains('.')) {
      value = double.tryParse(args[1]) ?? 0.0;
    } else {
      value = int.tryParse(args[1]) ?? 0;
    }

    log.info("Menu item change: id=$menuId, value=$value");
    _menuItemController.add(MenuItemEvent(menuId, value));
    _sendResponse(client, 0);
  }

  void _handleProfileLoad(Socket client, List<String> args) {
    // Format: upr current_index profile1 profile2 ...
    if (args.isEmpty) {
      log.warning("Profile load: missing arguments");
      _sendResponse(client, -1);
      return;
    }

    final currentIndex = int.tryParse(args[0]) ?? 0;
    final profiles = args.sublist(1).map((p) => Uri.decodeComponent(p)).toList();

    log.info("Profiles: current=$currentIndex, count=${profiles.length}");
    _profilesController.add(ProfilesEvent(currentIndex, profiles));
    _sendResponse(client, 0);
  }

  void _handleFileParamCurrent(Socket client, List<String> args) {
    // Format: fpc instance paramuri path
    if (args.length < 3) {
      log.warning("File param current: missing arguments");
      _sendResponse(client, -1);
      return;
    }

    final instance = args[0];
    final paramUri = args[1];
    final path = args.sublist(2).join(' '); // Path may contain spaces

    log.info("File param current: instance=$instance, uri=$paramUri, path=$path");
    _fileParamController.add(FileParamEvent(instance, paramUri, path));
    _sendResponse(client, 0);
  }

  void _sendResponse(Socket client, int status, [String? data]) {
    final response = data != null
        ? "${HMIProtocol.CMD_RESPONSE} $status $data\x00"
        : "${HMIProtocol.CMD_RESPONSE} $status\x00";
    client.add(response.codeUnits);
    log.fine("Sent: $response");
  }

  /// Send a command to all connected clients
  void broadcast(String command) {
    final message = "$command\x00";
    for (final client in _clients) {
      client.add(message.codeUnits);
    }
    log.fine("Broadcast: $command");
  }

  /// Set the current bank ID for pedalboard operations
  void setCurrentBank(int bankId) {
    _currentBankId = bankId;
    log.info("Current bank set to: $bankId");
  }

  /// Get the current bank ID
  int get currentBankId => _currentBankId;

  /// Request mod-ui to load a pedalboard from the current bank
  void loadPedalboard(int pedalboardIndex, {int? bankId}) {
    final effectiveBankId = bankId ?? _currentBankId;
    final command = '${HMIProtocol.CMD_PEDALBOARD_LOAD} $effectiveBankId $pedalboardIndex';
    log.info("Requesting pedalboard load: bankId=$effectiveBankId, index=$pedalboardIndex");
    broadcast(command);
  }

  /// Set a plugin parameter value
  void setParameter(String instance, String portSymbol, double value) {
    final command = '${HMIProtocol.CMD_CONTROL_PARAM_SET} $instance $portSymbol $value';
    log.info("Setting parameter: $instance/$portSymbol = $value");
    broadcast(command);
  }

  /// Set a plugin file parameter value
  void setFileParameter(String instance, String paramUri, String path) {
    final command = '${HMIProtocol.CMD_FILE_PARAM_SET} $instance $paramUri $path';
    log.info("Setting file parameter: $instance/$paramUri = $path");
    broadcast(command);
  }

  /// Save the current pedalboard
  void savePedalboard() {
    log.info("Saving pedalboard");
    broadcast(HMIProtocol.CMD_PEDALBOARD_SAVE);
  }

  /// Turn the tuner on
  void tunerOn() {
    log.info("Turning tuner on");
    broadcast(HMIProtocol.CMD_TUNER_ON);
  }

  /// Turn the tuner off
  void tunerOff() {
    log.info("Turning tuner off");
    broadcast(HMIProtocol.CMD_TUNER_OFF);
  }

  /// Set the tuner input port (1 or 2)
  void setTunerInput(int port) {
    log.info("Setting tuner input to port $port");
    broadcast('${HMIProtocol.CMD_TUNER_INPUT} $port');
  }

  /// Set the tuner reference frequency (default 440Hz)
  void setTunerRefFreq(int freq) {
    log.info("Setting tuner reference frequency to $freq Hz");
    broadcast('${HMIProtocol.CMD_TUNER_REF_FREQ} $freq');
  }

  // ============ Snapshot Commands ============

  /// Request snapshots list
  void getSnapshots() {
    log.info("Requesting snapshots list");
    broadcast(HMIProtocol.CMD_SNAPSHOTS);
  }

  /// Load a snapshot by index
  void loadSnapshot(int index) {
    log.info("Loading snapshot $index");
    broadcast('${HMIProtocol.CMD_SNAPSHOTS_LOAD} $index');
  }

  /// Save current state to snapshot
  void saveSnapshot(int index) {
    log.info("Saving snapshot $index");
    broadcast('${HMIProtocol.CMD_SNAPSHOTS_SAVE} $index');
  }

  /// Save snapshot with new name
  void saveSnapshotAs(String name) {
    log.info("Saving snapshot as '$name'");
    broadcast('${HMIProtocol.CMD_SNAPSHOT_SAVE_AS} ${Uri.encodeComponent(name)}');
  }

  /// Delete a snapshot
  void deleteSnapshot(int index) {
    log.info("Deleting snapshot $index");
    broadcast('${HMIProtocol.CMD_SNAPSHOT_DELETE} $index');
  }

  /// Rename a snapshot
  void renameSnapshot(int index, String name) {
    log.info("Renaming snapshot $index to '$name'");
    broadcast('${HMIProtocol.CMD_SNAPSHOT_NAME_SET} $index ${Uri.encodeComponent(name)}');
  }

  // ============ Menu Item Commands ============

  /// Set a menu item value (tempo, bypass, MIDI settings, etc.)
  void setMenuItem(int menuId, dynamic value) {
    log.info("Setting menu item $menuId to $value");
    broadcast('${HMIProtocol.CMD_MENU_ITEM_CHANGE} $menuId $value');
  }

  /// Set tempo BPM
  void setTempo(double bpm) {
    setMenuItem(HMIProtocol.MENU_ID_TEMPO, bpm);
  }

  /// Set beats per bar
  void setBeatsPerBar(int beats) {
    setMenuItem(HMIProtocol.MENU_ID_BEATS_PER_BAR, beats);
  }

  /// Set play status (0=stopped, 1=playing)
  void setPlayStatus(bool playing) {
    setMenuItem(HMIProtocol.MENU_ID_PLAY_STATUS, playing ? 1 : 0);
  }

  /// Set quick bypass (0=off, 1=on)
  void setQuickBypass(bool bypassed) {
    setMenuItem(HMIProtocol.MENU_ID_QUICK_BYPASS, bypassed ? 1 : 0);
  }

  /// Set bypass for channel 1 (0=off, 1=on)
  void setBypass1(bool bypassed) {
    setMenuItem(HMIProtocol.MENU_ID_BYPASS1, bypassed ? 1 : 0);
  }

  /// Set bypass for channel 2 (0=off, 1=on)
  void setBypass2(bool bypassed) {
    setMenuItem(HMIProtocol.MENU_ID_BYPASS2, bypassed ? 1 : 0);
  }

  /// Set MIDI clock source (0=internal, 1=MIDI, 2=Ableton Link)
  void setMidiClockSource(int source) {
    setMenuItem(HMIProtocol.MENU_ID_MIDI_CLK_SOURCE, source);
  }

  /// Set MIDI clock send (0=off, 1=on)
  void setMidiClockSend(bool send) {
    setMenuItem(HMIProtocol.MENU_ID_MIDI_CLK_SEND, send ? 1 : 0);
  }

  // ============ Profile Commands ============

  /// Request profiles list
  void getProfiles() {
    log.info("Requesting profiles list");
    broadcast(HMIProtocol.CMD_PROFILE_LOAD);
  }

  /// Store current settings to a profile
  void storeProfile(int index) {
    log.info("Storing profile $index");
    broadcast('${HMIProtocol.CMD_PROFILE_STORE} $index');
  }

  /// Load a profile
  void loadProfile(int index) {
    log.info("Loading profile $index");
    broadcast('${HMIProtocol.CMD_PROFILE_LOAD} $index');
  }

  void dispose() {
    _pedalboardChangeController.close();
    _pedalboardLoadController.close();
    _tunerController.close();
    _snapshotsController.close();
    _menuItemController.close();
    _profilesController.close();
    _pedalboardClearController.close();
    for (final client in _clients) {
      client.close();
    }
    serverSocket.close();
  }
}
