import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/map_graph.dart';

/// Résumé d'un graphe stocké côté serveur (sans le détail nœuds/arêtes),
/// utilisé pour lister les cartes disponibles.
class GraphSummary {
  final String id;
  final String name;
  final int nodeCount;

  const GraphSummary({
    required this.id,
    required this.name,
    required this.nodeCount,
  });

  factory GraphSummary.fromJson(Map<String, dynamic> json) => GraphSummary(
        id: json['id'] as String,
        name: json['name'] as String,
        nodeCount: json['node_count'] as int,
      );
}

/// Client HTTP pour le backend Pentamap (voir `server/main.py`) : stocke et
/// récupère les graphes de carte (chemins extérieurs + ancres intérieures)
/// sur un serveur partagé, au lieu de dépendre uniquement du presse-papiers
/// ou du stockage local à l'appareil.
///
/// ⚠️ [baseUrl] pointe par défaut sur `localhost` : pendant le développement,
/// le téléphone y accède via un tunnel `adb reverse tcp:8420 tcp:8420` vers
/// la machine qui fait tourner le serveur (voir README du dossier
/// `server/`). En production, il faudrait déployer ce serveur quelque part
/// de réellement joignable par les téléphones (serveur cloud, VPS...) et
/// changer cette URL en conséquence.
class MapGraphApiClient {
  final String baseUrl;
  final http.Client _client;

  MapGraphApiClient({
    this.baseUrl = 'http://localhost:8420',
    http.Client? client,
  }) : _client = client ?? http.Client();

  Future<GraphSummary> uploadGraph(String name, MapGraph graph) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/graphs'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'nodes': graph.toJson()['nodes'],
        'edges': graph.toJson()['edges'],
      }),
    );
    _checkOk(response, 'upload du graphe');
    return GraphSummary.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<GraphSummary>> listGraphs() async {
    final response = await _client.get(Uri.parse('$baseUrl/graphs'));
    _checkOk(response, 'liste des cartes');
    final list = jsonDecode(response.body) as List;
    return list
        .map((e) => GraphSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MapGraph> downloadGraph(String graphId) async {
    final response = await _client.get(Uri.parse('$baseUrl/graphs/$graphId'));
    _checkOk(response, 'téléchargement du graphe');
    return MapGraph.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  void _checkOk(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MapGraphApiException(
        'Échec ($action) : HTTP ${response.statusCode} — ${response.body}',
      );
    }
  }

  void dispose() => _client.close();
}

class MapGraphApiException implements Exception {
  final String message;
  const MapGraphApiException(this.message);

  @override
  String toString() => message;
}
