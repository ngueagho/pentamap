import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/map_graph.dart';
import '../../core/services/geo_utils.dart';
import 'route_calculator.dart';

/// Distance en dessous de laquelle on considère qu'un nœud du trajet est
/// atteint, et qu'on peut passer à l'étape suivante.
const _arrivalThresholdMeters = 8.0;

/// État de la navigation en cours, consommé par [ArNavigationScreen].
class NavigationState {
  final List<NavigationStep> steps;
  final int currentStepIndex;

  const NavigationState({
    this.steps = const [],
    this.currentStepIndex = 0,
  });

  NavigationStep? get currentStep =>
      currentStepIndex < steps.length ? steps[currentStepIndex] : null;

  bool get isArrived => steps.isNotEmpty && currentStepIndex >= steps.length;

  NavigationState copyWith({List<NavigationStep>? steps, int? currentStepIndex}) {
    return NavigationState(
      steps: steps ?? this.steps,
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
    );
  }
}

/// Pilote une navigation : calcule l'itinéraire au départ, puis avance
/// l'étape courante au fur et à mesure que la position GPS de l'utilisateur
/// se rapproche du nœud suivant.
class NavigationNotifier extends Notifier<NavigationState> {
  final _routeCalculator = RouteCalculator();

  // Retenus pour permettre un recalage (voir [resyncToNode]) sans que
  // l'appelant ait à re-fournir le graphe/la destination.
  MapGraph? _lastGraph;
  String? _lastDestinationNodeId;

  // Distance PDR accumulée depuis le dernier recalage (scan QR/arrivée à un
  // nœud) — voir [advanceByDistance].
  double _distanceSinceLastNode = 0;

  @override
  NavigationState build() => const NavigationState();

  void startRoute(MapGraph graph, String startNodeId, String destinationNodeId) {
    _lastGraph = graph;
    _lastDestinationNodeId = destinationNodeId;
    _distanceSinceLastNode = 0;
    final steps = _routeCalculator.computeRoute(graph, startNodeId, destinationNodeId);
    state = NavigationState(steps: steps, currentStepIndex: 0);
  }

  /// Calcule l'itinéraire depuis la position GPS actuelle de l'utilisateur
  /// (injectée dans le graphe via [MapGraph.withVirtualStart]) jusqu'à
  /// [destinationNodeId]. C'est le point d'entrée à utiliser pour une
  /// navigation extérieure classique — pas besoin que le point de départ
  /// ait été cartographié à l'avance.
  void startRouteToDestination(
    MapGraph graph,
    double currentLat,
    double currentLon,
    String destinationNodeId,
  ) {
    final augmented = graph.withVirtualStart(currentLat, currentLon);
    startRoute(augmented, virtualCurrentPositionNodeId, destinationNodeId);
  }

  void advanceToNextStep() {
    if (state.isArrived) return;
    _distanceSinceLastNode = 0;
    state = state.copyWith(currentStepIndex: state.currentStepIndex + 1);
  }

  /// Recalcule l'itinéraire à partir de [scannedNodeId] (un QR code
  /// fraîchement scanné) vers la destination déjà en cours — permet de
  /// corriger la dérive accumulée par l'odométrie à pas ([advanceByDistance])
  /// dès qu'un repère fixe est retrouvé, sans redemander la destination.
  /// Ne fait rien si aucune navigation n'est en cours.
  void resyncToNode(String scannedNodeId) {
    final graph = _lastGraph;
    final destinationNodeId = _lastDestinationNodeId;
    if (graph == null || destinationNodeId == null) return;
    startRoute(graph, scannedNodeId, destinationNodeId);
  }

  /// À appeler à chaque nouvelle position GPS reçue pendant la navigation :
  /// fait avancer automatiquement à l'étape suivante si l'utilisateur est
  /// arrivé à moins de [_arrivalThresholdMeters] du nœud actuellement visé.
  /// Gère le cas où plusieurs nœuds sont atteints d'un coup (peu probable
  /// en marchant, mais possible si la position saute).
  void updatePosition(double lat, double lon) {
    while (true) {
      final step = state.currentStep;
      if (step == null) return;
      final target = step.to;
      if (target.latitude == null) return;
      final distance = GeoUtils.haversineMeters(
        lat,
        lon,
        target.latitude!,
        target.longitude!,
      );
      if (distance <= _arrivalThresholdMeters) {
        advanceToNextStep();
        if (state.isArrived) return;
        continue; // vérifie si le nœud suivant est déjà atteint aussi
      }
      return;
    }
  }

  /// Équivalent indoor de [updatePosition] : à appeler avec la distance
  /// parcourue depuis le dernier appel (déduite du nombre de pas, voir
  /// `step_counter_service.dart`), plutôt qu'avec une position GPS absolue
  /// qui n'existe pas en intérieur. Avance à l'étape suivante dès que la
  /// distance accumulée dépasse celle du segment courant.
  ///
  /// ⚠️ Approximatif (longueur de pas moyenne) — l'erreur ne s'accumule
  /// qu'entre deux recalages : un scan QR ([resyncToNode]) la remet à zéro.
  void advanceByDistance(double metersSinceLastCall) {
    _distanceSinceLastNode += metersSinceLastCall;
    while (true) {
      final step = state.currentStep;
      if (step == null) return;
      if (_distanceSinceLastNode < step.distanceMeters) return;
      // Calculé avant advanceToNextStep(), qui remet le compteur à 0.
      final remainder = _distanceSinceLastNode - step.distanceMeters;
      advanceToNextStep();
      if (state.isArrived) return;
      _distanceSinceLastNode = remainder;
    }
  }
}

final navigationProvider = NotifierProvider<NavigationNotifier, NavigationState>(
  NavigationNotifier.new,
);
