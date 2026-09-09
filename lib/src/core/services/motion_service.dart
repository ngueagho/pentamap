import 'package:sensors_plus/sensors_plus.dart';

/// Enveloppe autour de `sensors_plus` : expose l'accéléromètre et le
/// gyroscope, utilisés pour détecter les pas et les rotations fines de
/// l'utilisateur entre deux relocalisations visuelles (indoor).
class MotionService {
  static const _interval = SensorInterval.gameInterval; // ~60 Hz

  Stream<AccelerometerEvent> accelerometerStream() {
    return accelerometerEventStream(samplingPeriod: _interval);
  }

  Stream<GyroscopeEvent> gyroscopeStream() {
    return gyroscopeEventStream(samplingPeriod: _interval);
  }

  /// Accélération utilisateur, gravité déjà soustraite — plus directement
  /// exploitable pour la détection de pas que l'accéléromètre brut.
  Stream<UserAccelerometerEvent> userAccelerometerStream() {
    return userAccelerometerEventStream(samplingPeriod: _interval);
  }
}
