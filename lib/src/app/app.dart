import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/map_node.dart';
import '../core/services/custom_poi_store.dart';
import '../core/services/map_graph_store.dart';
import '../features/admin/admin_screen.dart';
import '../features/mapping/mapping_recorder_screen.dart';
import '../features/navigation/destination_picker_screen.dart';
import 'app_theme.dart';
import 'pentamap_mark.dart';

class PentamapApp extends StatelessWidget {
  const PentamapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pentamap',
      debugShowCheckedModeBanner: false,
      theme: PentamapTheme.light(),
      home: const HomeScreen(),
    );
  }
}

/// Écran d'accueil : une seule entrée vers la carte — pas de choix
/// "extérieur"/"intérieur" à faire, la carte gère elle-même la transition
/// (voir `DestinationPickerScreen`). "Cartographier" et "Administrer" sont
/// des outils d'opérateur/gestionnaire, volontairement en retrait.
///
/// Recharge la carte sauvegardée localement au démarrage (voir
/// `map_graph_store.dart`) — les points cartographiés survivent donc à un
/// redémarrage de l'app.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(mapGraphProvider.notifier).loadPersisted());
    Future.microtask(() => ref.read(customPoiProvider.notifier).loadPersisted());
  }

  @override
  Widget build(BuildContext context) {
    final graph = ref.watch(mapGraphProvider);
    final outdoorCount =
        graph?.nodes.values.where((n) => n.kind == NodeKind.outdoorGps).length ?? 0;
    final indoorCount =
        graph?.nodes.values.where((n) => n.kind == NodeKind.indoorAnchor).length ?? 0;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const PentamapMark(size: 36),
                  const SizedBox(width: 12),
                  Text('Pentamap', style: Theme.of(context).textTheme.headlineSmall),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Text(
                  graph == null
                      ? 'Aucune carte chargée'
                      : '$outdoorCount repère(s) extérieur(s) · $indoorCount ancre(s) intérieure(s)',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: PentamapColors.ink.withValues(alpha: 0.55)),
                ),
              ),
              const SizedBox(height: 28),
              _ModeCard(
                color: PentamapColors.blue,
                icon: Icons.map_outlined,
                title: 'Explorer la carte',
                subtitle: 'Cherchez une destination, dehors ou dans un bâtiment',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DestinationPickerScreen()),
                ),
              ),
              const Spacer(),
              Center(
                child: Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.admin_panel_settings_outlined, size: 18),
                      label: const Text('Administrer'),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const AdminScreen()),
                        );
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.threed_rotation, size: 18),
                      label: const Text('Cartographier (AR)'),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const MappingRecorderScreen()),
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (graph != null)
                Center(
                  child: TextButton(
                    onPressed: () async {
                      await ref.read(mapGraphProvider.notifier).clear();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: PentamapColors.ink.withValues(alpha: 0.4),
                    ),
                    child: const Text('Effacer la carte enregistrée'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Une des deux entrées principales de l'accueil (extérieur/intérieur) —
/// une grande zone tapable plutôt qu'un bouton texte, pour que le choix de
/// mode soit la première décision visible en ouvrant l'app.
class _ModeCard extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: PentamapColors.ink.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: PentamapColors.ink.withValues(alpha: 0.3)),
            ],
          ),
        ),
      ),
    );
  }
}
