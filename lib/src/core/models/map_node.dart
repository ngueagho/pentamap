/// Un nœud du graphe de carte : soit un repère GPS extérieur,
/// soit une ancre visuelle intérieure (issue du SLAM AR).
class MapNode {
  final String id;
  final String label;
  final NodeKind kind;

  /// Renseigné si [kind] == outdoorGps.
  final double? latitude;
  final double? longitude;
  final double? altitude;

  /// Renseigné si [kind] == indoorAnchor : identifiant de l'ancre
  /// persistante (ex: ARCore Cloud Anchor ID, ou ARWorldMap anchor name).
  final String? anchorId;

  /// Position relative dans le repère 3D de la session AR d'origine
  /// (utile pour le calcul de trajet indoor avant relocalisation).
  final double? localX;
  final double? localY;
  final double? localZ;

  /// Numéro d'étage (uniquement pertinent pour [kind] == indoorAnchor).
  /// Saisi manuellement par l'opérateur pendant la cartographie — voir
  /// `core/services/barometer_service.dart` pour pourquoi ce n'est pas
  /// déduit automatiquement d'un capteur (GPS trop imprécis en altitude ;
  /// seul le baromètre est fiable, et seulement en relatif, pas en absolu).
  final int? floor;

  /// Bâtiment auquel appartient ce nœud (uniquement pertinent pour
  /// [kind] == indoorAnchor). `null` = nœud extérieur (chemin/repère public).
  /// C'est ce qui permet à un même graphe unique de représenter plusieurs
  /// bâtiments : le trajet entre deux nœuds de `buildingId` différents passe
  /// naturellement par les nœuds extérieurs qui les relient (calculé par
  /// Dijkstra sans notion de "mode" — voir `MapGraph.shortestPath`).
  final String? buildingId;

  const MapNode({
    required this.id,
    required this.label,
    required this.kind,
    this.latitude,
    this.longitude,
    this.altitude,
    this.anchorId,
    this.localX,
    this.localY,
    this.localZ,
    this.floor,
    this.buildingId,
  });

  factory MapNode.fromJson(Map<String, dynamic> json) => MapNode(
        id: json['id'] as String,
        label: json['label'] as String,
        kind: NodeKind.values.byName(json['kind'] as String),
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        altitude: (json['altitude'] as num?)?.toDouble(),
        anchorId: json['anchorId'] as String?,
        localX: (json['localX'] as num?)?.toDouble(),
        localY: (json['localY'] as num?)?.toDouble(),
        localZ: (json['localZ'] as num?)?.toDouble(),
        floor: (json['floor'] as num?)?.toInt(),
        buildingId: json['buildingId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'kind': kind.name,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (altitude != null) 'altitude': altitude,
        if (anchorId != null) 'anchorId': anchorId,
        if (localX != null) 'localX': localX,
        if (localY != null) 'localY': localY,
        if (localZ != null) 'localZ': localZ,
        if (floor != null) 'floor': floor,
        if (buildingId != null) 'buildingId': buildingId,
      };

  MapNode copyWith({String? label, int? floor, String? buildingId}) => MapNode(
        id: id,
        label: label ?? this.label,
        kind: kind,
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        anchorId: anchorId,
        localX: localX,
        localY: localY,
        localZ: localZ,
        floor: floor ?? this.floor,
        buildingId: buildingId ?? this.buildingId,
      );
}

enum NodeKind { outdoorGps, indoorAnchor }
