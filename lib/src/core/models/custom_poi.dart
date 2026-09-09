import 'package:flutter/material.dart';

/// Un point d'intérêt importé (voir `server/main.py`, endpoint
/// `/pois/import`), affiché en surcouche de la carte — pour compléter des
/// lieux absents ou incorrects sur OpenStreetMap, avec un style propre.
///
/// L'import et le parsing du GeoJSON se font entièrement côté serveur :
/// l'app ne fait que consommer le rendu déjà traité (`GET /pois`), jamais
/// de sélection/lecture de fichier ni de parsing elle-même.
///
/// Distinct des nœuds de navigation ([MapNode]) : un [CustomPoi] est juste
/// affiché sur la carte, il ne fait pas partie du graphe de chemins.
class CustomPoi {
  final String id;
  final String label;
  final double latitude;
  final double longitude;
  final Color color;

  const CustomPoi({
    required this.id,
    required this.label,
    required this.latitude,
    required this.longitude,
    this.color = const Color(0xFF7A5FBF), // violet — distinct du bleu/orange de la marque
  });

  /// Depuis la réponse de l'API (`GET /pois`/`POST /pois/import`) — la
  /// couleur y est une chaîne hexadécimale (ex: "#FF8800") ou absente.
  factory CustomPoi.fromApiJson(Map<String, dynamic> json) => CustomPoi(
        id: json['id'] as String,
        label: json['label'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        color: _parseHexColor(json['color'] as String?) ??
            const Color(0xFF7A5FBF),
      );

  /// Pour le cache local (`shared_preferences`) — la couleur y est stockée
  /// en entier ARGB, plus direct à round-tripper que du hexadécimal.
  factory CustomPoi.fromCacheJson(Map<String, dynamic> json) => CustomPoi(
        id: json['id'] as String,
        label: json['label'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        color: json['color'] != null
            ? Color(json['color'] as int)
            : const Color(0xFF7A5FBF),
      );

  Map<String, dynamic> toCacheJson() => {
        'id': id,
        'label': label,
        'latitude': latitude,
        'longitude': longitude,
        'color': color.toARGB32(),
      };

  static Color? _parseHexColor(String? hex) {
    if (hex == null) return null;
    var clean = hex.replaceFirst('#', '');
    if (clean.length == 6) clean = 'FF$clean'; // ajoute l'opacité si absente
    final value = int.tryParse(clean, radix: 16);
    return value != null ? Color(value) : null;
  }
}
