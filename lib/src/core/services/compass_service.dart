import 'package:flutter_compass/flutter_compass.dart';

/// Enveloppe autour de `flutter_compass` : expose le cap magnétique
/// (0 = nord, en degrés), utilisé pour orienter la flèche AR quand
/// l'utilisateur ne bouge pas (le VIO seul ne donne pas d'orientation
/// absolue par rapport au nord).
class CompassService {
  /// `null` si l'appareil n'a pas de magnétomètre.
  Stream<double?> headingStream() {
    final events = FlutterCompass.events;
    if (events == null) return const Stream.empty();
    return events.map((event) => event.heading);
  }
}
