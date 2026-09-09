import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:ar_flutter_plugin_plus/ar_flutter_plugin_plus.dart';
import 'package:ar_flutter_plugin_plus/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_plus/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_plus/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_plus/models/ar_hittest_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/models/map_edge.dart';
import '../../core/models/map_graph.dart';
import '../../core/models/map_node.dart';
import '../../core/services/barometer_service.dart';
import '../../core/services/geo_utils.dart';
import '../../core/services/location_service.dart';
import '../../core/services/map_graph_api_client.dart';
import '../../core/services/map_graph_store.dart';
import 'qr_codes_screen.dart';

/// Écran « opérateur » : sert à parcourir l'établissement une fois pour
/// enregistrer le graphe de carte (phase 1 de cartographie).
///
/// - En extérieur : chaque appui sur "Ajouter un point ici (GPS)" capture la
///   position GPS courante.
/// - En intérieur : un appui sur une surface détectée par la caméra AR place
///   une ancre visuelle persistante (via `ARAnchorManager`).
///
/// Les nœuds sont enregistrés dans l'ordre du parcours, donc reliés
/// automatiquement entre eux (chaque nouveau point est connecté au
/// précédent) — c'est la trace du chemin suivi par l'opérateur.
///
/// ⚠️ Les ancres créées ici sont des `ARPlaneAnchor` locales à la session en
/// cours : pour qu'un autre utilisateur puisse s'y relocaliser plus tard, il
/// faut les rendre persistantes via les Google Cloud Anchors, que
/// `ar_flutter_plugin_plus` expose déjà (`ARAnchorManager.
/// initGoogleCloudAnchorMode()`, `.uploadAnchor()`, `.downloadAnchor()`) —
/// il ne reste qu'à brancher un backend de stockage (Firebase Firestore
/// dans l'exemple officiel du plugin, ou un backend maison). Voir le README.
///
/// Le graphe en cours de construction est poussé en direct dans
/// [mapGraphProvider] (voir `map_graph_store.dart`) à chaque point ajouté —
/// il est donc immédiatement utilisable par l'écran de navigation, sans
/// passer par l'export/import presse-papiers (utile pour tester tout de
/// suite ; l'export reste disponible pour sauvegarder/partager la carte).
class MappingRecorderScreen extends ConsumerStatefulWidget {
  const MappingRecorderScreen({super.key});

  @override
  ConsumerState<MappingRecorderScreen> createState() =>
      _MappingRecorderScreenState();
}

class _MappingRecorderScreenState
    extends ConsumerState<MappingRecorderScreen> {
  final _locationService = LocationService();
  final _nodes = <MapNode>[];
  final _edges = <MapEdge>[];

  ARSessionManager? _arSessionManager;
  ARAnchorManager? _arAnchorManager;

  final _apiClient = MapGraphApiClient();
  final _barometerService = BarometerService();

  bool _outdoorMode = true;
  int _nodeCounter = 0;
  bool _isUploading = false;
  int _currentFloor = 0;

  StreamSubscription<double>? _barometerSubscription;
  double? _floorReferenceHpa;

  @override
  void initState() {
    super.initState();
    // Reprend une carte déjà chargée (persistée ou importée) plutôt que de
    // repartir de zéro et l'écraser silencieusement au premier point ajouté.
    final existingGraph = ref.read(mapGraphProvider);
    if (existingGraph != null) {
      _nodes.addAll(existingGraph.nodes.values);
      _edges.addAll(existingGraph.edges);
      // Repart après le plus grand suffixe "node_N" déjà utilisé, pour ne
      // jamais régénérer un id déjà pris (les ids importés ne suivent pas
      // forcément ce format, d'où le `whereType`/parsing défensif).
      final usedIndexes = _nodes
          .map((n) => int.tryParse(n.id.replaceFirst('node_', '')))
          .whereType<int>();
      _nodeCounter = usedIndexes.isEmpty ? 0 : usedIndexes.reduce(max) + 1;
    }
  }

  @override
  void dispose() {
    _arSessionManager?.dispose();
    _apiClient.dispose();
    _barometerSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cartographie'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Exporter le graphe (JSON, presse-papiers)',
            onPressed: _nodes.isEmpty ? null : _exportGraph,
          ),
          IconButton(
            icon: _isUploading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            tooltip: 'Envoyer vers le serveur',
            onPressed: (_nodes.isEmpty || _isUploading) ? null : _uploadToServer,
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Mode extérieur (GPS)'),
            subtitle: Text(_outdoorMode
                ? 'Les points seront capturés via le GPS'
                : "Touchez une surface dans l'image pour poser une ancre"),
            value: _outdoorMode,
            onChanged: _onModeChanged,
          ),
          if (!_outdoorMode) _buildFloorSelector(),
          Expanded(
            child: _outdoorMode ? _buildOutdoorPanel() : _buildIndoorArView(),
          ),
          _buildNodeList(),
        ],
      ),
    );
  }

  void _onModeChanged(bool outdoor) {
    setState(() => _outdoorMode = outdoor);
    if (outdoor) {
      _barometerSubscription?.cancel();
      _barometerSubscription = null;
      _floorReferenceHpa = null;
      return;
    }
    // Bascule en mode intérieur : on retient la pression courante comme
    // référence pour l'étage actuel, et on surveille les écarts pour
    // suggérer une mise à jour si l'opérateur change d'étage sans y penser.
    _barometerSubscription = _barometerService.pressureStream().listen((hpa) {
      _floorReferenceHpa ??= hpa;
      final delta = _barometerService.estimateFloorDelta(_floorReferenceHpa!, hpa);
      if (delta != 0) {
        _showMessage(
          delta > 0
              ? 'Changement de pression détecté : avez-vous monté $delta étage(s) ?'
              : 'Changement de pression détecté : avez-vous descendu ${-delta} étage(s) ?',
        );
        _floorReferenceHpa = hpa; // évite de re-suggérer en boucle
      }
    });
  }

  Widget _buildFloorSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Text('Étage actuel : '),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => setState(() => _currentFloor--),
          ),
          Text('$_currentFloor', style: Theme.of(context).textTheme.titleMedium),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => setState(() => _currentFloor++),
          ),
          const Spacer(),
          const Text('Saisi manuellement — voir README', style: TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildOutdoorPanel() {
    return Center(
      child: FilledButton.icon(
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Ajouter un point ici (GPS)'),
        onPressed: _addOutdoorNode,
      ),
    );
  }

  Widget _buildIndoorArView() {
    return ARView(
      key: const ValueKey('mapping_ar_view'),
      onARViewCreated: _onARViewCreated,
      planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
    );
  }

  Widget _buildNodeList() {
    if (_nodes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Aucun point enregistré pour le moment.'),
      );
    }
    return SizedBox(
      height: 160,
      child: ListView.builder(
        itemCount: _nodes.length,
        itemBuilder: (context, index) {
          final node = _nodes[index];
          return ListTile(
            dense: true,
            leading: Icon(
              node.kind == NodeKind.outdoorGps
                  ? Icons.satellite_alt
                  : Icons.anchor,
            ),
            title: Text(node.label),
            subtitle: Text(
              node.kind == NodeKind.outdoorGps
                  ? '${node.latitude?.toStringAsFixed(6)}, '
                      '${node.longitude?.toStringAsFixed(6)}'
                  : 'ancre ${node.anchorId}',
            ),
          );
        },
      ),
    );
  }

  Future<void> _addOutdoorNode() async {
    final hasPermission = await _locationService.ensurePermission();
    if (!mounted) return;
    if (!hasPermission) {
      _showMessage('Permission de localisation refusée.');
      return;
    }
    final Position position;
    try {
      position = await _locationService.getCurrentPosition();
    } catch (_) {
      _showMessage('Impossible de récupérer la position GPS. Activez le GPS et réessayez.');
      return;
    }
    if (!mounted) return;
    _appendNode(
      MapNode(
        id: _nextNodeId(),
        label: 'Point ${_nodes.length + 1}',
        kind: NodeKind.outdoorGps,
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: position.altitude,
      ),
    );
  }

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _arSessionManager = sessionManager;
    _arAnchorManager = anchorManager;

    _arSessionManager!.onInitialize(
      showFeaturePoints: true,
      showPlanes: true,
      showWorldOrigin: false,
      handleTaps: false,
    );
    objectManager.onInitialize();

    _arSessionManager!.onPlaneOrPointTap = _onIndoorTap;
  }

  Future<void> _onIndoorTap(List<ARHitTestResult> hitResults) async {
    final planeHit = hitResults
        .where((r) => r.type == ARHitTestResultType.plane)
        .toList();
    if (planeHit.isEmpty) {
      _showMessage('Aucune surface détectée à cet endroit, réessayez.');
      return;
    }

    final anchor = ARPlaneAnchor(transformation: planeHit.first.worldTransform);
    final added = await _arAnchorManager?.addAnchor(anchor);
    if (!mounted) return;
    if (added != true) {
      _showMessage("Échec de la création de l'ancre.");
      return;
    }

    final translation = anchor.transformation.getTranslation();
    _appendNode(
      MapNode(
        id: _nextNodeId(),
        label: 'Ancre ${_nodes.length + 1}',
        kind: NodeKind.indoorAnchor,
        anchorId: anchor.name,
        localX: translation.x,
        localY: translation.y,
        localZ: translation.z,
        floor: _currentFloor,
      ),
    );
  }

  void _appendNode(MapNode node) {
    setState(() {
      if (_nodes.isNotEmpty) {
        final previous = _nodes.last;
        _edges.add(
          MapEdge(
            fromNodeId: previous.id,
            toNodeId: node.id,
            distanceMeters: _distanceBetween(previous, node),
          ),
        );
      }
      _nodes.add(node);
    });
    ref.read(mapGraphProvider.notifier).setGraph(
          MapGraph(nodes: {for (final n in _nodes) n.id: n}, edges: _edges),
        );
  }

  double _distanceBetween(MapNode a, MapNode b) {
    if (a.latitude != null && b.latitude != null) {
      return GeoUtils.haversineMeters(
        a.latitude!,
        a.longitude!,
        b.latitude!,
        b.longitude!,
      );
    }
    if (a.localX != null && b.localX != null) {
      final dx = (b.localX! - a.localX!);
      final dy = (b.localY ?? 0) - (a.localY ?? 0);
      final dz = (b.localZ! - a.localZ!);
      return sqrt(dx * dx + dy * dy + dz * dz);
    }
    return 0;
  }

  String _nextNodeId() => 'node_${_nodeCounter++}';

  void _exportGraph() {
    final graph = MapGraph(
      nodes: {for (final n in _nodes) n.id: n},
      edges: _edges,
    );
    final jsonString = const JsonEncoder.withIndent('  ').convert(graph.toJson());
    Clipboard.setData(ClipboardData(text: jsonString));
    _showMessage('Graphe copié dans le presse-papiers (${_nodes.length} points).');
  }

  Future<void> _uploadToServer() async {
    final name = await _promptForGraphName();
    if (name == null || name.trim().isEmpty) return;

    setState(() => _isUploading = true);
    final graph = MapGraph(
      nodes: {for (final n in _nodes) n.id: n},
      edges: _edges,
    );
    try {
      final summary = await _apiClient.uploadGraph(name.trim(), graph);
      if (!mounted) return;
      final indoorNodes =
          _nodes.where((n) => n.kind == NodeKind.indoorAnchor).toList();
      if (indoorNodes.isEmpty) {
        _showMessage('Carte "${summary.name}" envoyée au serveur (${summary.nodeCount} points).');
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => QrCodesScreen(
              graphId: summary.id,
              indoorNodes: indoorNodes,
            ),
          ),
        );
      }
    } on MapGraphApiException catch (e) {
      _showMessage('Échec de l\'envoi : $e');
    } catch (_) {
      _showMessage(
        "Impossible de joindre le serveur. Vérifiez qu'il tourne et que "
        "'adb reverse tcp:8420 tcp:8420' a bien été fait (voir README serveur).",
      );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<String?> _promptForGraphName() {
    final controller = TextEditingController(
      text: 'Carte ${DateTime.now().toIso8601String().substring(0, 16)}',
    );
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nom de la carte'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
