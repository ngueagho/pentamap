import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../app/app_theme.dart';
import '../../core/models/custom_poi.dart';
import '../../core/models/map_node.dart';
import '../../core/services/custom_poi_store.dart';
import '../../core/services/location_service.dart';
import '../../core/services/map_graph_api_client.dart';
import '../../core/services/map_graph_store.dart';
import '../camera_ar/ar_navigation_screen.dart';
import 'indoor_destination_picker_screen.dart';

/// Carte extérieure — rendu **vectoriel** (MapLibre + tuiles OpenFreeMap,
/// gratuites, sans compte/clé), avec un style personnalisé aux couleurs de
/// la marque (`assets/map_style.json`, dérivé du style "Positron"
/// d'OpenFreeMap — eau teintée de notre bleu, grandes routes teintées de
/// notre orange). Contrairement à des tuiles raster (images figées), le
/// rendu vectoriel reste net à n'importe quel niveau de zoom.
///
/// Une épingle par repère extérieur cartographié. Taper une épingle propose
/// de naviguer jusqu'à ce point, et, si le bâtiment a aussi été cartographié
/// à l'intérieur, d'y entrer directement (même graphe, le nœud tapé sert de
/// point de départ indoor — pas besoin de scanner un QR si on vient d'y
/// arriver par la navigation extérieure).
///
/// Affiche aussi les points importés (voir `custom_poi_store.dart`) : import
/// et parsing entièrement côté serveur (`server/main.py`, `/pois/import`) —
/// cet écran ne fait que récupérer (`GET /pois`) et afficher le résultat.
///
/// La carte la plus récemment envoyée au serveur est chargée automatiquement
/// à l'ouverture de cet écran — pas de sélection manuelle nécessaire.
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
    // style, ou l'utilisateur revient d'un écran de cartographie).
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

  /// Charge directement depuis le serveur, sans sélection manuelle : la
  /// carte la plus récemment envoyée ([MapGraphApiClient.listGraphs] les
  /// retourne triées par date de mise à jour), et les points importés.
  /// Échoue silencieusement (garde ce qui est déjà en mémoire/en cache) si
  /// le serveur est injoignable — pas bloquant pour afficher l'écran.
  Future<void> _syncFromServer() async {
    setState(() => _isSyncing = true);
    try {
      final summaries = await _apiClient.listGraphs();
      if (summaries.isNotEmpty) {
        final graph = await _apiClient.downloadGraph(summaries.first.id);
        if (mounted) ref.read(mapGraphProvider.notifier).setGraph(graph);
      }
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

  List<MapNode> get _outdoorNodes =>
      ref.read(mapGraphProvider)?.nodes.values
          .where((node) => node.kind == NodeKind.outdoorGps)
          .toList() ??
      const [];

  bool get _hasIndoorNodes =>
      ref.read(mapGraphProvider)?.nodes.values.any((n) => n.kind == NodeKind.indoorAnchor) ??
      false;

  LatLng? get _defaultCenter {
    final outdoorNodes = _outdoorNodes;
    if (outdoorNodes.isNotEmpty) {
      return LatLng(outdoorNodes.first.latitude!, outdoorNodes.first.longitude!);
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
          circleRadius: 10,
          circleColor: _toHex(PentamapColors.blue),
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
        ),
        {'type': 'node', 'id': node.id},
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
    if (data['type'] == 'node') {
      for (final node in _outdoorNodes) {
        if (node.id == data['id']) {
          _onNodeTapped(context, node, _hasIndoorNodes);
          return;
        }
      }
    } else if (data['type'] == 'poi') {
      for (final poi in ref.read(customPoiProvider)) {
        if (poi.id == data['id']) {
          _onCustomPoiTapped(context, poi);
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

    final hasAnyData = _outdoorNodes.isNotEmpty || ref.watch(customPoiProvider).isNotEmpty;
    final center = _initialCenter ?? _defaultCenter;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Carte'),
        actions: [
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

  void _onNodeTapped(BuildContext context, MapNode node, bool hasIndoorNodes) {
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
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ArNavigationScreen(destinationNodeId: node.id),
                  ),
                );
              },
            ),
            if (hasIndoorNodes) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.meeting_room_outlined),
                label: const Text('Entrer et naviguer à l\'intérieur'),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => IndoorDestinationPickerScreen(startNodeId: node.id),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _onCustomPoiTapped(BuildContext context, CustomPoi poi) {
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
                "Cartographiez d'abord un lieu (bouton \"Cartographier\" "
                "sur l'écran d'accueil) — la carte apparaîtra ici "
                "automatiquement une fois envoyée au serveur.",
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
