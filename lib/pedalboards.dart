import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/bank.dart';
import 'package:rustyfoot_hmi/hmi_protocol.dart';
import 'package:rustyfoot_hmi/hmi_server.dart';
import 'package:rustyfoot_hmi/pedalboard.dart';
import 'package:rustyfoot_hmi/pedal.dart';
import 'package:rustyfoot_hmi/pedal_editor.dart';

final log = Logger('Pedalboards');

typedef PedalboardInfoCallback = void Function(String name, double bpm, int bpb);
typedef TransportChangeCallback = void Function(double bpm, int bpb);

class PedalboardsWidget extends StatefulWidget {
  final HMIServer? hmiServer;
  final int bankId;
  final int activePedalboardIndex;
  final PedalboardInfoCallback? onPedalboardInfo;
  final TransportChangeCallback? onTransportChanged;
  final double? liveBpm;
  final int? liveBpb;

  const PedalboardsWidget({super.key, this.hmiServer, this.bankId = 1, this.activePedalboardIndex = 0, this.onPedalboardInfo, this.onTransportChanged, this.liveBpm, this.liveBpb});

  @override
  State<PedalboardsWidget> createState() => _PedalboardsWidgetState();
}

class _PedalboardsWidgetState extends State<PedalboardsWidget> {
  var pedalboards = <Pedalboard>[];
  var activePedalboard = -1;
  var _editMode = false;
  bool _loadingPedalboards = true;
  List<Pedal>? _pedals;
  bool _loadingPedals = false;
  Pedal? _selectedPedal;
  StreamSubscription<PedalboardLoadEvent>? _loadSubscription;
  StreamSubscription<FileParamEvent>? _fileParamSubscription;
  StreamSubscription<void>? _clearSubscription;
  StreamSubscription<void>? _reloadSubscription;
  StreamSubscription<MenuItemEvent>? _transportSubscription;
  StreamSubscription<SnapshotsEvent>? _snapshotSubscription;
  PageController? _pageController;

  // Snapshot state
  List<Snapshot> _snapshots = [];
  int _currentSnapshotIndex = -1;

  // Transport state
  double _bpm = 120.0;
  int _bpb = 4;
  bool _playing = false;
  Timer? _beatTimer;
  int _currentBeat = 0;

  // System stats
  double _dspLoad = 0.0;
  double _memUsage = 0.0; // 0.0 to 1.0
  Timer? _memTimer;

  // Transport editor
  bool _transportEditorVisible = false;
  double _savedBpm = 120.0;
  int _savedBpb = 4;
  int? _lastTap;
  final List<double> _tapTempos = [];
  final ScrollController _bpbScrollController = ScrollController();

  bool get _transportModified => _bpm != _savedBpm || _bpb != _savedBpb;

  // Store file param values received from HMI (instance -> paramUri -> path)
  final Map<String, Map<String, String>> _fileParamValues = {};

  /// Normalize instance name by removing brackets and /graph/ prefix
  String _normalizeInstanceName(String name) {
    var result = name;
    if (result.startsWith('<')) {
      result = result.substring(1);
    }
    if (result.endsWith('>')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.startsWith('/graph/')) {
      result = result.substring(7); // Remove '/graph/'
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    if (widget.liveBpm != null) _bpm = widget.liveBpm!;
    if (widget.liveBpb != null) _bpb = widget.liveBpb!;
    load();
    _subscribeToHmiEvents();
    _updateMemUsage();
    _memTimer = Timer.periodic(const Duration(seconds: 3), (_) => _updateMemUsage());
  }

  void _subscribeToHmiEvents() {
    final hmi = widget.hmiServer;
    if (hmi == null) return;

    _loadSubscription = hmi.onPedalboardLoad.listen((event) {
      log.info("HMI pedalboard load event: index=${event.index}, uri=${event.uri}");
      // Find pedalboard by URI if possible, otherwise use index
      final idx = pedalboards.indexWhere((pb) => pb.path.endsWith(event.uri));
      int? targetIndex;
      if (idx >= 0) {
        targetIndex = idx;
      } else if (event.index >= 0 && event.index < pedalboards.length) {
        targetIndex = event.index;
      }
      if (targetIndex != null) {
        setState(() {
          activePedalboard = targetIndex!;
          _editMode = false;
          _pedals = null;
          _selectedPedal = null;
          _snapshots = [];
          _currentSnapshotIndex = -1;
        });
        _pageController?.jumpToPage(targetIndex);
        hmi.getSnapshots();
      }
    });

    _clearSubscription = hmi.onPedalboardClear.listen((_) {
      log.info("HMI pedalboard clear event");
      setState(() {
        _editMode = false;
        _pedals = null;
        _selectedPedal = null;
        _snapshots = [];
        _currentSnapshotIndex = -1;
      });
      _fileParamValues.clear();
    });

    _reloadSubscription = hmi.onPedalboardReload.listen((_) {
      log.info("HMI pedalboard list reload");
      setState(() { _loadingPedalboards = true; });
      load();
    });

    _transportSubscription = hmi.onMenuItem.listen((event) {
      switch (event.menuId) {
        case HMIProtocol.MENU_ID_TEMPO:
          setState(() {
            _bpm = (event.value as num).toDouble();
          });
          _restartBeatTimer();
          break;
        case HMIProtocol.MENU_ID_BEATS_PER_BAR:
          setState(() {
            _bpb = event.value as int;
            _currentBeat = 0;
          });
          break;
        case HMIProtocol.MENU_ID_PLAY_STATUS:
          setState(() {
            _playing = event.value == 1;
          });
          if (_playing) {
            _startBeatTimer();
          } else {
            _stopBeatTimer();
          }
          break;
        case HMIProtocol.MENU_ID_DSP_LOAD:
          setState(() {
            _dspLoad = (event.value as num).toDouble();
          });
          break;
      }
    });

    _snapshotSubscription = hmi.onSnapshots.listen((event) {
      if (!mounted) return;
      setState(() {
        _snapshots = event.snapshots;
        _currentSnapshotIndex = event.currentIndex;
      });
    });

    _fileParamSubscription = hmi.onFileParam.listen((event) {
      // Normalize the instance name from HMI (e.g., /graph/ratatouille -> ratatouille)
      final normalizedInstance = _normalizeInstanceName(event.instance);
      log.info("HMI file param event: instance=${event.instance} -> $normalizedInstance, uri=${event.paramUri}, path=${event.path}");

      // Store the value for later (when pedals are loaded)
      _fileParamValues.putIfAbsent(normalizedInstance, () => {});
      _fileParamValues[normalizedInstance]![event.paramUri] = event.path;

      // Also update pedals if they're already loaded
      _applyFileParamToPedals(normalizedInstance, event.paramUri, event.path);
    });
  }

  void _applyFileParamToPedals(String normalizedInstance, String paramUri, String path) {
    if (_pedals == null) return;

    for (final pedal in _pedals!) {
      // Check if this event is for this pedal (match instance name)
      final instanceName = _normalizeInstanceName(pedal.instanceName);
      if (instanceName == normalizedInstance) {
        // Update the file parameter
        if (pedal.fileParameters != null) {
          for (final param in pedal.fileParameters!) {
            if (param.uri == paramUri) {
              setState(() {
                param.currentPath = path;
              });
              log.info("Updated file param ${param.label} to $path");
              break;
            }
          }
        }
        break;
      }
    }
  }

  void _applyStoredFileParams() {
    if (_pedals == null) return;

    for (final pedal in _pedals!) {
      final instanceName = _normalizeInstanceName(pedal.instanceName);
      final storedParams = _fileParamValues[instanceName];
      if (storedParams != null && pedal.fileParameters != null) {
        for (final param in pedal.fileParameters!) {
          final storedPath = storedParams[param.uri];
          if (storedPath != null) {
            param.currentPath = storedPath;
            log.fine("Applied file param ${param.label} = $storedPath");
          }
        }
      }
    }
    // Trigger a rebuild to show the applied values
    setState(() {});
  }

  void _startBeatTimer() {
    _stopBeatTimer();
    final interval = Duration(milliseconds: (60000 / _bpm).round());
    _currentBeat = 0;
    _beatTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      setState(() {
        _currentBeat = (_currentBeat + 1) % _bpb;
      });
    });
  }

  void _stopBeatTimer() {
    _beatTimer?.cancel();
    _beatTimer = null;
    _currentBeat = 0;
  }

  void _restartBeatTimer() {
    if (_playing) _startBeatTimer();
  }

  void _updateMemUsage() {
    try {
      final content = File('/proc/meminfo').readAsStringSync();
      int? total, available;
      for (final line in content.split('\n')) {
        if (line.startsWith('MemTotal:')) {
          total = int.tryParse(line.split(RegExp(r'\s+'))[1]);
        } else if (line.startsWith('MemAvailable:')) {
          available = int.tryParse(line.split(RegExp(r'\s+'))[1]);
        }
        if (total != null && available != null) break;
      }
      if (total != null && available != null && total > 0) {
        if (!mounted) return;
        setState(() {
          _memUsage = (total! - available!) / total!;
        });
      }
    } catch (_) {}
  }

  void _initTransportFromPedalboard(int index) {
    if (index >= 0 && index < pedalboards.length) {
      final pb = pedalboards[index];
      _bpm = pb.bpm;
      _bpb = pb.bpb;
      _savedBpm = pb.bpm;
      _savedBpb = pb.bpb;
      widget.onPedalboardInfo?.call(pb.name, pb.bpm, pb.bpb);
    }
  }

  @override
  void didUpdateWidget(PedalboardsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync live transport values from parent
    if (widget.liveBpm != null && widget.liveBpm != _bpm) {
      _bpm = widget.liveBpm!;
    }
    if (widget.liveBpb != null && widget.liveBpb != _bpb) {
      _bpb = widget.liveBpb!;
    }
    if (widget.bankId != oldWidget.bankId) {
      // Bank changed: refilter cached pedalboards (no rescan needed)
      _applyFilter();
    } else if (widget.activePedalboardIndex != oldWidget.activePedalboardIndex) {
      final targetIndex = widget.activePedalboardIndex;
      if (targetIndex >= 0 && targetIndex < pedalboards.length && targetIndex != activePedalboard) {
        setState(() {
          activePedalboard = targetIndex;
          _editMode = false;
          _pedals = null;
          _selectedPedal = null;
          _snapshots = [];
          _currentSnapshotIndex = -1;
        });
        _pageController?.jumpToPage(targetIndex);
        widget.hmiServer?.getSnapshots();
      }
    }
  }

  @override
  void dispose() {
    _loadSubscription?.cancel();
    _fileParamSubscription?.cancel();
    _clearSubscription?.cancel();
    _reloadSubscription?.cancel();
    _transportSubscription?.cancel();
    _snapshotSubscription?.cancel();
    _memTimer?.cancel();
    _stopBeatTimer();
    _bpbScrollController.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  // Cached pedalboard data from disk — only rescanned on explicit reload
  Map<String, Pedalboard> _allPedalboards = {};

  /// Scan the filesystem for pedalboards and cache them.
  Future<void> _scanPedalboards() async {
    var pedalboardsDir = Platform.environment['MOD_USER_PEDALBOARDS_DIR']
        ?? '${Platform.environment['HOME']}/.pedalboards';
    Directory dir = Directory(pedalboardsDir);
    log.info("Scanning pedalboards from $dir");
    if (!dir.existsSync()) {
      log.warning("Pedalboards directory does not exist: $pedalboardsDir");
      _allPedalboards = {};
      return;
    }

    var pDirs = dir.listSync(recursive: false).toList();
    final scanned = <String, Pedalboard>{};
    for (var pDir in pDirs) {
      final pb = Pedalboard.load(pDir);
      if (pb != null) scanned[pb.path] = pb;
    }
    _allPedalboards = scanned;
  }

  /// Filter/order the cached pedalboards for the current bank.
  Future<List<Pedalboard>> _filterForBank() async {
    final newPedalboards = <Pedalboard>[];

    if (widget.bankId > 1) {
      // User bank selected: show only its pedalboards in bank order
      final banks = await Bank.loadAll();
      if (!mounted) return [];
      final bank = banks.where((b) => b.id == widget.bankId).firstOrNull;
      if (bank != null) {
        for (final bundle in bank.pedalboardBundles) {
          final pb = _allPedalboards[bundle] ??
              _allPedalboards.values.where((p) {
                try {
                  return Directory(p.path).resolveSymbolicLinksSync() ==
                      Directory(bundle).resolveSymbolicLinksSync();
                } catch (_) {
                  return false;
                }
              }).firstOrNull;
          if (pb != null) {
            newPedalboards.add(pb);
          } else {
            log.warning("Bank pedalboard not found on disk: $bundle");
          }
        }
      }
    } else {
      // "All Pedalboards": show all, sorted alphabetically by path
      final sorted = _allPedalboards.values.toList();
      sorted.sort((a, b) => a.path.compareTo(b.path));
      newPedalboards.addAll(sorted);
    }

    return newPedalboards;
  }

  /// Full reload: rescan filesystem, then filter for current bank.
  Future load() async {
    log.info("Loading pedalboards for bank ${widget.bankId}");
    await _scanPedalboards();
    await _applyFilter();
  }

  /// Apply bank filter on cached data (no filesystem rescan).
  Future _applyFilter() async {
    final newPedalboards = await _filterForBank();
    if (!mounted) return pedalboards;

    // Update state atomically — dispose old controller after the frame
    // to avoid disposing it while the PageView still references it
    final initialPage = newPedalboards.isEmpty
        ? 0
        : widget.activePedalboardIndex.clamp(0, newPedalboards.length - 1);
    final oldController = _pageController;
    _pageController = PageController(initialPage: initialPage);
    if (initialPage >= 0 && initialPage < newPedalboards.length) {
      final pb = newPedalboards[initialPage];
      // Only use TTL values if no live values were provided
      if (widget.liveBpm == null) _bpm = pb.bpm;
      if (widget.liveBpb == null) _bpb = pb.bpb;
      widget.onPedalboardInfo?.call(pb.name, _bpm, _bpb);
    }
    setState(() {
      pedalboards = newPedalboards;
      activePedalboard = initialPage;
      _loadingPedalboards = false;
      _editMode = false;
      _pedals = null;
      _selectedPedal = null;
      _snapshots = [];
      _currentSnapshotIndex = -1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController?.dispose();
    });
    // Request snapshots for the active pedalboard
    widget.hmiServer?.getSnapshots();
    return pedalboards;
  }

  @override
  String toStringShort() {
    return activePedalboard < 0 ? 'Pedalboard' : pedalboards[activePedalboard].name;
  }

  void _toggleEditMode() async {
    if (_editMode) {
      setState(() {
        _editMode = false;
      });
      // Jump to the active pedalboard page after rebuild
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController != null && _pageController!.hasClients) {
          _pageController!.jumpToPage(activePedalboard);
        }
      });
    } else {
      setState(() {
        _editMode = true;
        _loadingPedals = true;
      });

      // Load pedals for the current pedalboard
      if (activePedalboard >= 0 && activePedalboard < pedalboards.length) {
        final pedals = await pedalboards[activePedalboard].getPedals();
        // Apply stored file param values before setting state
        _pedals = pedals;
        _applyStoredFileParams();
        setState(() {
          _loadingPedals = false;
        });
      } else {
        setState(() {
          _loadingPedals = false;
        });
      }
    }
  }

  Widget _buildStatsOverlay() {
    final dspColor = _dspLoad > 80 ? Colors.red : (_dspLoad > 50 ? Colors.orange : Colors.green);
    final memColor = _memUsage > 0.85 ? Colors.red : (_memUsage > 0.65 ? Colors.orange : Colors.green);
    final memPct = (_memUsage * 100).round();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(8),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildStatBar('DSP', _dspLoad / 100, dspColor, '${_dspLoad.toStringAsFixed(0)}%'),
          const SizedBox(height: 2),
          _buildStatBar('MEM', _memUsage, memColor, '$memPct%'),
        ],
      ),
    );
  }

  Widget _buildStatBar(String label, double value, Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 9, fontFamily: 'monospace'),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 50,
          height: 6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(color: Colors.white70, fontSize: 9, fontFamily: 'monospace'),
        ),
      ],
    );
  }

  void _toggleTransportEditor() {
    setState(() {
      _transportEditorVisible = !_transportEditorVisible;
    });
    if (_transportEditorVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBpb());
    }
  }

  void _scrollToBpb() {
    if (!_bpbScrollController.hasClients) return;
    const segmentWidth = 40.0;
    final targetOffset = (_bpb - 1) * segmentWidth -
        (_bpbScrollController.position.viewportDimension / 2) +
        (segmentWidth / 2);
    _bpbScrollController.animateTo(
      targetOffset.clamp(0.0, _bpbScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _setTempo(double value) {
    setState(() { _bpm = value; });
  }

  void _commitTempo() {
    log.info('Setting tempo to $_bpm BPM');
    widget.hmiServer?.setTempo(_bpm);
    widget.onTransportChanged?.call(_bpm, _bpb);
  }

  void _setBeatsPerBar(int value) {
    setState(() {
      _bpb = value;
      _currentBeat = 0;
    });
    log.info('Setting beats per bar to $value');
    widget.hmiServer?.setBeatsPerBar(value);
    widget.onTransportChanged?.call(_bpm, _bpb);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBpb());
  }

  void _togglePlay() {
    final newState = !_playing;
    setState(() { _playing = newState; });
    log.info('Setting play status to $newState');
    widget.hmiServer?.setPlayStatus(newState);
    if (newState) {
      _startBeatTimer();
    } else {
      _stopBeatTimer();
    }
  }

  void _tapTempo() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTap != null) {
      final diff = now - _lastTap!;
      if (diff > 200 && diff < 2000) {
        final bpm = 60000.0 / diff;
        _tapTempos.add(bpm);
        if (_tapTempos.length > 4) _tapTempos.removeAt(0);
        final avgBpm = _tapTempos.reduce((a, b) => a + b) / _tapTempos.length;
        setState(() { _bpm = avgBpm.roundToDouble(); });
        widget.hmiServer?.setTempo(_bpm);
        widget.onTransportChanged?.call(_bpm, _bpb);
      }
    }
    _lastTap = now;
  }

  void _saveTransport() {
    log.info('Saving pedalboard transport');
    widget.hmiServer?.savePedalboard();
    setState(() {
      _savedBpm = _bpm;
      _savedBpb = _bpb;
    });
  }

  Widget _buildTransportBar(bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // BPM display
          Text(
            '${_bpm.toStringAsFixed(_bpm == _bpm.roundToDouble() ? 0 : 1)} BPM',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 24),
          // Time signature
          Text(
            '$_bpb/4',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 22,
              fontFamily: 'monospace',
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 24),
            // Beat indicators
            Row(
              children: List.generate(_bpb, (i) {
                final isCurrentBeat = _playing && i == _currentBeat;
                final isDownbeat = i == 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isCurrentBeat
                          ? (isDownbeat ? Colors.orange : Colors.white)
                          : Colors.white24,
                      boxShadow: isCurrentBeat
                          ? [BoxShadow(
                              color: isDownbeat
                                  ? Colors.orange.withValues(alpha: 0.6)
                                  : Colors.white.withValues(alpha: 0.4),
                              blurRadius: 8,
                              spreadRadius: 2,
                            )]
                          : null,
                    ),
                  ),
                );
              }),
            ),
          ],
          const Spacer(),
          Icon(
            _transportEditorVisible ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
            color: Colors.white54,
            size: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildTransportEditor() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        color: const Color(0xF01E1E1E),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // BPM slider row
          Row(
            children: [
              SizedBox(
                width: 100,
                child: Text(
                  '${_bpm.toStringAsFixed(1)} BPM',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: Colors.orange,
                    thumbColor: Colors.orange,
                    inactiveTrackColor: Colors.white24,
                    overlayColor: Colors.orange.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: _bpm.clamp(20, 280),
                    min: 20,
                    max: 280,
                    divisions: 260,
                    onChanged: _setTempo,
                    onChangeEnd: (_) => _commitTempo(),
                  ),
                ),
              ),
            ],
          ),
          // BPB + controls row
          Row(
            children: [
              const Text('BPB', style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: SingleChildScrollView(
                    controller: _bpbScrollController,
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<int>(
                      segments: List.generate(16, (i) {
                        final v = i + 1;
                        return ButtonSegment(value: v, label: Text('$v', style: const TextStyle(fontSize: 12)));
                      }),
                      selected: {_bpb.clamp(1, 16)},
                      onSelectionChanged: (values) => _setBeatsPerBar(values.first),
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected) ? Colors.black : Colors.white70),
                        backgroundColor: WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected) ? Colors.orange : Colors.transparent),
                        side: WidgetStateProperty.all(const BorderSide(color: Colors.white24)),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Play/Stop
              SizedBox(
                width: 40,
                height: 32,
                child: IconButton.filled(
                  onPressed: _togglePlay,
                  icon: Icon(_playing ? Icons.stop : Icons.play_arrow, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: _playing ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Tap tempo
              SizedBox(
                width: 40,
                height: 32,
                child: IconButton.outlined(
                  onPressed: _tapTempo,
                  icon: const Icon(Icons.touch_app, size: 18),
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_transportModified) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 32,
                  child: FilledButton.icon(
                    onPressed: _saveTransport,
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('Save', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  void _showSnapshotSelector() {
    if (_snapshots.length <= 1) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xF01E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Snapshots',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _snapshots.length,
                  itemBuilder: (context, index) {
                    final snapshot = _snapshots[index];
                    final isSelected = index == _currentSnapshotIndex;
                    return ListTile(
                      leading: Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        color: isSelected ? Colors.orange : Colors.white38,
                      ),
                      title: Text(
                        snapshot.name,
                        style: TextStyle(
                          color: isSelected ? Colors.orange : Colors.white,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        log.info('Loading snapshot $index: ${snapshot.name}');
                        widget.hmiServer?.loadSnapshot(index);
                        setState(() {
                          _currentSnapshotIndex = index;
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOutlinedText(String text, {required double fontSize, FontWeight fontWeight = FontWeight.bold}) {
    return Stack(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: fontWeight,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 6
              ..color = Colors.white,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: fontWeight,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = Colors.black,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: fontWeight,
          ),
        ),
      ],
    );
  }

  Widget _buildPedalboardPage(int index) {
    final pedalboard = pedalboards[index];

    final hasSnapshots = _snapshots.isNotEmpty;
    final currentSnapshotName = (_currentSnapshotIndex >= 0 && _currentSnapshotIndex < _snapshots.length)
        ? _snapshots[_currentSnapshotIndex].name
        : null;

    return Stack(children: [
      Image.asset(
        'assets/pedalboard.jpg',
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      ),
      Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 48),
          child: GestureDetector(
            onTap: _snapshots.length > 1 ? _showSnapshotSelector : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildOutlinedText(pedalboard.name, fontSize: 50),
                if (hasSnapshots && currentSnapshotName != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildOutlinedText(currentSnapshotName, fontSize: 24, fontWeight: FontWeight.w500),
                      if (_snapshots.length > 1) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.unfold_more, color: Colors.white70, size: 20),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildPedalboardView() {
    if (_loadingPedalboards || pedalboards.isEmpty || _pageController == null) {
      return Stack(
        children: [
          Image.asset(
            'assets/pedalboard.jpg',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          if (_loadingPedalboards)
            const Center(
              child: CircularProgressIndicator(color: Colors.orange),
            ),
        ],
      );
    }

    final isActive = activePedalboard >= 0 && activePedalboard < pedalboards.length;

    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          itemCount: pedalboards.length,
          onPageChanged: (index) {
            if (index != activePedalboard) {
              _initTransportFromPedalboard(index);
              setState(() {
                activePedalboard = index;
                _pedals = null;
                _selectedPedal = null;
                _snapshots = [];
                _currentSnapshotIndex = -1;
              });
              widget.hmiServer?.loadPedalboard(index);
              // Snapshot list will be refreshed when rustyfoot responds with ssg
            }
          },
          itemBuilder: (context, index) => _buildPedalboardPage(index),
        ),
        // Stats overlay (top right)
        Positioned(
          top: 0,
          right: 0,
          child: _buildStatsOverlay(),
        ),
        // Bottom panel: transport bar + slide-up editor
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Editor panel (slides up/down)
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                alignment: Alignment.bottomCenter,
                child: _transportEditorVisible
                    ? _buildTransportEditor()
                    : const SizedBox.shrink(),
              ),
              // Transport bar (always visible, tappable)
              GestureDetector(
                onTap: _toggleTransportEditor,
                child: _buildTransportBar(isActive),
              ),
            ],
          ),
        ),
        // Edit button overlay (above transport bar)
        Positioned(
          bottom: _transportEditorVisible ? 160 : 52,
          right: 8,
          child: FloatingActionButton.small(
            onPressed: _toggleEditMode,
            child: const Icon(Icons.edit),
          ),
        ),
      ],
    );
  }

  Widget _buildPedalListView() {
    if (_loadingPedals) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_pedals == null || _pedals!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('No pedals found'),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _toggleEditMode,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Header with back button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _toggleEditMode,
              ),
              Expanded(
                child: Text(
                  pedalboards[activePedalboard].name,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${_pedals!.length} pedals'),
            ],
          ),
        ),
        const Divider(height: 1),
        // Pedal list (horizontal scroll)
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            itemCount: _pedals!.length,
            itemBuilder: (context, index) {
              final pedal = _pedals![index];
              return _buildPedalTile(pedal);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPedalTile(Pedal pedal) {
    // Prefer screenshot (higher resolution) over thumbnail
    String? imagePath;
    if (pedal.screenshotPath != null && File(pedal.screenshotPath!).existsSync()) {
      imagePath = pedal.screenshotPath;
    } else if (pedal.thumbnailPath != null && File(pedal.thumbnailPath!).existsSync()) {
      imagePath = pedal.thumbnailPath;
    }

    return GestureDetector(
      onTap: () {
        log.info('Opening editor for pedal: ${pedal.label}');
        setState(() {
          _selectedPedal = pedal;
        });
      },
      child: SizedBox(
        width: 180,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: imagePath != null
                    ? Image.file(
                        File(imagePath),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: Colors.grey.shade300,
                            child: const Icon(Icons.extension, size: 32),
                          );
                        },
                      )
                    : Container(
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.extension, size: 32),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(4.0),
                child: Text(
                  pedal.label ?? pedal.instanceName,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPedalEditorView() {
    return PedalEditorWidget(
      pedal: _selectedPedal!,
      hmiServer: widget.hmiServer,
      onBack: () {
        setState(() {
          _selectedPedal = null;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_selectedPedal != null) {
      child = _buildPedalEditorView();
    } else if (_editMode) {
      child = _buildPedalListView();
    } else {
      child = _buildPedalboardView();
    }

    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: child,
    );
  }
}
