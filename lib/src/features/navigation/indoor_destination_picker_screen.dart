import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_theme.dart';
import '../../core/models/map_graph.dart';
import '../../core/models/map_node.dart';
import '../../core/services/map_graph_api_client.dart';
import '../../core/services/map_graph_store.dart';
import '../camera_ar/ar_navigation_screen.dart';

/// Après un scan de QR code, ou un tap sur un bâtiment de la carte
/// extérieure ([startNodeId] connu dans les deux cas), liste les autres
/// points intérieurs de la même carte comme destinations possibles, et
/// lance la navigation indoor (odométrie à pas) vers celle choisie.
///
/// [graphId] n'est nécessaire que pour retélécharger la carte si elle n'est
/// pas déjà en mémoire (cas du scan QR après un redémarrage de l'app) — un
/// tap depuis la carte extérieure a déjà le graphe chargé, donc peut
/// l'omettre.
class IndoorDestinationPickerScreen extends ConsumerStatefulWidget {
  final String? graphId;
  final String startNodeId;

  const IndoorDestinationPickerScreen({
    super.key,
    this.graphId,
    required this.startNodeId,
  });

  @override
  ConsumerState<IndoorDestinationPickerScreen> createState() =>
      _IndoorDestinationPickerScreenState();
}

class _IndoorDestinationPickerScreenState
    extends ConsumerState<IndoorDestinationPickerScreen> {
  final _apiClient = MapGraphApiClient();
  Future<MapGraph>? _future;

  @override
  void initState() {
    super.initState();
    // Si le graphe scanné est déjà celui chargé en mémoire, pas besoin de
    // le retélécharger.
    final loaded = ref.read(mapGraphProvider);
    if (loaded != null && loaded.nodes.containsKey(widget.startNodeId)) {
      _future = Future.value(loaded);
    } else if (widget.graphId != null) {
      _future = _apiClient.downloadGraph(widget.graphId!).then((graph) {
        ref.read(mapGraphProvider.notifier).setGraph(graph);
        return graph;
      });
    } else {
      _future = Future.error(
        'Carte introuvable en mémoire et aucun identifiant de carte fourni.',
      );
    }
  }

  @override
  void dispose() {
    _apiClient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choisir une destination')),
      body: FutureBuilder<MapGraph>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Impossible de charger la carte : ${snapshot.error}'),
            );
          }
          final graph = snapshot.data!;
          final destinations = graph.nodes.values
              .where((n) =>
                  n.kind == NodeKind.indoorAnchor && n.id != widget.startNodeId)
              .toList();
          if (destinations.isEmpty) {
            return const Center(
              child: Text('Aucune autre destination sur cette carte.'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            itemCount: destinations.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final node = destinations[index];
              return Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: CircleAvatar(
                    backgroundColor: PentamapColors.orange.withValues(alpha: 0.14),
                    foregroundColor: PentamapColors.orange,
                    child: const Icon(Icons.anchor, size: 20),
                  ),
                  title: Text(node.label),
                  subtitle: node.floor != null ? Text('Étage ${node.floor}') : null,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ArNavigationScreen(
                        destinationNodeId: node.id,
                        indoorStartNodeId: widget.startNodeId,
                      ),
                    ),
                  );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
