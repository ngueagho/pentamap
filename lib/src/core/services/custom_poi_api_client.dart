import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/custom_poi.dart';

/// Client HTTP pour les points d'intérêt importés (voir `server/main.py`).
/// Le serveur fait tout le travail — import, parsing du GeoJSON — l'app ne
/// fait que récupérer le résultat déjà traité pour l'afficher.
class CustomPoiApiClient {
  final String baseUrl;
  final http.Client _client;

  CustomPoiApiClient({
    this.baseUrl = 'http://localhost:8420',
    http.Client? client,
  }) : _client = client ?? http.Client();

  Future<List<CustomPoi>> listPois() async {
    final response = await _client.get(Uri.parse('$baseUrl/pois'));
    _checkOk(response, 'liste des points');
    final list = jsonDecode(response.body) as List;
    return list
        .map((e) => CustomPoi.fromApiJson(e as Map<String, dynamic>))
        .toList();
  }

  void _checkOk(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CustomPoiApiException(
        'Échec ($action) : HTTP ${response.statusCode} — ${response.body}',
      );
    }
  }

  void dispose() => _client.close();
}

class CustomPoiApiException implements Exception {
  final String message;
  const CustomPoiApiException(this.message);

  @override
  String toString() => message;
}
