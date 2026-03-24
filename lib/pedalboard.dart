import 'dart:io';

import 'package:logging/logging.dart';
import 'package:rdflib/rdflib.dart';
import 'package:rustyfoot_hmi/pedal.dart';

final _log = Logger('Pedalboard');

class Pedalboard {
  final String name;
  final String path;
  final String _ttlFileName;
  final double bpm;
  final int bpb;
  List<Pedal>? _pedals;

  Pedalboard(this.name, this.path, this._ttlFileName, {this.bpm = 120.0, this.bpb = 4});

  static Pedalboard? load(FileSystemEntity f) {
    try {
      Graph g = Graph();
      g.parseTurtle(File("${f.path}/manifest.ttl").readAsStringSync());
      var triples = g.matchTriples("http://www.w3.org/2000/01/rdf-schema#seeAlso");
      if (triples.isEmpty) {
        _log.warning('No seeAlso triple in ${f.path}/manifest.ttl');
        return null;
      }
      var uri = triples.first.obj as URIRef;
      g = Graph();
      g.parseTurtle(File("${f.path}/${uri.value}").readAsStringSync());
      triples = g.matchTriples("http://usefulinc.com/ns/doap#name");
      if (triples.isEmpty) {
        _log.warning('No doap:name triple in ${f.path}/${uri.value}');
        return null;
      }
      var name = triples.first.obj as Literal;

      // Parse transport values (bpm, bpb) from the pedalboard TTL
      double bpm = 120.0;
      int bpb = 4;
      try {
        final pbGraph = Graph();
        pbGraph.parseTurtle(File("${f.path}/${uri.value}").readAsStringSync());
        final ingenValue = 'http://drobilla.net/ns/ingen#value';
        for (final t in pbGraph.triples) {
          if (t.pre.value == ingenValue && t.obj is Literal) {
            final val = (t.obj as Literal).value;
            if (t.sub.value.endsWith(':bpm') || t.sub.value.endsWith('/bpm')) {
              bpm = double.tryParse(val) ?? bpm;
            } else if (t.sub.value.endsWith(':bpb') || t.sub.value.endsWith('/bpb')) {
              bpb = (double.tryParse(val) ?? bpb.toDouble()).toInt();
            }
          }
        }
      } catch (e) {
        _log.fine('Could not parse transport from ${f.path}/${uri.value}: $e');
      }

      return Pedalboard(name.value, f.path, uri.value, bpm: bpm, bpb: bpb);
    } catch (e) {
      _log.warning('Failed to load pedalboard from ${f.path}: $e');
      return null;
    }
  }

  /// Load and return the list of pedals in this pedalboard
  Future<List<Pedal>> getPedals() async {
    if (_pedals != null) return _pedals!;

    _pedals = [];
    try {
      final g = Graph();
      g.parseTurtle(File("$path/$_ttlFileName").readAsStringSync());

      // Find all ingen:Block instances (plugins)
      final blockTriples = g.triples.where((t) =>
          t.pre.value == 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type' &&
          t.obj.value == 'http://drobilla.net/ns/ingen#Block');

      for (final blockTriple in blockTriples) {
        final instanceName = blockTriple.sub.value;

        // Find the prototype URI for this block
        final protoTriples = g.triples.where((t) =>
            t.sub.value == instanceName &&
            t.pre.value == 'http://lv2plug.in/ns/lv2core#prototype');

        if (protoTriples.isEmpty) continue;

        final pluginUri = protoTriples.first.obj.value;

        // Find instance number
        final instanceNumTriples = g.triples.where((t) =>
            t.sub.value == instanceName &&
            t.pre.value == 'http://moddevices.com/ns/modpedal#instanceNumber');

        int instanceNumber = 0;
        if (instanceNumTriples.isNotEmpty) {
          final numLiteral = instanceNumTriples.first.obj as Literal;
          instanceNumber = int.tryParse(numLiteral.value) ?? 0;
        }

        // Find enabled state
        final enabledTriples = g.triples.where((t) =>
            t.sub.value == instanceName &&
            t.pre.value == 'http://drobilla.net/ns/ingen#enabled');

        bool enabled = true;
        if (enabledTriples.isNotEmpty) {
          final enabledVal = enabledTriples.first.obj;
          if (enabledVal is Literal) {
            enabled = enabledVal.value == 'true';
          }
        }

        // Find port values for this instance
        // Ports are named like <instanceName/portSymbol> with ingen:value
        final portValues = <String, double>{};
        final portPrefix = '$instanceName/';

        for (final triple in g.triples) {
          if (triple.sub.value.startsWith(portPrefix) &&
              triple.pre.value == 'http://drobilla.net/ns/ingen#value') {
            final portSymbol = triple.sub.value.substring(portPrefix.length);
            final valueObj = triple.obj;
            if (valueObj is Literal) {
              final value = double.tryParse(valueObj.value);
              if (value != null) {
                portValues[portSymbol] = value;
              }
            }
          }
        }

        // Extract file parameter values from LV2 state
        final fileValues = _readFileParamState(instanceNumber);

        _pedals!.add(Pedal(
          instanceName: instanceName,
          pluginUri: pluginUri,
          instanceNumber: instanceNumber,
          enabled: enabled,
          portValues: portValues,
          fileValues: fileValues,
        ));
      }

      // Sort by instance number
      _pedals!.sort((a, b) => a.instanceNumber.compareTo(b.instanceNumber));

      // Load metadata for all pedals
      final cache = LV2PluginCache.instance;
      for (final pedal in _pedals!) {
        await pedal.loadMetadata(cache);
      }

      _log.info('Loaded ${_pedals!.length} pedals from $name');
    } catch (e) {
      _log.warning('Failed to load pedals from $path: $e');
    }

    return _pedals!;
  }

  /// Read file parameter values from the LV2 state directory for a plugin instance.
  /// State files are stored in effect-{instanceNumber}/effect.ttl within the
  /// pedalboard bundle. The state format uses angle brackets for both param URI
  /// and file value: `<param_uri> <url_encoded_filename>`
  /// The file value is relative to the effect directory and URL-encoded.
  Map<String, String> _readFileParamState(int instanceNumber) {
    final fileValues = <String, String>{};
    final effectDir = '$path/effect-$instanceNumber';
    final effectTtl = File('$effectDir/effect.ttl');
    if (!effectTtl.existsSync()) return fileValues;

    try {
      final content = effectTtl.readAsStringSync();
      // Match state entries: <param_uri> <filename> or <param_uri> "path"
      // Inside state:state [...] block, params look like:
      //   <http://...#model> <URL%20encoded%20name.nam>
      // or sometimes:
      //   <http://...#model> "/absolute/path"
      final anglePattern = RegExp(r'<(https?://[^>]+)>\s+<([^>]+)>');
      for (final match in anglePattern.allMatches(content)) {
        final paramUri = match.group(1)!;
        final rawValue = match.group(2)!;
        // Skip URIs that look like full http URLs (not file references)
        if (rawValue.startsWith('http://') || rawValue.startsWith('https://')) continue;
        final decoded = Uri.decodeComponent(rawValue);
        fileValues[paramUri] = decoded;
      }
      // Also match quoted string values: <param_uri> "path"
      final quotedPattern = RegExp(r'<(https?://[^>]+)>\s+"([^"]*)"');
      for (final match in quotedPattern.allMatches(content)) {
        final paramUri = match.group(1)!;
        final value = match.group(2)!;
        if (value.isNotEmpty && value != 'None') {
          fileValues[paramUri] = value;
        }
      }
    } catch (e) {
      _log.fine('Could not read state for effect-$instanceNumber: $e');
    }

    return fileValues;
  }
}