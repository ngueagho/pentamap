import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../app/app_theme.dart';
import '../../core/models/building.dart';
import '../../core/models/custom_poi.dart';
import '../../core/models/map_graph.dart';
import '../../core/models/map_node.dart';
import '../../core/services/custom_poi_store.dart';
import '../../core/services/location_service.dart';
import '../../core/services/map_graph_api_client.dart';
import '../../core/services/map_graph_store.dart';
import '../camera_ar/ar_navigation_screen.dart';
import 'qr_scan_screen.dart';

/// Écran unique de navigation — extérieur ET intérieur, sans bouton de
/// "mode" à choisir. Rendu **vectoriel** (MapLibre + tuiles OpenFreeMap,
/// gratuites, sans compte/clé) aux couleurs de la marque
/// (`assets/map_style.json`).
///
/// - Une épingle **bleue** par point extérieur (chemin, repère) : tap →
///   "Naviguer jusqu'ici".
/// - Une épingle **orange**, plus grande, par bâtiment : tap → liste ses
///   pièces par étage, choisir en lance directement la navigation — le
///   trajet complet (position actuelle → sortie éventuelle → extérieur →
///   entrée du bâtiment → pièce) est calculé en une seule fois par
///   [MapGraph.shortestPath], qui ne fait aucune distinction entre
///   "dedans"/"dehors" : c'est le même graphe.
/// - Recherche (icône loupe) : toutes les destinations, pièces incluses,
///   filtrables par nom — pour taper directement "salle 101" sans chercher
///   le bâtiment sur la carte.
/// - Scanner un QR (icône dédiée) : pour repartir d'un point précis déjà
///   connu (plus rapide/précis que le GPS en intérieur) plutôt que de la
///   position GPS actuelle.
///
/// Affiche aussi les points importés (voir `custom_poi_store.dart`).
///
/// Le site actif (le plus récemment modifié côté serveur, créé
/// automatiquement s'il n'en existe encore aucun) est chargé automatiquement
/// à l'ouverture — pas de sélection manuelle nécessaire.
class DestinationPickerScreen extends ConsumerStatefulWidget {
  const DestinationPickerScreen({super.key});

  @override
  ConsumerState<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState extends ConsumerState<DestinationPickerScreen> {
  final _locationService = LocationService();
  final _apiClient = MapGraphApiClient();

  MapLibreMapController? _mapController;
  String? _styleJson;
  LatLng? _initialCenter;
  bool _hasLocationPermission = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _loadStyle();
    _prepareLocation();
    _syncFromServer();

    // Recompose les épingles dès que le graphe ou les POI importés changent
    // (ex: la synchronisation serveur se termine après le chargement du
    // style, ou l'utilisateur revient d'un écran d'administration).
    ref.listenManual(mapGraphProvider, (_, _) => _refreshMarkers());
    ref.listenManual(customPoiProvider, (_, _) => _refreshMarkers());
  }

  @override
  void dispose() {
    _apiClient.dispose();
    super.dispose();
  }

  Future<void> _loadStyle() async {
    final json = await rootBundle.loadString('assets/map_style.json');
    if (mounted) setState(() => _styleJson = json);
  }

  Future<void> _prepareLocation() async {
    final hasPermission = await _locationService.ensurePermission();
    if (!mounted) return;
    setState(() => _hasLocationPermission = hasPermission);
    if (!hasPermission) return;
    try {
      final position = await _locationService.getCurrentPosition();
      if (mounted) {
        setState(() => _initialCenter = LatLng(position.latitude, position.longitude));
      }
    } catch (_) {
      // Pas de position initiale : la carte se centrera sur le premier
      // repère disponible à la place (voir _defaultCenter).
    }
  }

  /// Charge directement depuis le serveur, sans sélection manuelle — voir
  /// [MapGraphNotifier.refreshFromServer]. Échoue silencieusement (garde ce
  /// qui est déjà en mémoire/en cache) si le serveur est injoignable.
  Future<void> _syncFromServer() async {
    setState(() => _isSyncing = true);
    try {
      await ref.read(mapGraphProvider.notifier).refreshFromServer(_apiClient);
    } catch (_) {
      // Garde le graphe déjà chargé (persisté localement au démarrage).
    }
    try {
      await ref.read(customPoiProvider.notifier).refreshFromServer();
    } catch (_) {
      // Garde le cache local des points importés déjà chargé.
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  MapGraph? get _graph => ref.read(mapGraphProvider);

  List<MapNode> get _outdoorNodes =>
      _graph?.nodes.values.where((node) => node.kind == NodeKind.outdoorGps).toList() ??
      const [];

  List<Building> get _buildings => _graph?.buildings ?? const [];

  LatLng? get _defaultCenter {
    final outdoorNodes = _outdoorNodes;
    if (outdoorNodes.isNotEmpty) {
      return LatLng(outdoorNodes.first.latitude!, outdoorNodes.first.longitude!);
    }
    final buildings = _buildings;
    if (buildings.isNotEmpty) {
      return LatLng(buildings.first.latitude, buildings.first.longitude);
    }
    final customPois = ref.read(customPoiProvider);
    if (customPois.isNotEmpty) {
      return LatLng(customPois.first.latitude, customPois.first.longitude);
    }
    return null;
  }

  Future<void> _onStyleLoaded() => _refreshMarkers();

  /// Retire toutes les épingles et les recrée à partir de l'état courant du
  /// graphe et des points importés — appelé à chaque changement de données
  /// plutôt que de suivre les diffs, plus simple et largement assez rapide
  /// pour le nombre de points en jeu ici.
  Future<void> _refreshMarkers() async {
    final controller = _mapController;
    if (controller == null) return;

    await controller.clearCircles();
    controller.onCircleTapped.clear();
    controller.onCircleTapped.add(_onCircleTapped);

    for (final node in _outdoorNodes) {
      await controller.addCircle(
        CircleOptions(
          geometry: LatLng(node.latitude!, node.longitude!),
          circleRadius: 9,
          circleColor: _toHex(PentamapColors.blue),
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
        ),
        {'type': 'node', 'id': node.id},
      );
    }
    for (final building in _buildings) {
      await controller.addCircle(
        CircleOptions(
          geometry: LatLng(building.latitude, building.longitude),
          circleRadius: 14,
          circleColor: _toHex(PentamapColors.orange),
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
        {'type': 'building', 'id': building.id},
      );
    }
    for (final poi in ref.read(customPoiProvider)) {
      await controller.addCircle(
        CircleOptions(
          geometry: LatLng(poi.latitude, poi.longitude),
          circleRadius: 8,
          circleColor: _toHex(poi.color),
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
        ),
        {'type': 'poi', 'id': poi.id},
      );
    }
  }

  void _onCircleTapped(Circle circle) {
    final data = circle.data;
    if (data == null) return;
    switch (data['type']) {
      case 'node':
        for (final node in _outdoorNodes) {
          if (node.id == data['id']) {
            _onNodeTapped(node);
            return;
          }
        }
      case 'building':
        for (final building in _buildings) {
          if (building.id == data['id']) {
            _onBuildingTapped(building);
            return;
          }
        }
      case 'poi':
        for (final poi in ref.read(customPoiProvider)) {
          if (poi.id == data['id']) {
            _onCustomPoiTapped(poi);
            return;
          }
        }
    }
  }

  String _toHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  @override
  Widget build(BuildContext context) {
    // Se reconstruit quand le graphe ou les points importés changent — les
    // épingles elles-mêmes sont recomposées via [_refreshMarkers] (déclenché
    // par les `ref.listenManual` posés dans `initState`).
    ref.watch(mapGraphProvider);
    ref.watch(customPoiProvider);

    final hasAnyData =
        _outdoorNodes.isNotEmpty || _buildings.isNotEmpty || ref.watch(customPoiProvider).isNotEmpty;
    final center = _initialCenter ?? _defaultCenter;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pentamap'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Rechercher une destination',
            onPressed: hasAnyData ? () => _openSearch(startNodeId: null) : null,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scanner un QR pour repartir d\'un point précis',
            onPressed: _scanThenSearch,
          ),
          IconButton(
            icon: _isSyncing
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Actualiser depuis le serveur',
            onPressed: _isSyncing ? null : _syncFromServer,
          ),
        ],
      ),
      body: (_styleJson == null || (!hasAnyData && center == null))
          ? _buildEmptyState(context, loadingStyle: _styleJson == null)
          : MapLibreMap(
              styleString: _styleJson!,
              initialCameraPosition: CameraPosition(target: center!, zoom: 17),
              myLocationEnabled: _hasLocationPermission,
              myLocationRenderMode: MyLocationRenderMode.normal,
              onMapCreated: (controller) => _mapController = controller,
              onStyleLoadedCallback: _onStyleLoaded,
            ),
    );
  }

  Future<void> _scanThenSearch() async {
    final result = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;
    final (_, nodeId) = result;
    _openSearch(startNodeId: nodeId);
  }

  void _navigateTo(String destinationNodeId, {String? startNodeId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArNavigationScreen(
          destinationNodeId: destinationNodeId,
          startNodeId: startNodeId,
        ),
      ),
    );
  }

  void _onNodeTapped(MapNode node) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(node.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${node.latitude?.toStringAsFixed(6)}, ${node.longitude?.toStringAsFixed(6)}',
              style: PentamapTheme.readout(context),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.directions),
              label: const Text('Naviguer jusqu\'ici'),
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _navigateTo(node.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _onBuildingTapped(Building building) {
    final roomsByFloor = _graph?.roomsByFloor(building.id) ?? const {};
    final floors = roomsByFloor.keys.toList()..sort();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.apartment, color: PentamapColors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(building.name, style: Theme.of(context).textTheme.titleLarge),
                  ),
                ],
              ),
              if (building.description != null) ...[
                const SizedBox(height: 4),
                Text(building.description!),
              ],
              const SizedBox(height: 12),
              if (floors.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Aucune pièce cartographiée pour ce bâtiment pour le moment.'),
                )
              else
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    children: [
                      for (final floor in floors) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text('Étage $floor',
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                        for (final room in roomsByFloor[floor]!)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.meeting_room_outlined,
                                color: PentamapColors.orange),
                            title: Text(room.label),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _navigateTo(room.id);
                            },
                          ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Recherche parmi toutes les destinations connues (points extérieurs et
  /// pièces de tous les bâtiments) — pour taper directement un nom plutôt
  /// que de chercher sur la carte. [startNodeId] : si fourni (après un scan
  /// QR), le trajet partira de ce nœud plutôt que du GPS actuel.
  void _openSearch({required String? startNodeId}) {
    final graph = _graph;
    if (graph == null) return;
    final buildingNameById = {for (final b in _buildings) b.id: b.name};
    final entries = <(String label, String subtitle, String nodeId)>[
      for (final n in _outdoorNodes) (n.label, 'Extérieur', n.id),
      for (final n in graph.nodes.values.where((n) => n.kind == NodeKind.indoorAnchor))
        (
          n.label,
          n.buildingId != null
              ? (buildingNameById[n.buildingId] ?? 'Bâtiment')
              : 'Intérieur',
          n.id,
        ),
    ];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _SearchSheet(
        entries: entries,
        onSelected: (nodeId) {
          Navigator.of(sheetContext).pop();
          _navigateTo(nodeId, startNodeId: startNodeId);
        },
      ),
    );
  }

  void _onCustomPoiTapped(CustomPoi poi) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.place, color: poi.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(poi.label, style: Theme.of(context).textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${poi.latitude.toStringAsFixed(6)}, ${poi.longitude.toStringAsFixed(6)}',
              style: PentamapTheme.readout(context),
            ),
            const SizedBox(height: 8),
            Text(
              'Point importé — pas encore cartographié pour la navigation.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: PentamapColors.ink.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, {required bool loadingStyle}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loadingStyle || _isSyncing) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(loadingStyle ? 'Chargement de la carte...' : 'Recherche d\'une carte sur le serveur...'),
            ] else ...[
              const Icon(Icons.map_outlined, size: 48),
              const SizedBox(height: 16),
              const Text(
                "Aucune destination disponible.\n\n"
                "Ajoutez des bâtiments et des points depuis l'administration "
                "(web ou dans l'app) — la carte se mettra à jour automatiquement.",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
                onPressed: _syncFromServer,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchSheet extends StatefulWidget {
  final List<(String label, String subtitle, String nodeId)> entries;
  final void Function(String nodeId) onSelected;

  const _SearchSheet({required this.entries, required this.onSelected});

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.entries
        .where((e) => e.$1.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Où voulez-vous aller ?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Nom d\'un point ou d\'une salle...',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final entry = filtered[index];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(entry.$1),
                    subtitle: Text(entry.$2),
                    onTap: () => widget.onSelected(entry.$3),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
