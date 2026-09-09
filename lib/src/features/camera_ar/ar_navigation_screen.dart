import 'dart:async';
import 'dart:math';

import 'package:ar_flutter_plugin_plus/ar_flutter_plugin_plus.dart';
import 'package:ar_flutter_plugin_plus/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_plus/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_plus/models/ar_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../../app/app_theme.dart';
import '../../core/services/location_service.dart';
import '../../core/services/map_graph_store.dart';
import '../../core/services/step_counter_service.dart';
import '../navigation/navigation_controller.dart';
import '../navigation/qr_scan_screen.dart';
import '../navigation/sensor_fusion_service.dart';

/// Écran de navigation : affiche le flux caméra et guide vers
/// [destinationNodeId].
///
/// Deux modes, selon comment le point de départ est connu :
/// - **Extérieur** ([indoorStartNodeId] == null) : position de départ =
///   position GPS actuelle, orientation = fusion GPS + boussole.
/// - **Intérieur** ([indoorStartNodeId] fourni, typiquement après un scan de
///   QR code) : position de départ = ce nœud exact, avancement estimé par
///   odométrie à pas (nombre de pas × longueur de foulée) plutôt que GPS
///   (inutilisable en intérieur). Un bouton permet de rescanner un QR en
///   cours de route pour corriger la dérive accumulée.
///
/// ⚠️ En extérieur, la flèche agit comme une "boussole flottante" : position
/// fixe devant la caméra, qui **tourne** pour indiquer le cap. En intérieur,
/// faute de cap absolu fiable (voir le README sur les limites du repère
/// local des ancres AR), elle ne tourne pas : seule la distance restante est
/// indiquée. Ancrer précisément le tracé au sol dans les deux cas
/// nécessiterait de reprojeter le trajet dans l'espace 3D de la session AR
/// à chaque frame — hors scope de cette version.
class ArNavigationScreen extends ConsumerStatefulWidget {
  final String destinationNodeId;
  final String? indoorStartNodeId;

  const ArNavigationScreen({
    super.key,
    required this.destinationNodeId,
    this.indoorStartNodeId,
  });

  bool get isIndoor => indoorStartNodeId != null;

  @override
  ConsumerState<ArNavigationScreen> createState() => _ArNavigationScreenState();
}

class _ArNavigationScreenState extends ConsumerState<ArNavigationScreen> {
  static const _arrowModelAsset = 'assets/models/arrow.glb';

  final _locationService = LocationService();
  final _sensorFusion = SensorFusionService();
  final _stepCounter = StepCounterService();

  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARNode? _arrow;
  StreamSubscription<UserPose>? _poseSubscription;
  StreamSubscription<double>? _stepDistanceSubscription;
  double _lastStepDistance = 0;

  String _status = 'Initialisation de la session AR...';
  double? _lastHeadingDegrees;
  HeadingSource? _lastHeadingSource;
  bool _isLoadingRoute = true;
  bool _hasError = false;
  bool _hasArrived = false;

  @override
  void dispose() {
    _poseSubscription?.cancel();
    _stepDistanceSubscription?.cancel();
    _sessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Se reconstruit quand l'étape courante change (avancement automatique).
    ref.watch(navigationProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Navigation'),
        actions: [
          if (widget.isIndoor && !_hasArrived)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Rescanner un repère (corriger la position)',
              onPressed: _rescanToResync,
            ),
        ],
      ),
      body: Stack(
        children: [
          ARView(
            key: const ValueKey('nav_ar_view'),
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: PentamapColors.ink.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isLoadingRoute) ...[
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          _status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  if (_hasError || _hasArrived) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text("Retour à l'accueil"),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _sessionManager = sessionManager;
    _objectManager = objectManager;

    _sessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: false,
      showWorldOrigin: false,
      handleTaps: false,
    );
    // `onPlaneOrPointTap` est un champ `late` du plugin : le canal natif
    // l'appelle parfois même avec `handleTaps: false`, et plante avec un
    // LateInitializationError si rien n'est assigné. On ne navigue pas via
    // les taps ici, donc un handler vide suffit.
    _sessionManager!.onPlaneOrPointTap = (_) {};
    _objectManager!.onInitialize();

    _placeDirectionArrow();
    if (widget.isIndoor) {
      _startIndoorNavigation();
    } else {
      _startOutdoorNavigation();
    }
  }

  /// Place le modèle 3D de flèche (voir `assets/models/arrow.glb` — généré
  /// localement, pas de dépendance réseau ni de question de licence).
  Future<void> _placeDirectionArrow() async {
    final arrow = ARNode(
      type: NodeType.localGLB,
      uri: _arrowModelAsset,
      scale: Vector3(0.4, 0.4, 0.4),
      position: Vector3(0.0, 0.0, -1.0),
      rotation: Vector4(1.0, 0.0, 0.0, 0.0),
    );

    final added = await _objectManager?.addNode(arrow);
    if (!mounted) return;
    if (added ?? false) {
      _arrow = arrow;
    } else {
      _showError("Impossible d'afficher la flèche de direction.");
    }
  }

  // --- Mode extérieur (GPS + boussole) ---------------------------------

  Future<void> _startOutdoorNavigation() async {
    final graph = ref.read(mapGraphProvider);
    if (graph == null) {
      _showError('Aucune carte chargée.');
      return;
    }

    final hasPermission = await _locationService.ensurePermission();
    if (!mounted) return;
    if (!hasPermission) {
      _showError('Permission de localisation refusée.');
      return;
    }

    final Position position;
    try {
      position = await _locationService.getCurrentPosition();
    } catch (_) {
      _showError('Impossible de récupérer la position GPS. Activez le GPS et réessayez.');
      return;
    }
    if (!mounted) return;

    ref.read(navigationProvider.notifier).startRouteToDestination(
          graph,
          position.latitude,
          position.longitude,
          widget.destinationNodeId,
        );

    if (!_checkRouteFound()) return;

    setState(() {
      _isLoadingRoute = false;
      _status = 'Calcul de votre position en cours...';
    });
    _poseSubscription = _sensorFusion.poseStream().listen(_onOutdoorPoseUpdate);
  }

  void _onOutdoorPoseUpdate(UserPose pose) {
    if (!mounted) return;
    if (pose.headingDegrees != null) {
      _lastHeadingDegrees = pose.headingDegrees;
      _lastHeadingSource = pose.headingSource;
    }

    if (pose.latitude != null && pose.longitude != null) {
      ref.read(navigationProvider.notifier).updatePosition(
            pose.latitude!,
            pose.longitude!,
          );
    }

    if (_handleArrivalIfNeeded()) return;

    final step = ref.read(navigationProvider).currentStep;
    if (step == null) return;

    final distanceLabel = _formatDistance(step.distanceMeters);

    if (step.bearingDegrees != null && _lastHeadingDegrees != null) {
      final relativeBearing = _normalizeAngle(step.bearingDegrees! - _lastHeadingDegrees!);
      _rotateArrow(relativeBearing);
      setState(() => _status =
          '${_directionLabel(relativeBearing)} · $distanceLabel${_headingSourceSuffix()}');
    } else {
      setState(() => _status = 'Continuez · $distanceLabel');
    }
  }

  // --- Mode intérieur (départ connu via QR + odométrie à pas) ----------

  void _startIndoorNavigation() {
    final graph = ref.read(mapGraphProvider);
    if (graph == null) {
      _showError('Aucune carte chargée.');
      return;
    }

    ref.read(navigationProvider.notifier).startRoute(
          graph,
          widget.indoorStartNodeId!,
          widget.destinationNodeId,
        );

    if (!_checkRouteFound()) return;

    setState(() {
      _isLoadingRoute = false;
      _status = 'Continuez tout droit';
    });
    _stepDistanceSubscription =
        _stepCounter.distanceStream().listen(_onIndoorDistanceUpdate);
  }

  void _onIndoorDistanceUpdate(double totalDistanceSinceStart) {
    if (!mounted) return;
    // Le flux donne une distance cumulée depuis l'abonnement ; on ne
    // transmet au notifier que le delta depuis la dernière mesure.
    final delta = totalDistanceSinceStart - _lastStepDistance;
    _lastStepDistance = totalDistanceSinceStart;
    if (delta <= 0) return;

    ref.read(navigationProvider.notifier).advanceByDistance(delta);

    if (_handleArrivalIfNeeded()) return;

    final step = ref.read(navigationProvider).currentStep;
    if (step == null) return;
    setState(() => _status = 'Continuez tout droit · ${_formatDistance(step.distanceMeters)}');
  }

  /// Ouvre le scanner pour rescanner un QR code en cours de route et
  /// recaler la position — corrige la dérive de l'odométrie à pas.
  Future<void> _rescanToResync() async {
    final result = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;
    final (_, nodeId) = result;
    ref.read(navigationProvider.notifier).resyncToNode(nodeId);
    _lastStepDistance = 0;
    _stepDistanceSubscription?.cancel();
    _stepDistanceSubscription =
        _stepCounter.distanceStream().listen(_onIndoorDistanceUpdate);
    if (!_checkRouteFound()) return;
    setState(() {
      _hasArrived = false;
      _status = 'Position recalée · Continuez tout droit';
    });
  }

  // --- Commun -------------------------------------------------------

  bool _checkRouteFound() {
    if (ref.read(navigationProvider).steps.isEmpty) {
      _showError('Aucun itinéraire trouvé vers cette destination.');
      return false;
    }
    return true;
  }

  /// Retourne `true` (et met à jour l'état "arrivé") si la navigation vient
  /// de se terminer — à appeler après chaque mise à jour de position.
  bool _handleArrivalIfNeeded() {
    if (!ref.read(navigationProvider).isArrived) return false;
    _poseSubscription?.cancel();
    _stepDistanceSubscription?.cancel();
    setState(() {
      _hasArrived = true;
      _status = '🎉 Vous êtes arrivé !';
    });
    return true;
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _isLoadingRoute = false;
      _hasError = true;
      _status = message;
    });
  }

  String _formatDistance(double meters) {
    return meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(1)} km'
        : '${meters.round()} m';
  }

  /// Petit indicateur ("cap GPS" vs "boussole") pour juger sur le terrain de
  /// quelle source de cap est active — utile en phase de test/réglage.
  String _headingSourceSuffix() {
    switch (_lastHeadingSource) {
      case HeadingSource.gpsCourseOverGround:
        return ' (cap GPS)';
      case HeadingSource.compass:
        return ' (boussole)';
      case null:
        return '';
    }
  }

  /// Tourne la flèche autour de son axe vertical pour qu'elle pointe vers
  /// [relativeBearingDegrees] (0 = tout droit, positif = à droite).
  ///
  /// ⚠️ Le sens de rotation (horaire/antihoraire) par rapport à ce signe n'a
  /// pas pu être vérifié sans test sur device réel. Si la flèche tourne à
  /// l'envers par rapport à la direction annoncée dans le bandeau de texte,
  /// inverser le signe ci-dessous (`-relativeBearingDegrees`).
  void _rotateArrow(double relativeBearingDegrees) {
    final yawRadians = relativeBearingDegrees * pi / 180;
    _arrow?.eulerAngles = Vector3(0, yawRadians, 0);
  }

  String _directionLabel(double relativeBearingDegrees) {
    if (relativeBearingDegrees.abs() < 20) return 'Continuez tout droit';
    if (relativeBearingDegrees > 0) return 'Tournez à droite';
    return 'Tournez à gauche';
  }

  double _normalizeAngle(double angle) {
    var a = angle % 360;
    if (a > 180) a -= 360;
    if (a < -180) a += 360;
    return a;
  }
}
