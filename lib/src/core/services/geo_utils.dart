import 'dart:math';

/// Fonctions géométriques partagées (distance/cap entre coordonnées GPS),
/// utilisées à la fois par le calcul d'itinéraire et par l'enregistrement
/// de carte pendant la cartographie.
class GeoUtils {
  const GeoUtils._();

  /// Distance orthodromique (grand cercle) entre deux points GPS, en mètres.
  static double haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusMeters = 6371000.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(lat1)) *
            cos(_degToRad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Cap absolu (0 = nord, en degrés) pour aller du point 1 vers le point 2.
  static double bearingDegrees(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final phi1 = _degToRad(lat1);
    final phi2 = _degToRad(lat2);
    final dLon = _degToRad(lon2 - lon1);

    final y = sin(dLon) * cos(phi2);
    final x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLon);
    return (_radToDeg(atan2(y, x)) + 360) % 360;
  }

  /// Moyenne pondérée (lissage exponentiel) de deux caps en degrés, en
  /// gérant correctement le passage 359°→0° (une moyenne naïve de 359 et 1
  /// donnerait 180, ce qui est faux — on moyenne via les composantes
  /// sin/cos plutôt que les degrés directement).
  ///
  /// [weight] est le poids donné à [newAngle] (entre 0 et 1) : proche de 1 =
  /// réagit vite aux nouvelles mesures, proche de 0 = lisse fortement.
  static double smoothAngleDegrees(
    double previousAngle,
    double newAngle,
    double weight,
  ) {
    final prevRad = _degToRad(previousAngle);
    final newRad = _degToRad(newAngle);
    final x = cos(prevRad) * (1 - weight) + cos(newRad) * weight;
    final y = sin(prevRad) * (1 - weight) + sin(newRad) * weight;
    return (_radToDeg(atan2(y, x)) + 360) % 360;
  }

  static double _degToRad(double deg) => deg * pi / 180;
  static double _radToDeg(double rad) => rad * 180 / pi;
}
