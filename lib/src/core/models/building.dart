/// Un bâtiment : simple repère géographique (lat/lon, pour l'afficher sur la
/// carte extérieure) qui pointe vers le nœud d'entrée à utiliser dans le
/// graphe unifié ([MapGraph]). Ce n'est PAS un graphe séparé — ses pièces
/// sont des [MapNode] normaux (kind == indoorAnchor) portant ce [id] comme
/// `buildingId`, reliées entre elles et au nœud d'entrée par des [MapEdge]
/// comme n'importe quel autre chemin.
class Building {
  final String id;
  final String graphId;
  final String name;
  final double latitude;
  final double longitude;
  final String? entranceNodeId;
  final String? description;

  const Building({
    required this.id,
    required this.graphId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.entranceNodeId,
    this.description,
  });

  factory Building.fromJson(Map<String, dynamic> json) => Building(
        id: json['id'] as String,
        graphId: json['graphId'] as String,
        name: json['name'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        entranceNodeId: json['entranceNodeId'] as String?,
        description: json['description'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        if (entranceNodeId != null) 'entranceNodeId': entranceNodeId,
        if (description != null) 'description': description,
      };
}
