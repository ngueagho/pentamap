import 'dart:math';

import '../../core/models/map_graph.dart';
import '../../core/models/map_node.dart';
import '../../core/services/geo_utils.dart';

/// Une instruction pas à pas dérivée du chemin brut renvoyé par
/// [MapGraph.shortestPath].
class NavigationStep {
  final MapNode from;
  final MapNode to;
  final double distanceMeters;

  /// Cap absolu à suivre pour aller de [from] à [to], en degrés (0 = nord),
  /// calculé uniquement quand les deux nœuds ont des coordonnées GPS.
  /// `null` pour un segment indoor (pas de notion de cap absolu tant que la
  /// fusion de capteurs ne l'a pas résolu par rapport à une ancre).
  final double? bearingDegrees;

  const NavigationStep({
    required this.from,
    required this.to,
    required this.distanceMeters,
    this.bearingDegrees,
  });
}

/// Convertit le chemin brut (liste de nœuds) en instructions exploitables
/// par l'écran de navigation.
class RouteCalculator {
  List<NavigationStep> computeRoute(
    MapGraph graph,
    String startNodeId,
    String destinationNodeId,
  ) {
    final path = graph.shortestPath(startNodeId, destinationNodeId);
    if (path.length < 2) return [];

    final steps = <NavigationStep>[];
    for (var i = 0; i < path.length - 1; i++) {
      final from = path[i];
      final to = path[i + 1];
      steps.add(
        NavigationStep(
          from: from,
          to: to,
          distanceMeters: _distanceBetween(from, to),
          bearingDegrees: _bearingBetween(from, to),
        ),
      );
    }
    return steps;
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
      final dx = b.localX! - a.localX!;
      final dy = (b.localY ?? 0) - (a.localY ?? 0);
      final dz = b.localZ! - a.localZ!;
      return sqrt(dx * dx + dy * dy + dz * dz);
    }
    return 0;
  }

  double? _bearingBetween(MapNode a, MapNode b) {
    if (a.latitude == null || b.latitude == null) return null;
    return GeoUtils.bearingDegrees(
      a.latitude!,
      a.longitude!,
      b.latitude!,
      b.longitude!,
    );
  }
}
