import 'dart:async';

import 'package:pedometer/pedometer.dart';

/// Enveloppe autour du podomètre natif (`pedometer`), utilisé pour estimer
/// la distance parcourue entre deux repères fixes (QR code, ancre) — c'est
/// l'odométrie à pas (PDR, "Pedestrian Dead Reckoning"), la méthode standard
/// pour suivre un déplacement en intérieur entre deux points de recalage.
///
/// ⚠️ Approximatif par nature : la longueur de pas moyenne ([strideMeters])
/// varie d'une personne à l'autre et selon l'allure. C'est pour ça que ça
/// doit être combiné à des points de recalage réguliers (QR codes) plutôt
/// qu'utilisé seul sur de longues distances — l'erreur ne s'accumule que
/// entre deux scans, pas sur tout un trajet.
class StepCounterService {
  /// Longueur de pas moyenne, en mètres. ~0.7-0.8 m est une valeur usuelle
  /// pour un adulte à allure normale ; à affiner/rendre configurable si
  /// besoin d'une meilleure précision par utilisateur.
  static const strideMeters = 0.75;

  int? _baselineSteps;

  /// Flux du nombre de mètres parcourus **depuis le premier événement reçu**
  /// (remet le compteur à zéro à chaque nouvel abonnement, pratique pour
  /// mesurer la distance depuis le dernier recalage/scan QR).
  Stream<double> distanceStream() {
    _baselineSteps = null;
    return Pedometer.stepCountStream.map((event) {
      _baselineSteps ??= event.steps;
      final stepsSinceStart = event.steps - _baselineSteps!;
      return stepsSinceStart * strideMeters;
    });
  }
}
