import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../app/app_theme.dart';
import '../../core/models/building.dart';
import '../../core/models/map_edge.dart';
import '../../core/models/map_graph.dart';
import '../../core/models/map_node.dart';
import '../../core/services/geo_utils.dart';
import '../../core/services/location_service.dart';
import '../../core/services/map_graph_api_client.dart';
import '../../core/services/map_graph_store.dart';

/// Interface d'administration **dans l'app** : ajouter/modifier/supprimer
/// des bâtiments, des points (pièces/repères) et des liaisons — le pendant
/// mobile du dashboard web (`server/admin/`), toutes deux pilotant les
/// mêmes endpoints (`server/main.py`). Graphe abstrait (points + distances),
/// pas de plan importé — un point se place en donnant ses coordonnées GPS
/// (extérieur) ou juste un nom + un étage (intérieur, rattaché à un
/// bâtiment).
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  final _apiClient = MapGraphApiClient();
  final _locationService = LocationService();
  bool _isLoading = true;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _ensureGraphLoaded();
  }

  @override
  void dispose() {
    _apiClient.dispose();
    super.dispose();
  }

  Future<void> _ensureGraphLoaded() async {
    final existing = ref.read(mapGraphProvider);
    if (existing?.id == null) {
      try {
        await ref.read(mapGraphProvider.notifier).refreshFromServer(_apiClient);
      } catch (_) {
        // L'écran affichera quand même les données locales si présentes.
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  MapGraph? get _graph => ref.watch(mapGraphProvider);
  String? get _graphId => _graph?.id;

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    if (_isLoading || graph == null || graph.id == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Administration')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final outdoorNodes = graph.nodes.values.where((n) => n.kind == NodeKind.outdoorGps).toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Administration'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Bâtiments'),
            Tab(text: 'Points extérieurs'),
            Tab(text: 'Liaisons'),
          ]),
        ),
        body: _isBusy
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _BuildingsTab(
                    graph: graph,
                    apiClient: _apiClient,
                    locationService: _locationService,
                    setBusy: _setBusy,
                    onChanged: _reload,
                  ),
                  _OutdoorNodesTab(
                    graph: graph,
                    outdoorNodes: outdoorNodes,
                    apiClient: _apiClient,
                    locationService: _locationService,
                    setBusy: _setBusy,
                    onChanged: _reload,
                  ),
                  _EdgesTab(
                    graph: graph,
                    apiClient: _apiClient,
                    setBusy: _setBusy,
                    onChanged: _reload,
                  ),
                ],
              ),
      ),
    );
  }

  void _setBusy(bool busy) => setState(() => _isBusy = busy);

  Future<void> _reload() async {
    try {
      final graph = await _apiClient.downloadGraph(_graphId!);
      ref.read(mapGraphProvider.notifier).setGraph(graph);
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------
// Bâtiments
// ---------------------------------------------------------------------

class _BuildingsTab extends StatelessWidget {
  final MapGraph graph;
  final MapGraphApiClient apiClient;
  final LocationService locationService;
  final void Function(bool) setBusy;
  final Future<void> Function() onChanged;

  const _BuildingsTab({
    required this.graph,
    required this.apiClient,
    required this.locationService,
    required this.setBusy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editBuilding(context, null),
        child: const Icon(Icons.add),
      ),
      body: graph.buildings.isEmpty
          ? const Center(child: Text('Aucun bâtiment. Appuyez sur + pour en créer un.'))
          : ListView.builder(
              itemCount: graph.buildings.length,
              itemBuilder: (context, i) {
                final b = graph.buildings[i];
                final roomCount = graph.nodes.values.where((n) => n.buildingId == b.id).length;
                return ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x22E08A3C),
                    foregroundColor: PentamapColors.orange,
                    child: Icon(Icons.apartment),
                  ),
                  title: Text(b.name),
                  subtitle: Text(
                    '${b.latitude.toStringAsFixed(5)}, ${b.longitude.toStringAsFixed(5)} · '
                    '$roomCount pièce(s)'
                    '${b.entranceNodeId == null ? ' · pas d\'entrée définie' : ''}',
                  ),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _BuildingDetailScreen(
                      graph: graph,
                      building: b,
                      apiClient: apiClient,
                      setBusy: setBusy,
                      onChanged: onChanged,
                    ),
                  )),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') _editBuilding(context, b);
                      if (v == 'delete') _deleteBuilding(context, b);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Modifier')),
                      PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _editBuilding(BuildContext context, Building? existing) async {
    final result = await showDialog<Building>(
      context: context,
      builder: (_) => _BuildingFormDialog(existing: existing, locationService: locationService),
    );
    if (result == null) return;
    setBusy(true);
    try {
      if (existing == null) {
        await apiClient.createBuilding(graph.id!, result);
      } else {
        await apiClient.updateBuilding(graph.id!, result);
      }
      await onChanged();
    } finally {
      setBusy(false);
    }
  }

  Future<void> _deleteBuilding(BuildContext context, Building b) async {
    final confirmed = await _confirm(context, 'Supprimer "${b.name}" ? Ses pièces resteront mais ne seront plus rattachées à ce bâtiment.');
    if (!confirmed) return;
    setBusy(true);
    try {
      await apiClient.deleteBuilding(graph.id!, b.id);
      await onChanged();
    } finally {
      setBusy(false);
    }
  }
}

class _BuildingFormDialog extends StatefulWidget {
  final Building? existing;
  final LocationService locationService;

  const _BuildingFormDialog({this.existing, required this.locationService});

  @override
  State<_BuildingFormDialog> createState() => _BuildingFormDialogState();
}

class _BuildingFormDialogState extends State<_BuildingFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _lat = TextEditingController(text: widget.existing?.latitude.toString() ?? '');
  late final _lon = TextEditingController(text: widget.existing?.longitude.toString() ?? '');
  late final _description = TextEditingController(text: widget.existing?.description ?? '');
  bool _locating = false;

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final hasPermission = await widget.locationService.ensurePermission();
      if (!hasPermission) return;
      final Position position = await widget.locationService.getCurrentPosition();
      _lat.text = position.latitude.toString();
      _lon.text = position.longitude.toString();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Nouveau bâtiment' : 'Modifier le bâtiment'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nom')),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _lat,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Latitude'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _lon,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Longitude'),
              ),
            ),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: _locating
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location, size: 16),
              label: const Text('Utiliser ma position actuelle'),
              onPressed: _locating ? null : _useCurrentLocation,
            ),
          ),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Description (optionnel)'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            final lat = double.tryParse(_lat.text);
            final lon = double.tryParse(_lon.text);
            if (_name.text.trim().isEmpty || lat == null || lon == null) return;
            Navigator.of(context).pop(Building(
              id: widget.existing?.id ?? '',
              graphId: widget.existing?.graphId ?? '',
              name: _name.text.trim(),
              latitude: lat,
              longitude: lon,
              entranceNodeId: widget.existing?.entranceNodeId,
              description: _description.text.trim().isEmpty ? null : _description.text.trim(),
            ));
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

class _BuildingDetailScreen extends StatelessWidget {
  final MapGraph graph;
  final Building building;
  final MapGraphApiClient apiClient;
  final void Function(bool) setBusy;
  final Future<void> Function() onChanged;

  const _BuildingDetailScreen({
    required this.graph,
    required this.building,
    required this.apiClient,
    required this.setBusy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final roomsByFloor = graph.roomsByFloor(building.id);
    final floors = roomsByFloor.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: Text(building.name)),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editRoom(context, null),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Nœud d\'entrée'),
            subtitle: Text(building.entranceNodeId == null
                ? 'Aucun — reliez un point extérieur comme entrée depuis l\'onglet Liaisons'
                : graph.nodes[building.entranceNodeId]?.label ?? building.entranceNodeId!),
          ),
          const Divider(),
          if (floors.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Aucune pièce. Appuyez sur + pour en ajouter une.'),
            ),
          for (final floor in floors) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Étage $floor', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final room in roomsByFloor[floor]!)
              ListTile(
                leading: const Icon(Icons.meeting_room_outlined),
                title: Text(room.label),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'edit') _editRoom(context, room);
                    if (v == 'delete') _deleteRoom(context, room);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Modifier')),
                    PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _editRoom(BuildContext context, MapNode? existing) async {
    final result = await showDialog<MapNode>(
      context: context,
      builder: (_) => _RoomFormDialog(existing: existing, buildingId: building.id),
    );
    if (result == null) return;
    setBusy(true);
    try {
      if (existing == null) {
        await apiClient.createNode(graph.id!, result);
      } else {
        await apiClient.updateNode(graph.id!, result);
      }
      await onChanged();
    } finally {
      setBusy(false);
    }
  }

  Future<void> _deleteRoom(BuildContext context, MapNode room) async {
    final confirmed = await _confirm(context, 'Supprimer "${room.label}" ?');
    if (!confirmed) return;
    setBusy(true);
    try {
      await apiClient.deleteNode(graph.id!, room.id);
      await onChanged();
    } finally {
      setBusy(false);
    }
  }
}

class _RoomFormDialog extends StatefulWidget {
  final MapNode? existing;
  final String buildingId;

  const _RoomFormDialog({this.existing, required this.buildingId});

  @override
  State<_RoomFormDialog> createState() => _RoomFormDialogState();
}

class _RoomFormDialogState extends State<_RoomFormDialog> {
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _floor = TextEditingController(text: (widget.existing?.floor ?? 0).toString());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Nouvelle pièce' : 'Modifier la pièce'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _label, decoration: const InputDecoration(labelText: 'Nom (ex: Salle 101)')),
        TextField(
          controller: _floor,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: const InputDecoration(labelText: 'Étage'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            if (_label.text.trim().isEmpty) return;
            Navigator.of(context).pop(MapNode(
              id: widget.existing?.id ?? '',
              label: _label.text.trim(),
              kind: NodeKind.indoorAnchor,
              floor: int.tryParse(_floor.text) ?? 0,
              buildingId: widget.buildingId,
            ));
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Points extérieurs
// ---------------------------------------------------------------------

class _OutdoorNodesTab extends StatelessWidget {
  final MapGraph graph;
  final List<MapNode> outdoorNodes;
  final MapGraphApiClient apiClient;
  final LocationService locationService;
  final void Function(bool) setBusy;
  final Future<void> Function() onChanged;

  const _OutdoorNodesTab({
    required this.graph,
    required this.outdoorNodes,
    required this.apiClient,
    required this.locationService,
    required this.setBusy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editNode(context, null),
        child: const Icon(Icons.add),
      ),
      body: outdoorNodes.isEmpty
          ? const Center(child: Text('Aucun point extérieur. Appuyez sur + pour en ajouter un.'))
          : ListView.builder(
              itemCount: outdoorNodes.length,
              itemBuilder: (context, i) {
                final n = outdoorNodes[i];
                return ListTile(
                  leading: const Icon(Icons.satellite_alt_outlined, color: PentamapColors.blue),
                  title: Text(n.label),
                  subtitle: Text('${n.latitude?.toStringAsFixed(5)}, ${n.longitude?.toStringAsFixed(5)}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') _editNode(context, n);
                      if (v == 'delete') _deleteNode(context, n);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Modifier')),
                      PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _editNode(BuildContext context, MapNode? existing) async {
    final result = await showDialog<MapNode>(
      context: context,
      builder: (_) => _OutdoorNodeFormDialog(existing: existing, locationService: locationService),
    );
    if (result == null) return;
    setBusy(true);
    try {
      if (existing == null) {
        await apiClient.createNode(graph.id!, result);
      } else {
        await apiClient.updateNode(graph.id!, result);
      }
      await onChanged();
    } finally {
      setBusy(false);
    }
  }

  Future<void> _deleteNode(BuildContext context, MapNode node) async {
    final confirmed = await _confirm(context, 'Supprimer "${node.label}" ?');
    if (!confirmed) return;
    setBusy(true);
    try {
      await apiClient.deleteNode(graph.id!, node.id);
      await onChanged();
    } finally {
      setBusy(false);
    }
  }
}

class _OutdoorNodeFormDialog extends StatefulWidget {
  final MapNode? existing;
  final LocationService locationService;

  const _OutdoorNodeFormDialog({this.existing, required this.locationService});

  @override
  State<_OutdoorNodeFormDialog> createState() => _OutdoorNodeFormDialogState();
}

class _OutdoorNodeFormDialogState extends State<_OutdoorNodeFormDialog> {
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _lat = TextEditingController(text: widget.existing?.latitude?.toString() ?? '');
  late final _lon = TextEditingController(text: widget.existing?.longitude?.toString() ?? '');
  bool _locating = false;

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final hasPermission = await widget.locationService.ensurePermission();
      if (!hasPermission) return;
      final position = await widget.locationService.getCurrentPosition();
      _lat.text = position.latitude.toString();
      _lon.text = position.longitude.toString();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Nouveau point extérieur' : 'Modifier le point'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _label, decoration: const InputDecoration(labelText: 'Nom')),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _lat,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Latitude'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _lon,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Longitude'),
              ),
            ),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: _locating
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location, size: 16),
              label: const Text('Utiliser ma position actuelle'),
              onPressed: _locating ? null : _useCurrentLocation,
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            final lat = double.tryParse(_lat.text);
            final lon = double.tryParse(_lon.text);
            if (_label.text.trim().isEmpty || lat == null || lon == null) return;
            Navigator.of(context).pop(MapNode(
              id: widget.existing?.id ?? '',
              label: _label.text.trim(),
              kind: NodeKind.outdoorGps,
              latitude: lat,
              longitude: lon,
            ));
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Liaisons
// ---------------------------------------------------------------------

class _EdgesTab extends StatelessWidget {
  final MapGraph graph;
  final MapGraphApiClient apiClient;
  final void Function(bool) setBusy;
  final Future<void> Function() onChanged;

  const _EdgesTab({
    required this.graph,
    required this.apiClient,
    required this.setBusy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editEdge(context),
        child: const Icon(Icons.add),
      ),
      body: graph.edges.isEmpty
          ? const Center(child: Text('Aucune liaison. Appuyez sur + pour en créer une.'))
          : ListView.builder(
              itemCount: graph.edges.length,
              itemBuilder: (context, i) {
                final e = graph.edges[i];
                final from = graph.nodes[e.fromNodeId]?.label ?? e.fromNodeId;
                final to = graph.nodes[e.toNodeId]?.label ?? e.toNodeId;
                return ListTile(
                  leading: Icon(e.bidirectional ? Icons.sync_alt : Icons.arrow_forward),
                  title: Text('$from → $to'),
                  subtitle: Text('${e.distanceMeters.toStringAsFixed(1)} m'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: e.id == null ? null : () => _deleteEdge(context, e),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _editEdge(BuildContext context) async {
    final allNodes = graph.nodes.values.toList()..sort((a, b) => a.label.compareTo(b.label));
    final result = await showDialog<MapEdge>(
      context: context,
      builder: (_) => _EdgeFormDialog(nodes: allNodes),
    );
    if (result == null) return;
    setBusy(true);
    try {
      await apiClient.createEdge(graph.id!, result);
      await onChanged();
    } finally {
      setBusy(false);
    }
  }

  Future<void> _deleteEdge(BuildContext context, MapEdge e) async {
    final confirmed = await _confirm(context, 'Supprimer cette liaison ?');
    if (!confirmed) return;
    setBusy(true);
    try {
      await apiClient.deleteEdge(graph.id!, e.id!);
      await onChanged();
    } finally {
      setBusy(false);
    }
  }
}

class _EdgeFormDialog extends StatefulWidget {
  final List<MapNode> nodes;

  const _EdgeFormDialog({required this.nodes});

  @override
  State<_EdgeFormDialog> createState() => _EdgeFormDialogState();
}

class _EdgeFormDialogState extends State<_EdgeFormDialog> {
  String? _fromId;
  String? _toId;
  final _distance = TextEditingController();
  bool _bidirectional = true;

  void _autoFillDistance() {
    final from = widget.nodes.where((n) => n.id == _fromId).firstOrNull;
    final to = widget.nodes.where((n) => n.id == _toId).firstOrNull;
    if (from == null || to == null) return;
    double? distance;
    if (from.latitude != null && to.latitude != null) {
      distance = GeoUtils.haversineMeters(from.latitude!, from.longitude!, to.latitude!, to.longitude!);
    } else if (from.localX != null && to.localX != null) {
      final dx = to.localX! - from.localX!;
      final dy = (to.localY ?? 0) - (from.localY ?? 0);
      final dz = to.localZ! - from.localZ!;
      distance = sqrt(dx * dx + dy * dy + dz * dz);
    }
    if (distance != null) _distance.text = distance.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouvelle liaison'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: _fromId,
            decoration: const InputDecoration(labelText: 'De'),
            items: [for (final n in widget.nodes) DropdownMenuItem(value: n.id, child: Text(n.label))],
            onChanged: (v) => setState(() {
              _fromId = v;
              _autoFillDistance();
            }),
          ),
          DropdownButtonFormField<String>(
            initialValue: _toId,
            decoration: const InputDecoration(labelText: 'Vers'),
            items: [for (final n in widget.nodes) DropdownMenuItem(value: n.id, child: Text(n.label))],
            onChanged: (v) => setState(() {
              _toId = v;
              _autoFillDistance();
            }),
          ),
          TextField(
            controller: _distance,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Distance (mètres)'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Bidirectionnel'),
            value: _bidirectional,
            onChanged: (v) => setState(() => _bidirectional = v),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            final distance = double.tryParse(_distance.text);
            if (_fromId == null || _toId == null || _fromId == _toId || distance == null) return;
            Navigator.of(context).pop(MapEdge(
              fromNodeId: _fromId!,
              toNodeId: _toId!,
              distanceMeters: distance,
              bidirectional: _bidirectional,
            ));
          },
          child: const Text('Créer'),
        ),
      ],
    );
  }
}

Future<bool> _confirm(BuildContext context, String message) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Supprimer')),
      ],
    ),
  );
  return result ?? false;
}
