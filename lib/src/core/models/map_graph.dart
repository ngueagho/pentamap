import '../services/geo_utils.dart';
import 'map_edge.dart';
import 'map_node.dart';

/// Identifiant réservé au nœud virtuel injecté par [MapGraph.withVirtualStart].
const virtualCurrentPositionNodeId = '__current_position__';

/// Le graphe complet d'un établissement : tous les nœuds (repères GPS
/// extérieurs + ancres visuelles intérieures) et les chemins qui les relient.
///
/// Construit côté serveur pendant la phase de cartographie, puis téléchargé
/// par l'app pour le calcul d'itinéraire côté client.
class MapGraph {
  final Map<String, MapNode> nodes;
  final List<MapEdge> edges;

  MapGraph({required this.nodes, required this.edges});

  factory MapGraph.fromJson(Map<String, dynamic> json) {
    final nodesJson = json['nodes'] as List;
    final edgesJson = json['edges'] as List;
    return MapGraph(
      nodes: {
        for (final n in nodesJson)
          (n as Map<String, dynamic>)['id'] as String: MapNode.fromJson(n),
      },
      edges: edgesJson
          .map((e) => MapEdge.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'nodes': nodes.values.map((n) => n.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
      };

  /// Liste d'adjacence : pour chaque nœud, les (voisin, distance) atteignables.
  Map<String, List<(String, double)>> _adjacency() {
    final adj = <String, List<(String, double)>>{};
    for (final e in edges) {
      adj.putIfAbsent(e.fromNodeId, () => []).add((e.toNodeId, e.distanceMeters));
      if (e.bidirectional) {
        adj.putIfAbsent(e.toNodeId, () => []).add((e.fromNodeId, e.distanceMeters));
      }
    }
    return adj;
  }

  /// Calcule le plus court chemin entre [startId] et [endId] avec Dijkstra.
  /// Retourne la séquence ordonnée de [MapNode] à suivre, ou une liste vide
  /// si aucun chemin n'existe.
  List<MapNode> shortestPath(String startId, String endId) {
    if (!nodes.containsKey(startId) || !nodes.containsKey(endId)) return [];
    if (startId == endId) return [nodes[startId]!];

    final adj = _adjacency();
    final distances = <String, double>{startId: 0};
    final previous = <String, String>{};
    final visited = <String>{};

    final queue = PriorityQueue<(String, double)>((a, b) => a.$2.compareTo(b.$2));
    queue.add((startId, 0));

    while (queue.isNotEmpty) {
      final (current, currentDist) = queue.removeFirst();
      if (visited.contains(current)) continue;
      visited.add(current);
      if (current == endId) break;

      for (final (neighbor, weight) in adj[current] ?? const <(String, double)>[]) {
        final candidate = currentDist + weight;
        if (candidate < (distances[neighbor] ?? double.infinity)) {
          distances[neighbor] = candidate;
          previous[neighbor] = current;
          queue.add((neighbor, candidate));
        }
      }
    }

    if (!distances.containsKey(endId)) return []; // pas de chemin

    final path = <MapNode>[];
    var step = endId;
    while (step != startId) {
      path.add(nodes[step]!);
      step = previous[step]!;
    }
    path.add(nodes[startId]!);
    return path.reversed.toList();
  }

  /// Retourne une copie de ce graphe avec un nœud GPS supplémentaire
  /// représentant la position actuelle de l'utilisateur ([lat]/[lon]),
  /// relié au nœud extérieur connu le plus proche.
  ///
  /// Permet de calculer un itinéraire depuis "là où je suis maintenant"
  /// sans que ce point n'ait besoin d'avoir été cartographié à l'avance.
  MapGraph withVirtualStart(double lat, double lon) {
    MapNode? nearest;
    double? nearestDistance;
    for (final node in nodes.values) {
      if (node.kind != NodeKind.outdoorGps || node.latitude == null) continue;
      final distance = GeoUtils.haversineMeters(
        lat,
        lon,
        node.latitude!,
        node.longitude!,
      );
      if (nearestDistance == null || distance < nearestDistance) {
        nearestDistance = distance;
        nearest = node;
      }
    }

    final virtualNode = MapNode(
      id: virtualCurrentPositionNodeId,
      label: 'Position actuelle',
      kind: NodeKind.outdoorGps,
      latitude: lat,
      longitude: lon,
    );

    final newNodes = Map<String, MapNode>.from(nodes)
      ..[virtualCurrentPositionNodeId] = virtualNode;
    final newEdges = List<MapEdge>.from(edges);
    if (nearest != null) {
      newEdges.add(MapEdge(
        fromNodeId: virtualCurrentPositionNodeId,
        toNodeId: nearest.id,
        distanceMeters: nearestDistance!,
      ));
    }

    return MapGraph(nodes: newNodes, edges: newEdges);
  }
}

/// Petite file de priorité minimale suffisante pour Dijkstra, en attendant
/// d'ajouter le package `collection` si des besoins plus poussés apparaissent.
class PriorityQueue<E> {
  final List<E> _items = [];
  final Comparator<E> _comparator;

  PriorityQueue(this._comparator);

  bool get isNotEmpty => _items.isNotEmpty;

  void add(E item) {
    _items.add(item);
    _items.sort(_comparator);
  }

  E removeFirst() => _items.removeAt(0);
}
