import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/map_graph.dart';
import 'map_graph_api_client.dart';

const _prefsKey = 'pentamap_map_graph_json';

/// Nom du site créé automatiquement s'il n'en existe encore aucun côté
/// serveur — l'app a toujours besoin d'un graphe actif pour fonctionner
/// (carte unifiée, sans notion de "carte sélectionnée" manuellement).
const _defaultGraphName = 'Site principal';

/// Détient le graphe de carte actuellement chargé, partagé entre l'écran de
/// cartographie (qui le remplit au fur et à mesure) et l'écran de
/// navigation (qui le consulte pour proposer des destinations).
///
/// Persisté localement sur l'appareil (`shared_preferences`) à chaque
/// modification, et rechargé automatiquement au démarrage de l'app — les
/// points cartographiés survivent donc à un redémarrage. Reste local à
/// l'appareil : pour partager une carte entre plusieurs téléphones, il faut
/// toujours passer par l'export/import JSON (presse-papiers), en attendant
/// un vrai backend.
class MapGraphNotifier extends Notifier<MapGraph?> {
  @override
  MapGraph? build() => null;

  /// À appeler une fois au démarrage de l'app pour recharger la dernière
  /// carte sauvegardée localement, s'il y en a une.
  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_prefsKey);
    if (jsonString == null) return;
    try {
      state = MapGraph.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
    } catch (_) {
      // Sauvegarde corrompue/format obsolète : on l'ignore plutôt que de
      // planter au démarrage.
      await prefs.remove(_prefsKey);
    }
  }

  void setGraph(MapGraph graph) {
    state = graph;
    _persist(graph);
  }

  /// Récupère le graphe actif depuis le serveur (le plus récemment modifié),
  /// ou en crée un vide s'il n'en existe encore aucun — c'est LE site géré
  /// par cette installation de Pentamap, il n'y a jamais besoin d'en choisir
  /// un manuellement. Source de vérité : le serveur (voir README backend).
  Future<MapGraph> refreshFromServer(MapGraphApiClient apiClient) async {
    final summaries = await apiClient.listGraphs();
    final String graphId;
    if (summaries.isEmpty) {
      graphId = (await apiClient.createGraph(_defaultGraphName)).id;
    } else {
      graphId = summaries.first.id;
    }
    final graph = await apiClient.downloadGraph(graphId);
    state = graph;
    _persist(graph);
    return graph;
  }

  /// Charge un graphe depuis une chaîne JSON (typiquement collée depuis le
  /// presse-papiers, exportée précédemment par l'écran de cartographie).
  /// Lève une exception si le JSON est invalide — à charge de l'appelant de
  /// l'attraper et d'informer l'utilisateur.
  void loadFromJson(String jsonString) {
    final graph = MapGraph.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
    state = graph;
    _persist(graph);
  }

  Future<void> clear() async {
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  Future<void> _persist(MapGraph graph) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(graph.toJson()));
  }
}

final mapGraphProvider = NotifierProvider<MapGraphNotifier, MapGraph?>(
  MapGraphNotifier.new,
);
