import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../core/services/compass_service.dart';
import '../../core/services/geo_utils.dart';
import '../../core/services/location_service.dart';
import '../../core/services/motion_service.dart';

/// En dessous de cette vitesse (m/s), le cap de déplacement du GPS n'est
/// pas fiable (bruit de position dominant) — on retombe sur la boussole.
/// ~0.8 m/s ≈ une marche lente ; en dessous, on considère l'utilisateur
/// à l'arrêt ou hésitant.
const _minSpeedForGpsHeadingMs = 0.8;

/// Poids du lissage exponentiel appliqué au cap à chaque mise à jour
/// (proche de 1 = réactif mais bruité, proche de 0 = stable mais lent à
/// suivre un vrai changement de direction).
const _headingSmoothingWeight = 0.25;

/// Estimation de la pose de l'utilisateur à un instant donné.
///
/// En extérieur, [latitude]/[longitude] viennent directement du GPS.
/// En intérieur, ils restent ceux de la dernière relocalisation visuelle
/// connue tant qu'aucune nouvelle relocalisation n'a eu lieu — la position
/// fine entre deux relocalisations devra être estimée par le VIO d'ARKit/
/// ARCore (exposé par `ar_flutter_plugin_plus` via la pose caméra), pas
/// encore branché ici.
class UserPose {
  final double? latitude;
  final double? longitude;

  /// Cap en degrés (0 = nord), lissé, et calculé à partir de la source la
  /// plus fiable disponible sur le moment (voir [headingSource]).
  final double? headingDegrees;

  /// D'où vient [headingDegrees] pour ce point — utile pour du debug/UI
  /// ("cap GPS" est nettement plus fiable que "boussole" en marchant).
  final HeadingSource? headingSource;

  final DateTime timestamp;

  const UserPose({
    this.latitude,
    this.longitude,
    this.headingDegrees,
    this.headingSource,
    required this.timestamp,
  });
}

enum HeadingSource { gpsCourseOverGround, compass }

/// Combine GPS + boussole (+ IMU à terme) en un flux unique de pose.
///
/// Deux mesures de précision appliquées ici :
/// 1. **Choix de la source de cap** : en marchant, le cap de déplacement
///    calculé par le GPS lui-même (`Position.heading`, dérivé de la
///    trajectoire réelle) est bien plus fiable que le magnétomètre du
///    téléphone (sensible aux interférences, mal calibré). On ne retombe
///    sur la boussole qu'à l'arrêt ou en marchant très lentement.
/// 2. **Lissage** : chaque nouveau cap est mélangé avec le précédent
///    (moyenne circulaire, voir [GeoUtils.smoothAngleDegrees]) plutôt que
///    republié brut, pour éviter que la flèche ne tremble à chaque mesure
///    bruitée.
///
/// ⚠️ Toujours pas de vrai filtre de Kalman/complementary filter intégrant
/// le gyroscope (`_motion`) entre deux positions GPS — ce serait l'étape
/// suivante pour une précision encore meilleure (voir pathfinding_notes.md).
class SensorFusionService {
  final LocationService _location;
  final CompassService _compass;
  // Réservé à une future intégration IMU pour interpoler entre deux
  // positions GPS (fusion façon Kalman/complementary filter) — pas encore
  // consommé.
  // ignore: unused_field
  final MotionService _motion;

  SensorFusionService({
    LocationService? location,
    CompassService? compass,
    MotionService? motion,
  })  : _location = location ?? LocationService(),
        _compass = compass ?? CompassService(),
        _motion = motion ?? MotionService();

  Stream<UserPose> poseStream() {
    double? lastLat;
    double? lastLon;
    double? lastCompassHeading;
    double? smoothedHeading;
    HeadingSource? headingSource;

    final controller = StreamController<UserPose>.broadcast();
    final subscriptions = <StreamSubscription>[];

    void emit() {
      controller.add(UserPose(
        latitude: lastLat,
        longitude: lastLon,
        headingDegrees: smoothedHeading,
        headingSource: headingSource,
        timestamp: DateTime.now(),
      ));
    }

    void applyNewHeading(double rawHeading, HeadingSource source) {
      smoothedHeading = smoothedHeading == null
          ? rawHeading
          : GeoUtils.smoothAngleDegrees(
              smoothedHeading!,
              rawHeading,
              _headingSmoothingWeight,
            );
      headingSource = source;
    }

    controller.onListen = () {
      subscriptions.add(_location.positionStream().listen((Position position) {
        lastLat = position.latitude;
        lastLon = position.longitude;

        // En mouvement suffisant : le cap de déplacement GPS prime sur la
        // boussole. `heading` est en degrés (0 = nord), fourni par l'OS à
        // partir de la trajectoire réelle — indépendant du magnétomètre.
        if (position.speed >= _minSpeedForGpsHeadingMs) {
          applyNewHeading(position.heading, HeadingSource.gpsCourseOverGround);
        } else if (lastCompassHeading != null) {
          // À l'arrêt/trop lent pour un cap GPS fiable : retombe sur la
          // dernière lecture de boussole connue.
          applyNewHeading(lastCompassHeading!, HeadingSource.compass);
        }
        emit();
      }));

      subscriptions.add(_compass.headingStream().listen((heading) {
        if (heading == null) return;
        lastCompassHeading = heading;
        // N'utilise la boussole que si on n'a pas déjà un cap GPS valide
        // en cours (évite qu'une lecture de boussole bruitée n'écrase un
        // cap de déplacement fiable pendant qu'on marche).
        if (headingSource != HeadingSource.gpsCourseOverGround) {
          applyNewHeading(heading, HeadingSource.compass);
          emit();
        }
      }));
      // Le flux IMU (`_motion`) sera intégré ici pour lisser l'estimation
      // entre deux mises à jour GPS/boussole (qui sont plus lentes/bruitées).
    };

    controller.onCancel = () async {
      for (final s in subscriptions) {
        await s.cancel();
      }
    };

    return controller.stream;
  }
}
