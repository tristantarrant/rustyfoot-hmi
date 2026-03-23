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

class PedalboardsWidget extends StatefulWidget {
  final HMIServer? hmiServer;
  final int bankId;
  final int activePedalboardIndex;

  const PedalboardsWidget({super.key, this.hmiServer, this.bankId = 1, this.activePedalboardIndex = 0});

  @override
  State<PedalboardsWidget> createState() => _PedalboardsWidgetState();
}

class _PedalboardsWidgetState extends State<PedalboardsWidget> {
  var pedalboards = <Pedalboard>[];
  var activePedalboard = -1;
  var _editMode = false;
  List<Pedal>? _pedals;
  bool _loadingPedals = false;
  Pedal? _selectedPedal;
  StreamSubscription<PedalboardLoadEvent>? _loadSubscription;
  StreamSubscription<FileParamEvent>? _fileParamSubscription;
  StreamSubscription<void>? _clearSubscription;
  StreamSubscription<void>? _reloadSubscription;
  StreamSubscription<MenuItemEvent>? _transportSubscription;
  PageController? _pageController;

  // Transport state
  double _bpm = 120.0;
  int _bpb = 4;
  bool _playing = false;
  Timer? _beatTimer;
  int _currentBeat = 0;

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
    load();
    _subscribeToHmiEvents();
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
        });
        _pageController?.animateToPage(
          targetIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });

    _clearSubscription = hmi.onPedalboardClear.listen((_) {
      log.info("HMI pedalboard clear event");
      setState(() {
        _editMode = false;
        _pedals = null;
        _selectedPedal = null;
      });
      _fileParamValues.clear();
    });

    _reloadSubscription = hmi.onPedalboardReload.listen((_) {
      log.info("HMI pedalboard list reload");
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
      }
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

  void _initTransportFromPedalboard(int index) {
    if (index >= 0 && index < pedalboards.length) {
      final pb = pedalboards[index];
      _bpm = pb.bpm;
      _bpb = pb.bpb;
    }
  }

  @override
  void didUpdateWidget(PedalboardsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bankId != oldWidget.bankId) {
      // Bank changed: reload pedalboard list in new bank order
      load();
    } else if (widget.activePedalboardIndex != oldWidget.activePedalboardIndex) {
      final targetIndex = widget.activePedalboardIndex;
      if (targetIndex >= 0 && targetIndex < pedalboards.length && targetIndex != activePedalboard) {
        setState(() {
          activePedalboard = targetIndex;
          _editMode = false;
          _pedals = null;
          _selectedPedal = null;
        });
        _pageController?.animateToPage(
          targetIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
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
    _stopBeatTimer();
    _pageController?.dispose();
    super.dispose();
  }

  Future load() async {
    var pedalboardsDir = Platform.environment['MOD_USER_PEDALBOARDS_DIR']
        ?? '${Platform.environment['HOME']}/.pedalboards';
    Directory dir = Directory(pedalboardsDir);
    log.info("Loading pedalboards from $dir for bank ${widget.bankId}");
    if (!dir.existsSync()) {
      log.warning("Pedalboards directory does not exist: $pedalboardsDir");
      return pedalboards;
    }

    // Load all pedalboards from disk into a map keyed by path
    var pDirs = dir.listSync(recursive: false).toList();
    final allPedalboards = <String, Pedalboard>{};
    for (var pDir in pDirs) {
      final pb = Pedalboard.load(pDir);
      if (pb != null) allPedalboards[pb.path] = pb;
    }

    // Build the new list without modifying state yet
    final newPedalboards = <Pedalboard>[];

    if (widget.bankId > 1) {
      // User bank selected: show only its pedalboards in bank order
      final banks = await Bank.loadAll();
      if (!mounted) return pedalboards;
      final bank = banks.where((b) => b.id == widget.bankId).firstOrNull;
      if (bank != null) {
        for (final bundle in bank.pedalboardBundles) {
          // Try exact match first, then try resolving symlinks
          final pb = allPedalboards[bundle] ??
              allPedalboards.values.where((p) {
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
      final sorted = allPedalboards.values.toList();
      sorted.sort((a, b) => a.path.compareTo(b.path));
      newPedalboards.addAll(sorted);
    }

    if (!mounted) return pedalboards;

    // Update state atomically — dispose old controller after the frame
    // to avoid disposing it while the PageView still references it
    final initialPage = newPedalboards.isEmpty
        ? 0
        : widget.activePedalboardIndex.clamp(0, newPedalboards.length - 1);
    final oldController = _pageController;
    _pageController = PageController(initialPage: initialPage);
    if (initialPage >= 0 && initialPage < newPedalboards.length) {
      _bpm = newPedalboards[initialPage].bpm;
      _bpb = newPedalboards[initialPage].bpb;
    }
    setState(() {
      pedalboards = newPedalboards;
      activePedalboard = initialPage;
      _editMode = false;
      _pedals = null;
      _selectedPedal = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController?.dispose();
    });
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
        ],
      ),
    );
  }

  Widget _buildPedalboardPage(int index) {
    final pedalboard = pedalboards[index];
    final thumbnailFile = File("${pedalboard.path}/thumbnail.png");
    final hasThumbnail = thumbnailFile.existsSync();
    final isActive = index == activePedalboard;

    return Stack(children: [
      Image.asset(
        'assets/pedalboard.png',
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      ),
      if (hasThumbnail)
        Image(image: FileImage(thumbnailFile)),
      Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 48),
          child: Text(
            pedalboard.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 50,
              fontWeight: FontWeight.bold,
              shadows: [
                Shadow(
                  color: Colors.black,
                  offset: Offset(5.0, 5.0),
                  blurRadius: 10.0,
                ),
                Shadow(
                  color: Colors.blue.shade200,
                  offset: Offset(-5.0, -5.0),
                  blurRadius: 8.0,
                ),
              ],
            ),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: _buildTransportBar(isActive),
      ),
    ]);
  }

  Widget _buildPedalboardView() {
    if (pedalboards.isEmpty || _pageController == null) {
      return Image.asset(
        'assets/pedalboard.png',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      );
    }

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
              });
              widget.hmiServer?.loadPedalboard(index);
            }
          },
          itemBuilder: (context, index) => _buildPedalboardPage(index),
        ),
        // Edit button overlay (above transport bar)
        Positioned(
          bottom: 52,
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
