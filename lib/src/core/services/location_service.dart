import 'package:geolocator/geolocator.dart';

/// Enveloppe autour de `geolocator` : gère la permission et expose la
/// position GPS de l'utilisateur (utilisée en extérieur, et comme donnée
/// d'appoint en intérieur).
class LocationService {
  static const _settings = LocationSettings(
    accuracy: LocationAccuracy.best,
    distanceFilter: 1, // ré-émettre dès que l'utilisateur bouge de 1 m
  );

  /// Demande la permission de localisation si besoin. Retourne `true` si
  /// elle est accordée (au moins "en cours d'utilisation").
  Future<bool> ensurePermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) return false;
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Future<Position> getCurrentPosition() {
    return Geolocator.getCurrentPosition(
      locationSettings: _settings,
    );
  }

  /// Flux continu de position, utilisé pendant la cartographie (trace GPS)
  /// et pendant la navigation extérieure.
  Stream<Position> positionStream() {
    return Geolocator.getPositionStream(locationSettings: _settings);
  }
}
