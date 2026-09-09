/// Encode/décode le contenu des QR codes utilisés comme repères de
/// position intérieure.
///
/// Chaque QR code physique, imprimé et collé à un point cartographié,
/// encode simplement `pentamap://waypoint/<graphId>/<nodeId>` — un lien
/// direct vers "quel nœud de quel graphe est-ce que je viens de scanner".
/// Scanner ce QR code donne une position exacte et instantanée (précision
/// centimétrique, pas de dérive), contrairement à une ancre AR qui
/// nécessite une relocalisation visuelle coûteuse (Cloud Anchors) — voir le
/// README pour la comparaison des deux approches.
class QrWaypointCodec {
  const QrWaypointCodec._();

  static const _scheme = 'pentamap://waypoint/';

  static String encode(String graphId, String nodeId) =>
      '$_scheme$graphId/$nodeId';

  /// Retourne (graphId, nodeId), ou `null` si [payload] n'est pas un QR
  /// Pentamap valide.
  static (String, String)? decode(String payload) {
    if (!payload.startsWith(_scheme)) return null;
    final rest = payload.substring(_scheme.length);
    final parts = rest.split('/');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return (parts[0], parts[1]);
  }
}
