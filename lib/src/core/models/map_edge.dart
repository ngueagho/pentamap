/// Une arête du graphe de carte : un chemin praticable entre deux nœuds.
class MapEdge {
  final String fromNodeId;
  final String toNodeId;

  /// Distance en mètres, utilisée comme poids par l'algorithme de plus
  /// court chemin (Dijkstra/A*).
  final double distanceMeters;

  /// Vrai si le chemin peut être parcouru dans les deux sens.
  final bool bidirectional;

  const MapEdge({
    required this.fromNodeId,
    required this.toNodeId,
    required this.distanceMeters,
    this.bidirectional = true,
  });

  factory MapEdge.fromJson(Map<String, dynamic> json) => MapEdge(
        fromNodeId: json['fromNodeId'] as String,
        toNodeId: json['toNodeId'] as String,
        distanceMeters: (json['distanceMeters'] as num).toDouble(),
        bidirectional: json['bidirectional'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'fromNodeId': fromNodeId,
        'toNodeId': toNodeId,
        'distanceMeters': distanceMeters,
        'bidirectional': bidirectional,
      };
}
