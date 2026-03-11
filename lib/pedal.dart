import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:rdflib/rdflib.dart';

final _log = Logger('Pedal');

/// Represents a scale point (enumeration value) on a control port
class ScalePoint {
  final String label;
  final double value;

  ScalePoint({required this.label, required this.value});

  Map<String, dynamic> toJson() => {
    'label': label,
    'value': value,
  };

  factory ScalePoint.fromJson(Map<String, dynamic> json) => ScalePoint(
    label: json['label'],
    value: (json['value'] as num).toDouble(),
  );
}

/// Represents a file parameter (atom:Path) on a plugin
class FileParameter {
  final String uri;
  final String label;
  final List<String> fileTypes;
  String? currentPath;

  FileParameter({
    required this.uri,
    required this.label,
    required this.fileTypes,
    this.currentPath,
  });

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'label': label,
    'fileTypes': fileTypes,
    'currentPath': currentPath,
  };

  factory FileParameter.fromJson(Map<String, dynamic> json) => FileParameter(
    uri: json['uri'],
    label: json['label'],
    fileTypes: List<String>.from(json['fileTypes'] ?? []),
    currentPath: json['currentPath'],
  );

  @override
  String toString() => 'FileParameter($label: $currentPath)';
}

/// Represents a control port (parameter) on a plugin
class ControlPort {
  final String symbol;
  final String name;
  final double minimum;
  final double maximum;
  final double defaultValue;
  final bool isToggled;
  final bool isInteger;
  final bool isTrigger;
  final bool isOutput;
  final bool isEnumeration;
  final List<ScalePoint> scalePoints;
  double currentValue;

  ControlPort({
    required this.symbol,
    required this.name,
    required this.minimum,
    required this.maximum,
    required this.defaultValue,
    this.isToggled = false,
    this.isInteger = false,
    this.isTrigger = false,
    this.isOutput = false,
    this.isEnumeration = false,
    List<ScalePoint>? scalePoints,
    double? currentValue,
  }) : scalePoints = scalePoints ?? [],
       currentValue = currentValue ?? defaultValue;

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'name': name,
    'minimum': minimum,
    'maximum': maximum,
    'defaultValue': defaultValue,
    'isToggled': isToggled,
    'isInteger': isInteger,
    'isTrigger': isTrigger,
    'isOutput': isOutput,
    'isEnumeration': isEnumeration,
    'scalePoints': scalePoints.map((sp) => sp.toJson()).toList(),
  };

  factory ControlPort.fromJson(Map<String, dynamic> json) => ControlPort(
    symbol: json['symbol'],
    name: json['name'],
    minimum: (json['minimum'] as num).toDouble(),
    maximum: (json['maximum'] as num).toDouble(),
    defaultValue: (json['defaultValue'] as num).toDouble(),
    isToggled: json['isToggled'] ?? false,
    isInteger: json['isInteger'] ?? false,
    isTrigger: json['isTrigger'] ?? false,
    isOutput: json['isOutput'] ?? false,
    isEnumeration: json['isEnumeration'] ?? false,
    scalePoints: (json['scalePoints'] as List?)
        ?.map((sp) => ScalePoint.fromJson(sp))
        .toList(),
  );

  @override
  String toString() => 'ControlPort($symbol: $currentValue [$minimum-$maximum])';
}

/// Represents an LV2 plugin instance within a pedalboard
class Pedal {
  final String instanceName;
  final String pluginUri;
  final int instanceNumber;
  final bool enabled;
  final Map<String, double> portValues;
  final Map<String, String> fileValues;

  // Plugin metadata (loaded from LV2 bundle)
  String? label;
  String? brand;
  String? thumbnailPath;
  String? screenshotPath;
  List<ControlPort>? controlPorts;
  List<FileParameter>? fileParameters;

  Pedal({
    required this.instanceName,
    required this.pluginUri,
    required this.instanceNumber,
    required this.enabled,
    Map<String, double>? portValues,
    Map<String, String>? fileValues,
  }) : portValues = portValues ?? {},
       fileValues = fileValues ?? {};

  /// Load plugin metadata from its LV2 bundle
  Future<void> loadMetadata(LV2PluginCache cache) async {
    final info = await cache.getPluginInfo(pluginUri);
    if (info != null) {
      label = info.label;
      brand = info.brand;
      thumbnailPath = info.thumbnailPath;
      screenshotPath = info.screenshotPath;

      // Load control ports and apply current values
      controlPorts = info.controlPorts.map((port) {
        final currentVal = portValues[port.symbol];
        return ControlPort(
          symbol: port.symbol,
          name: port.name,
          minimum: port.minimum,
          maximum: port.maximum,
          defaultValue: port.defaultValue,
          isToggled: port.isToggled,
          isInteger: port.isInteger,
          isTrigger: port.isTrigger,
          isOutput: port.isOutput,
          isEnumeration: port.isEnumeration,
          scalePoints: port.scalePoints,
          currentValue: currentVal,
        );
      }).toList();

      // Load file parameters and apply current values
      fileParameters = info.fileParameters.map((param) {
        final currentPath = fileValues[param.uri];
        return FileParameter(
          uri: param.uri,
          label: param.label,
          fileTypes: param.fileTypes,
          currentPath: currentPath,
        );
      }).toList();
    }
  }

  @override
  String toString() => 'Pedal($instanceName: $pluginUri)';
}

/// Information about an LV2 plugin from its modgui.ttl and main TTL
class LV2PluginInfo {
  final String uri;
  final String bundlePath;
  final String? label;
  final String? brand;
  final String? thumbnailPath;
  final String? screenshotPath;
  final List<ControlPort> controlPorts;
  final List<FileParameter> fileParameters;

  LV2PluginInfo({
    required this.uri,
    required this.bundlePath,
    this.label,
    this.brand,
    this.thumbnailPath,
    this.screenshotPath,
    List<ControlPort>? controlPorts,
    List<FileParameter>? fileParameters,
  }) : controlPorts = controlPorts ?? [],
       fileParameters = fileParameters ?? [];

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'bundlePath': bundlePath,
    'label': label,
    'brand': brand,
    'thumbnailPath': thumbnailPath,
    'screenshotPath': screenshotPath,
    'controlPorts': controlPorts.map((p) => p.toJson()).toList(),
    'fileParameters': fileParameters.map((p) => p.toJson()).toList(),
  };

  factory LV2PluginInfo.fromJson(Map<String, dynamic> json) => LV2PluginInfo(
    uri: json['uri'],
    bundlePath: json['bundlePath'],
    label: json['label'],
    brand: json['brand'],
    thumbnailPath: json['thumbnailPath'],
    screenshotPath: json['screenshotPath'],
    controlPorts: (json['controlPorts'] as List?)
        ?.map((p) => ControlPort.fromJson(p))
        .toList(),
    fileParameters: (json['fileParameters'] as List?)
        ?.map((p) => FileParameter.fromJson(p))
        .toList(),
  );
}

/// Cache for LV2 plugin information
/// Uses on-demand loading with disk caching for fast startup
class LV2PluginCache {
  static LV2PluginCache? _instance;

  // URI -> bundle path index (built once on first use)
  final Map<String, String> _uriIndex = {};

  // Loaded plugin info cache
  final Map<String, LV2PluginInfo> _cache = {};

  bool _indexBuilt = false;
  String? _cacheFilePath;

  LV2PluginCache._();

  static LV2PluginCache get instance {
    _instance ??= LV2PluginCache._();
    return _instance!;
  }

  String get _defaultCachePath {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.cache/rustyfoot-hmi/lv2_cache.json';
  }

  /// Get plugin info by URI (loads on-demand)
  Future<LV2PluginInfo?> getPluginInfo(String uri) async {
    // Check memory cache first
    if (_cache.containsKey(uri)) {
      return _cache[uri];
    }

    // Build index if not done yet
    if (!_indexBuilt) {
      await _buildIndex();
    }

    // Check if we know where this plugin is
    final bundlePath = _uriIndex[uri];
    if (bundlePath == null) {
      _log.warning('Unknown plugin URI: $uri');
      return null;
    }

    // Load plugin info in isolate
    final info = await Isolate.run(() => _loadPluginSync(uri, bundlePath));
    if (info != null) {
      _cache[uri] = info;
      // Save to disk cache in background
      _saveCacheAsync();
    }

    return info;
  }

  /// Build URI -> bundle path index (fast, only reads manifest.ttl)
  Future<void> _buildIndex() async {
    if (_indexBuilt) return;

    // Try to load from disk cache first
    await _loadDiskCache();

    final lv2Paths = <String>[
      '/usr/lib/lv2',
      '/usr/local/lib/lv2',
      '${Platform.environment['HOME']}/.lv2',
    ];

    // Build index in isolate
    final index = await Isolate.run(() => _buildIndexInIsolate(lv2Paths));
    _uriIndex.addAll(index);

    _indexBuilt = true;
    _log.info('LV2 plugin index built with ${_uriIndex.length} plugins');
  }

  /// Load disk cache
  Future<void> _loadDiskCache() async {
    try {
      final cacheFile = File(_defaultCachePath);
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final plugins = json['plugins'] as Map<String, dynamic>?;
        if (plugins != null) {
          for (final entry in plugins.entries) {
            _cache[entry.key] = LV2PluginInfo.fromJson(entry.value);
            _uriIndex[entry.key] = _cache[entry.key]!.bundlePath;
          }
          _log.info('Loaded ${_cache.length} plugins from disk cache');
        }
      }
    } catch (e) {
      _log.warning('Failed to load disk cache: $e');
    }
  }

  /// Save cache to disk (async, non-blocking)
  void _saveCacheAsync() {
    Future(() async {
      try {
        final cacheFile = File(_defaultCachePath);
        await cacheFile.parent.create(recursive: true);

        final json = {
          'version': 1,
          'plugins': _cache.map((k, v) => MapEntry(k, v.toJson())),
        };

        await cacheFile.writeAsString(jsonEncode(json));
      } catch (e) {
        _log.warning('Failed to save disk cache: $e');
      }
    });
  }

  /// Clear the cache and rebuild
  Future<void> refresh() async {
    _cache.clear();
    _uriIndex.clear();
    _indexBuilt = false;

    // Delete disk cache
    try {
      final cacheFile = File(_defaultCachePath);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (e) {
      _log.warning('Failed to delete cache file: $e');
    }

    _log.info('LV2 plugin cache cleared');
  }

  /// Build URI index in isolate (only parses manifest.ttl for speed)
  static Map<String, String> _buildIndexInIsolate(List<String> lv2Paths) {
    final index = <String, String>{};

    for (final lv2Path in lv2Paths) {
      final dir = Directory(lv2Path);
      if (!dir.existsSync()) continue;

      for (final bundle in dir.listSync()) {
        if (bundle is Directory && bundle.path.endsWith('.lv2')) {
          final manifestFile = File('${bundle.path}/manifest.ttl');
          if (!manifestFile.existsSync()) continue;

          try {
            final g = Graph();
            g.parseTurtle(manifestFile.readAsStringSync());

            // Find all plugins in this bundle
            final pluginTriples = g.triples.where((t) =>
                t.pre.value == 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type' &&
                t.obj.value == 'http://lv2plug.in/ns/lv2core#Plugin');

            for (final triple in pluginTriples) {
              index[triple.sub.value] = bundle.path;
            }
          } catch (e) {
            // Skip problematic bundles
          }
        }
      }
    }

    return index;
  }

  /// Load a single plugin's full info (for use in isolate).
  /// Each file is parsed at most once for performance on ARM hardware.
  static LV2PluginInfo? _loadPluginSync(String uri, String bundlePath) {
    String? label;
    String? brand;
    String? thumbnailPath;
    String? screenshotPath;

    // Parse manifest.ttl once (reused for TTL file lookup, modgui, file params)
    Graph? manifestGraph;
    final manifestFile = File('$bundlePath/manifest.ttl');
    if (manifestFile.existsSync()) {
      try {
        manifestGraph = Graph();
        manifestGraph.parseTurtle(manifestFile.readAsStringSync());
      } catch (e) {
        manifestGraph = null;
      }
    }

    // Find plugin TTL files from manifest graph (without re-parsing manifest)
    final pluginTtlFiles = <File>[];
    if (manifestGraph != null) {
      final seeAlsoTriples = manifestGraph.triples.where((t) =>
          t.sub.value == uri &&
          t.pre.value == 'http://www.w3.org/2000/01/rdf-schema#seeAlso');
      for (final seeAlso in seeAlsoTriples) {
        final ref = seeAlso.obj;
        if (ref is URIRef && !ref.value.contains('modgui')) {
          pluginTtlFiles.add(File('$bundlePath/${ref.value}'));
        }
      }
    }

    // Parse plugin TTL files once into a single graph
    final pluginGraph = Graph();
    for (final ttlFile in pluginTtlFiles) {
      if (ttlFile.existsSync()) {
        try {
          pluginGraph.parseTurtle(ttlFile.readAsStringSync());
        } catch (e) {
          // Ignore parse errors
        }
      }
    }

    // Try modgui.ttl first
    final modguiFile = File('$bundlePath/modgui.ttl');
    if (modguiFile.existsSync()) {
      try {
        final g = Graph();
        g.parseTurtle(modguiFile.readAsStringSync());
        _extractModguiDataFromGraph(g, bundlePath, (l, b, t, s) {
          label = l;
          brand = b;
          thumbnailPath = t;
          screenshotPath = s;
        }, uri: uri);
      } catch (e) {
        // modgui.ttl parse failed
      }
    }

    // Check modguis.ttl (plural) for multi-plugin bundles like rkr.lv2
    if (label == null || thumbnailPath == null) {
      final modguisFile = File('$bundlePath/modguis.ttl');
      if (modguisFile.existsSync()) {
        try {
          final g = Graph();
          g.parseTurtle(modguisFile.readAsStringSync());
          _extractModguiDataFromGraph(g, bundlePath, (l, b, t, s) {
            label ??= l;
            brand ??= b;
            thumbnailPath ??= t;
            screenshotPath ??= s;
          }, uri: uri);
        } catch (e) {
          // modguis.ttl parse failed
        }
      }
    }

    // If missing data, check plugin TTL (already parsed into pluginGraph)
    if (label == null || thumbnailPath == null) {
      _extractModguiDataFromGraph(pluginGraph, bundlePath, (l, b, t, s) {
        label ??= l;
        brand ??= b;
        thumbnailPath ??= t;
        screenshotPath ??= s;
      }, uri: uri);
    }

    // Some bundles (e.g., midifilter.lv2) put modgui data in manifest.ttl
    if ((label == null || thumbnailPath == null) && manifestGraph != null) {
      _extractModguiDataFromGraph(manifestGraph, bundlePath, (l, b, t, s) {
        label ??= l;
        brand ??= b;
        thumbnailPath ??= t;
        screenshotPath ??= s;
      }, uri: uri);
    }

    // If no label from modgui, try doap:name from the plugin graph
    if (label == null) {
      final nameTriples = pluginGraph.triples.where((t) =>
          t.sub.value == uri &&
          t.pre.value == 'http://usefulinc.com/ns/doap#name');
      if (nameTriples.isNotEmpty) {
        final nameObj = nameTriples.first.obj;
        if (nameObj is Literal) {
          label = nameObj.value;
        }
      }
    }

    // Final fallback: extract from URI
    label ??= uri.split('/').last.split('#').last;

    // Extract control ports from pre-parsed plugin graph
    final controlPorts = _extractControlPorts(pluginGraph);

    // Extract file parameters from pre-parsed graphs
    final fileParameters = _extractFileParameters(pluginGraph, manifestGraph);

    return LV2PluginInfo(
      uri: uri,
      bundlePath: bundlePath,
      label: label,
      brand: brand,
      thumbnailPath: thumbnailPath,
      screenshotPath: screenshotPath,
      controlPorts: controlPorts,
      fileParameters: fileParameters,
    );
  }

  /// Extract modgui data (label, brand, thumbnail, screenshot) from a pre-parsed graph.
  /// If uri is provided, only extract data for that specific plugin URI.
  static void _extractModguiDataFromGraph(
    Graph g,
    String bundlePath,
    void Function(String? label, String? brand, String? thumbnailPath, String? screenshotPath) onData,
    {String? uri}
  ) {
    String? label;
    String? brand;
    String? thumbnailPath;
    String? screenshotPath;

    if (uri != null) {
      // Find the gui blank node for this specific plugin URI
      final guiTriples = g.triples.where((t) =>
          t.sub.value == uri &&
          t.pre.value == 'http://moddevices.com/ns/modgui#gui');

      if (guiTriples.isNotEmpty) {
        final guiNode = guiTriples.first.obj;

        final labelTriples = g.triples.where((t) =>
            t.sub == guiNode &&
            t.pre.value == 'http://moddevices.com/ns/modgui#label');
        if (labelTriples.isNotEmpty && labelTriples.first.obj is Literal) {
          label = (labelTriples.first.obj as Literal).value;
        }

        final brandTriples = g.triples.where((t) =>
            t.sub == guiNode &&
            t.pre.value == 'http://moddevices.com/ns/modgui#brand');
        if (brandTriples.isNotEmpty && brandTriples.first.obj is Literal) {
          brand = (brandTriples.first.obj as Literal).value;
        }

        final thumbTriples = g.triples.where((t) =>
            t.sub == guiNode &&
            t.pre.value == 'http://moddevices.com/ns/modgui#thumbnail');
        if (thumbTriples.isNotEmpty) {
          thumbnailPath = '$bundlePath/${thumbTriples.first.obj.value}';
        }

        final screenTriples = g.triples.where((t) =>
            t.sub == guiNode &&
            t.pre.value == 'http://moddevices.com/ns/modgui#screenshot');
        if (screenTriples.isNotEmpty) {
          screenshotPath = '$bundlePath/${screenTriples.first.obj.value}';
        }
      }
    } else {
      // No specific URI - extract from any modgui properties
      final labelTriples = g.triples.where((t) =>
          t.pre.value == 'http://moddevices.com/ns/modgui#label');
      if (labelTriples.isNotEmpty && labelTriples.first.obj is Literal) {
        label = (labelTriples.first.obj as Literal).value;
      }

      final brandTriples = g.triples.where((t) =>
          t.pre.value == 'http://moddevices.com/ns/modgui#brand');
      if (brandTriples.isNotEmpty && brandTriples.first.obj is Literal) {
        brand = (brandTriples.first.obj as Literal).value;
      }

      final thumbTriples = g.triples.where((t) =>
          t.pre.value == 'http://moddevices.com/ns/modgui#thumbnail');
      if (thumbTriples.isNotEmpty) {
        thumbnailPath = '$bundlePath/${thumbTriples.first.obj.value}';
      }

      final screenTriples = g.triples.where((t) =>
          t.pre.value == 'http://moddevices.com/ns/modgui#screenshot');
      if (screenTriples.isNotEmpty) {
        screenshotPath = '$bundlePath/${screenTriples.first.obj.value}';
      }
    }

    onData(label, brand, thumbnailPath, screenshotPath);
  }

  /// Extract control ports from a pre-parsed plugin graph
  static List<ControlPort> _extractControlPorts(Graph g) {
    final ports = <ControlPort>[];

    // Find all nodes with rdf:type lv2:ControlPort
    final controlPortNodes = g.triples.where((t) =>
        t.pre.value == 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type' &&
        t.obj.value == 'http://lv2plug.in/ns/lv2core#ControlPort'
    ).map((t) => t.sub).toList();

    for (final node in controlPortNodes) {
      // Extract symbol (required)
      final symbolTriples = g.triples.where((t) =>
          t.sub == node &&
          t.pre.value == 'http://lv2plug.in/ns/lv2core#symbol');
      if (symbolTriples.isEmpty) continue;
      final symbol = (symbolTriples.first.obj as Literal).value;

      // Extract name
      final nameTriples = g.triples.where((t) =>
          t.sub == node &&
          t.pre.value == 'http://lv2plug.in/ns/lv2core#name');
      final name = nameTriples.isNotEmpty
          ? (nameTriples.first.obj as Literal).value
          : symbol;

      // Check if it's an output port
      final isOutput = g.triples.any((t) =>
          t.sub == node &&
          t.pre.value == 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type' &&
          t.obj.value == 'http://lv2plug.in/ns/lv2core#OutputPort');

      // Extract min/max/default
      final minTriples = g.triples.where((t) =>
          t.sub == node &&
          t.pre.value == 'http://lv2plug.in/ns/lv2core#minimum');
      final maxTriples = g.triples.where((t) =>
          t.sub == node &&
          t.pre.value == 'http://lv2plug.in/ns/lv2core#maximum');
      final defTriples = g.triples.where((t) =>
          t.sub == node &&
          t.pre.value == 'http://lv2plug.in/ns/lv2core#default');

      final minimum = minTriples.isNotEmpty
          ? double.tryParse((minTriples.first.obj as Literal).value) ?? 0
          : 0.0;
      final maximum = maxTriples.isNotEmpty
          ? double.tryParse((maxTriples.first.obj as Literal).value) ?? 1
          : 1.0;
      final defaultValue = defTriples.isNotEmpty
          ? double.tryParse((defTriples.first.obj as Literal).value) ?? 0
          : 0.0;

      // Check port properties
      final portProperties = g.triples.where((t) =>
          t.sub == node &&
          t.pre.value == 'http://lv2plug.in/ns/lv2core#portProperty'
      ).map((t) => t.obj.value).toSet();

      final isToggled = portProperties.contains('http://lv2plug.in/ns/lv2core#toggled');
      final isInteger = portProperties.contains('http://lv2plug.in/ns/lv2core#integer');
      final isEnumeration = portProperties.contains('http://lv2plug.in/ns/lv2core#enumeration');
      final isTrigger = portProperties.contains('http://lv2plug.in/ns/ext/port-props#trigger');

      // Parse scale points for enumeration ports
      final scalePoints = <ScalePoint>[];
      if (isEnumeration) {
        final spTriples = g.triples.where((t) =>
            t.sub == node &&
            t.pre.value == 'http://lv2plug.in/ns/lv2core#scalePoint');

        for (final sp in spTriples) {
          final spNode = sp.obj;
          final spLabelTriples = g.triples.where((t) =>
              t.sub == spNode &&
              t.pre.value == 'http://www.w3.org/2000/01/rdf-schema#label');
          final spValueTriples = g.triples.where((t) =>
              t.sub == spNode &&
              t.pre.value == 'http://www.w3.org/1999/02/22-rdf-syntax-ns#value');

          if (spLabelTriples.isNotEmpty && spValueTriples.isNotEmpty) {
            scalePoints.add(ScalePoint(
              label: (spLabelTriples.first.obj as Literal).value,
              value: double.tryParse(
                  (spValueTriples.first.obj as Literal).value) ?? 0,
            ));
          }
        }
        scalePoints.sort((a, b) => a.value.compareTo(b.value));
      }

      ports.add(ControlPort(
        symbol: symbol,
        name: name,
        minimum: minimum,
        maximum: maximum,
        defaultValue: defaultValue,
        isToggled: isToggled,
        isInteger: isInteger,
        isTrigger: isTrigger,
        isOutput: isOutput,
        isEnumeration: isEnumeration,
        scalePoints: scalePoints,
      ));
    }

    return ports;
  }

  /// Extract file parameters (atom:Path) from pre-parsed graphs
  static List<FileParameter> _extractFileParameters(
    Graph pluginGraph,
    Graph? manifestGraph,
  ) {
    final params = <FileParameter>[];

    // Combine triples from both graphs for unified lookup
    final allTriples = pluginGraph.triples.toList();
    if (manifestGraph != null) {
      allTriples.addAll(manifestGraph.triples);
    }

    // Find all patch:writable triples
    final writableTriples = allTriples.where((t) =>
        t.pre.value == 'http://lv2plug.in/ns/ext/patch#writable');

    for (final wt in writableTriples) {
      final paramRef = wt.obj;

      // Check if this parameter has rdfs:range atom:Path
      final hasAtomPath = allTriples.any((t) =>
          t.sub.value == paramRef.value &&
          t.pre.value == 'http://www.w3.org/2000/01/rdf-schema#range' &&
          t.obj.value == 'http://lv2plug.in/ns/ext/atom#Path');

      if (!hasAtomPath) continue;

      final paramUri = paramRef.value;

      // Extract label
      final labelTriples = allTriples.where((t) =>
          t.sub.value == paramRef.value &&
          t.pre.value == 'http://www.w3.org/2000/01/rdf-schema#label');
      final label = labelTriples.isNotEmpty && labelTriples.first.obj is Literal
          ? (labelTriples.first.obj as Literal).value
          : paramUri.split('#').last.split('/').last;

      // Extract file types from mod:fileTypes
      final fileTypes = <String>[];
      final fileTypesTriples = allTriples.where((t) =>
          t.sub.value == paramRef.value &&
          t.pre.value == 'http://moddevices.com/ns/mod#fileTypes');

      for (final ft in fileTypesTriples) {
        final obj = ft.obj;
        if (obj is Literal) {
          // Comma-separated string (e.g., "nammodel,aidadspmodel,nam")
          for (final type in obj.value.split(',')) {
            final normalizedType = _normalizeFileType(type.trim());
            if (normalizedType != null && !fileTypes.contains(normalizedType)) {
              fileTypes.add(normalizedType);
            }
          }
        } else if (obj is URIRef) {
          // mod:TypeName format - extract local name
          final localName = obj.value.split('#').last.split('/').last;
          final fileType = _modTypeToFileType(localName);
          if (fileType != null && !fileTypes.contains(fileType)) {
            fileTypes.add(fileType);
          }
        }
      }

      if (fileTypes.isEmpty) {
        fileTypes.add('file');
      }

      params.add(FileParameter(
        uri: paramUri,
        label: label,
        fileTypes: fileTypes,
      ));
    }

    return params;
  }

  /// Normalize a file type string to our standard identifiers
  static String? _normalizeFileType(String type) {
    final lower = type.toLowerCase();
    switch (lower) {
      case 'nammodel':
      case 'nam':
        return 'nammodel';
      case 'aidadspmodel':
      case 'aidax':
      case 'aidiax':
        return 'aidadspmodel';
      case 'cabsim':
      case 'cab':
        return 'cabsim';
      case 'ir':
        return 'ir';
      case 'wav':
      case 'audio':
      case 'audiosample':
      case 'flac':
      case 'ogg':
        return 'audiosample';
      case 'sf2':
        return 'sf2';
      case 'sfz':
        return 'sfz';
      case 'json':
        // JSON can be AIDA-X model
        return 'aidadspmodel';
      case 'midi':
      case 'mid':
        return 'midifile';
      default:
        return lower;
    }
  }

  /// Convert MOD file type identifier to standard fileType
  static String? _modTypeToFileType(String modType) {
    // Map MOD type identifiers to file type strings used in file_types.dart
    switch (modType.toLowerCase()) {
      case 'sfzfile':
        return 'sfz';
      case 'sf2file':
        return 'sf2';
      case 'audiofile':
      case 'audiosample':
        return 'audiosample';
      case 'cabsimfile':
      case 'cabsimulatorfile':
        return 'cabsim';
      case 'irfile':
      case 'impulseresponsefile':
        return 'ir';
      case 'aidadspmodelfile':
        return 'aidadspmodel';
      case 'nammodelfile':
        return 'nammodel';
      case 'midifile':
        return 'midifile';
      default:
        // Try to match common patterns
        if (modType.toLowerCase().contains('audio')) return 'audiosample';
        if (modType.toLowerCase().contains('sfz')) return 'sfz';
        if (modType.toLowerCase().contains('sf2')) return 'sf2';
        if (modType.toLowerCase().contains('cab')) return 'cabsim';
        if (modType.toLowerCase().contains('ir')) return 'ir';
        if (modType.toLowerCase().contains('aida')) return 'aidadspmodel';
        if (modType.toLowerCase().contains('nam')) return 'nammodel';
        return modType.toLowerCase();
    }
  }
}
