import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/building.dart';
import '../models/map_edge.dart';
import '../models/map_graph.dart';
import '../models/map_node.dart';

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

/// Client HTTP pour le backend Pentamap (voir `server/main.py`) : graphe de
/// navigation unifié (bâtiments, points, liaisons) partagé entre l'app et
/// les deux interfaces d'administration (web + app).
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

  Future<GraphSummary> createGraph(String name) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/graphs'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    );
    _checkOk(response, 'création du site');
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

  Future<void> deleteGraph(String graphId) async {
    final response = await _client.delete(Uri.parse('$baseUrl/graphs/$graphId'));
    _checkOk(response, 'suppression du site');
  }

  // -- Nœuds -----------------------------------------------------------

  Future<MapNode> createNode(String graphId, MapNode node) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/graphs/$graphId/nodes'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(node.toJson()..remove('id')),
    );
    _checkOk(response, 'création du point');
    return MapNode.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<MapNode> updateNode(String graphId, MapNode node) async {
    final response = await _client.put(
      Uri.parse('$baseUrl/graphs/$graphId/nodes/${node.id}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(node.toJson()..remove('id')),
    );
    _checkOk(response, 'modification du point');
    return MapNode.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteNode(String graphId, String nodeId) async {
    final response =
        await _client.delete(Uri.parse('$baseUrl/graphs/$graphId/nodes/$nodeId'));
    _checkOk(response, 'suppression du point');
  }

  /// Ajoute un lot de nœuds + arêtes d'un coup (append, ne remplace rien) —
  /// utilisé par la cartographie physique par ancres AR.
  Future<MapGraph> bulkAddNodes(String graphId, List<MapNode> nodes, List<MapEdge> edges) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/graphs/$graphId/nodes/bulk'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
      }),
    );
    _checkOk(response, 'envoi de la cartographie');
    return MapGraph.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // -- Arêtes ------------------------------------------------------------

  Future<MapEdge> createEdge(String graphId, MapEdge edge) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/graphs/$graphId/edges'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(edge.toJson()..remove('id')),
    );
    _checkOk(response, 'création de la liaison');
    return MapEdge.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteEdge(String graphId, String edgeId) async {
    final response =
        await _client.delete(Uri.parse('$baseUrl/graphs/$graphId/edges/$edgeId'));
    _checkOk(response, 'suppression de la liaison');
  }

  // -- Bâtiments -----------------------------------------------------------

  Future<Building> createBuilding(String graphId, Building building) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/graphs/$graphId/buildings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(building.toJson()),
    );
    _checkOk(response, 'création du bâtiment');
    return Building.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<Building> updateBuilding(String graphId, Building building) async {
    final response = await _client.put(
      Uri.parse('$baseUrl/graphs/$graphId/buildings/${building.id}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(building.toJson()),
    );
    _checkOk(response, 'modification du bâtiment');
    return Building.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteBuilding(String graphId, String buildingId) async {
    final response = await _client
        .delete(Uri.parse('$baseUrl/graphs/$graphId/buildings/$buildingId'));
    _checkOk(response, 'suppression du bâtiment');
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
