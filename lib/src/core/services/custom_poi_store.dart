import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/custom_poi.dart';
import 'custom_poi_api_client.dart';

const _prefsKey = 'pentamap_custom_pois_cache_json';

/// Points d'intérêt importés (voir `custom_poi.dart`), affichés en surcouche
/// de la carte extérieure.
///
/// Le serveur (`server/main.py`, `/pois`) est la source de vérité — l'import
/// et le parsing du GeoJSON se font entièrement côté backend, jamais dans
/// l'app. [loadPersisted] ne sert qu'à afficher immédiatement un cache
/// local au démarrage (avant que la requête réseau vers `/pois` n'ait
/// répondu, ou hors ligne) ; [refreshFromServer] est la vraie source.
class CustomPoiNotifier extends Notifier<List<CustomPoi>> {
  final _apiClient = CustomPoiApiClient();

  @override
  List<CustomPoi> build() => const [];

  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_prefsKey);
    if (jsonString == null) return;
    try {
      final list = jsonDecode(jsonString) as List;
      state = list
          .map((e) => CustomPoi.fromCacheJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      await prefs.remove(_prefsKey);
    }
  }

  /// Récupère la liste à jour depuis le serveur et la met en cache local.
  /// Lève une exception réseau si le serveur est injoignable — à charge de
  /// l'appelant de l'attraper et de garder l'affichage du cache existant.
  Future<void> refreshFromServer() async {
    final pois = await _apiClient.listPois();
    state = pois;
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(state.map((p) => p.toCacheJson()).toList()),
    );
  }
}

final customPoiProvider = NotifierProvider<CustomPoiNotifier, List<CustomPoi>>(
  CustomPoiNotifier.new,
);
