import 'package:sensors_plus/sensors_plus.dart';

/// Enveloppe autour du baromètre (`sensors_plus`), utilisé pour détecter les
/// changements d'étage.
///
/// ⚠️ Volontairement basé sur la pression **relative**, pas absolue :
/// l'altitude déduite du GPS a une erreur de ±10-30 m (bien plus que les
/// ~3-4 m entre deux étages), donc inexploitable pour ça — c'est la méthode
/// utilisée par les vraies apps de nav indoor (Google Maps y compris) :
/// mesurer l'écart de pression par rapport à un point de référence connu
/// (ex: l'entrée du bâtiment), pas une valeur absolue.
class BarometerService {
  /// Chute de pression (hPa) associée à peu près à une montée d'un étage
  /// standard (~3 m). Approximatif — la vraie valeur dépend de l'altitude
  /// de base et de la météo (pression atmosphérique ambiante), mais utile
  /// comme heuristique de détection de changement d'étage en intérieur sur
  /// une courte période (quelques minutes), où la météo ne varie pas.
  static const hpaPerFloor = 0.35;

  Stream<double> pressureStream() {
    return barometerEventStream().map((event) => event.pressure);
  }

  /// Estime le nombre d'étages franchis entre [referenceHpa] (mesuré à un
  /// point connu, ex: à l'entrée) et [currentHpa]. Positif = monté,
  /// négatif = descendu. Arrondi à l'entier le plus proche.
  int estimateFloorDelta(double referenceHpa, double currentHpa) {
    final deltaHpa = referenceHpa - currentHpa; // pression baisse en montant
    return (deltaHpa / hpaPerFloor).round();
  }
}
