import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_theme.dart';
import '../../core/models/map_node.dart';
import '../../core/services/qr_waypoint_codec.dart';

/// Affiche, un par un, les QR codes correspondant aux points intérieurs
/// d'une carte tout juste envoyée au serveur — à imprimer et coller
/// physiquement à chaque endroit cartographié.
///
/// Scanner un de ces QR codes plus tard (voir `qr_scan_screen.dart`)
/// redonne une position exacte et instantanée, sans dérive — contrairement
/// à une ancre AR qui demanderait une relocalisation visuelle coûteuse
/// (Cloud Anchors). Voir le README pour la comparaison des deux approches.
class QrCodesScreen extends StatelessWidget {
  final String graphId;
  final List<MapNode> indoorNodes;

  const QrCodesScreen({
    super.key,
    required this.graphId,
    required this.indoorNodes,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR codes à imprimer')),
      body: indoorNodes.isEmpty
          ? const Center(child: Text('Aucun point intérieur dans cette carte.'))
          : PageView.builder(
              itemCount: indoorNodes.length,
              itemBuilder: (context, index) {
                final node = indoorNodes[index];
                final payload = QrWaypointCodec.encode(graphId, node.id);
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        node.label,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (node.floor != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Étage ${node.floor}',
                            style: PentamapTheme.readout(context),
                          ),
                        ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: PentamapColors.orange, width: 3),
                        ),
                        child: QrImageView(
                          data: payload,
                          size: 240,
                          version: QrVersions.auto,
                          eyeStyle: const QrEyeStyle(color: PentamapColors.ink),
                          dataModuleStyle:
                              const QrDataModuleStyle(color: PentamapColors.ink),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '${index + 1} / ${indoorNodes.length} — '
                        'glissez pour le suivant',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
