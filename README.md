# Pentamap

Application de navigation en réalité augmentée (Flutter). Guide l'utilisateur
pas à pas — en extérieur via GPS, en intérieur via des repères QR code —
avec des flèches directionnelles superposées au flux caméra.

## ✅ Ce qui fonctionne, testé sur device réel (Pixel 6 Pro, wifi)

**Navigation extérieure — bout en bout, fonctionnelle :**
- Écran d'accueil → **carte réelle** (serveur de tuiles OpenStreetMap
  standard, aucune clé API/compte) avec une épingle par repère cartographié
  → tap sur une
  épingle → choix "Naviguer jusqu'ici" ou, si le lieu a aussi été
  cartographié à l'intérieur, "Entrer et naviguer à l'intérieur" (réutilise
  le même graphe, le nœud tapé sert de départ indoor — pas besoin de
  scanner un QR si on vient d'y arriver par la navigation extérieure).
- Position de l'utilisateur affichée en direct sur la carte (point bleu).
- Position GPS courante injectée dans le graphe (`MapGraph.withVirtualStart`),
  calcul d'itinéraire par Dijkstra (`RouteCalculator`), avancement automatique
  d'étape en étape à l'approche de chaque point (`NavigationNotifier`).
- Flèche 3D (modèle `.glb` généré localement, pas de dépendance réseau/
  licence) qui **tourne en direct** vers le bon cap, avec une fusion
  GPS+boussole qui privilégie le cap de déplacement du GPS (plus fiable
  qu'un magnétomètre de téléphone) dès que l'utilisateur marche, et retombe
  sur la boussole à l'arrêt — lissage circulaire pour éviter que la flèche
  ne tremble (`SensorFusionService`, `GeoUtils.smoothAngleDegrees`).
- Bandeau d'état avec distance restante, direction ("Tournez à droite" etc.),
  indicateur de source de cap actif ("cap GPS"/"boussole"), écran d'arrivée,
  et gestion d'erreurs (permission refusée, GPS indisponible, itinéraire
  introuvable) avec retour à l'accueil.

**Navigation intérieure — QR codes + odométrie à pas :**
- Voir la section dédiée ci-dessous — c'est le résultat d'une recherche
  poussée sur les projets open source et papiers académiques du domaine
  (Google Maps, IndoorAtlas, Navigine, plusieurs projets GitHub Flutter+AR).

**Cartographie — fonctionnelle :**
- Capture de points GPS en extérieur, pose d'ancres AR en intérieur (tap sur
  une surface détectée, avec numéro d'étage saisi manuellement), chemin
  reconstitué automatiquement dans l'ordre du parcours.
- Le graphe est **persisté localement sur l'appareil** (`shared_preferences`)
  et rechargé automatiquement au démarrage. Export JSON (presse-papiers)
  disponible, et **envoi vers un serveur backend** (voir `server/`) pour
  partager une carte entre appareils.

## 🧭 Navigation intérieure : comment ça marche

### Le constat qui a guidé le choix technique

Après recherche (voir historique de conversation pour le détail des sources),
deux familles d'approches existent pour la navigation indoor :

| Approche | Précision | Coût de mise en place |
|---|---|---|
| **Cloud Anchors** (Google, relocalisation visuelle) | Bonne | Élevé : compte Google Cloud + backend (Firebase Firestore dans l'exemple officiel du plugin AR) |
| **QR codes** (repères physiques imprimés) | 1-2 m (études académiques) | Faible : juste imprimer et coller des QR codes, aucun compte externe requis |

On a choisi les **QR codes** comme fondation : c'est la méthode utilisée par
plusieurs projets académiques et open source
([tinhpv/indoor-navigation-system-qrcode-augmented-reality](https://github.com/tinhpv/indoor-navigation-system-qrcode-augmented-reality)),
et ça évite complètement la dépendance à un compte Google Cloud/Firebase que
Cloud Anchors nécessiterait. Rien n'empêche d'ajouter Cloud Anchors plus tard
en complément si besoin d'une couverture plus dense sans repères physiques.

### Le flux complet

1. **Cartographie** (`MappingRecorderScreen`) : l'opérateur pose une ancre AR
   à chaque point clé, avec un numéro d'étage (saisi manuellement — voir
   pourquoi ci-dessous), puis envoie la carte au serveur
   (`MapGraphApiClient.uploadGraph`).
2. **Génération des QR codes** (`QrCodesScreen`) : automatique juste après
   l'envoi — chaque point intérieur a son QR (`QrWaypointCodec`, format
   `pentamap://waypoint/<graphId>/<nodeId>`), à imprimer et coller
   physiquement à l'endroit correspondant.
3. **Navigation** : l'utilisateur scanne un QR (`QrScanScreen`, package
   `mobile_scanner`) pour obtenir une position de départ exacte, choisit une
   destination (`IndoorDestinationPickerScreen`), puis suit la flèche AR.
   La progression est estimée par **odométrie à pas** (PDR — Pedestrian Dead
   Reckoning, la méthode standard du domaine) : nombre de pas × longueur de
   foulée moyenne (`StepCounterService`, package `pedometer`).
4. **Recalage** : un bouton "scanner" toujours visible pendant la navigation
   indoor permet de rescanner un QR croisé en chemin pour corriger la dérive
   accumulée par le PDR (`NavigationNotifier.resyncToNode`) — exactement le
   principe validé par la littérature (précision ~0.64 m avec ce combo).

### Détection d'étage : pourquoi pas l'altitude GPS

L'altitude GPS a une erreur de ±10-30 m — bien plus que les ~3-4 m entre deux
étages, donc inexploitable. La vraie méthode (utilisée par Google Maps) est
la **pression atmosphérique relative** via le baromètre (`BarometerService`,
`sensors_plus` — déjà une dépendance du projet, zéro coût supplémentaire).
Actuellement utilisé uniquement comme **suggestion** pendant la cartographie
("avez-vous changé d'étage ?") — le numéro d'étage réel reste saisi
manuellement par l'opérateur, qui le connaît avec certitude à 100 %, ce
qu'aucun capteur ne peut garantir.

## ⚠️ Ce qui n'est PAS fait, et pourquoi

**Cloud Anchors (relocalisation visuelle AR)** — pas implémenté, au profit
des QR codes (voir ci-dessus). `ar_flutter_plugin_plus` les expose déjà
(`ARAnchorManager.initGoogleCloudAnchorMode()`, `.uploadAnchor()`,
`.downloadAnchor()`) si on veut les ajouter en complément plus tard — ça
reste un choix de service externe (compte Google Cloud) qui n'appartient
qu'à vous.

**Rendu du tracé ancré au sol** — la flèche agit comme une "boussole
flottante" (position fixe devant la caméra, orientation dynamique) plutôt
que d'être ancrée à un point précis du monde réel qui suivrait le tracé du
chemin au sol. Ancrer précisément nécessiterait de reprojeter le trajet dans
l'espace 3D de la session AR à chaque frame — un problème distinct, plus
avancé. En intérieur, faute de cap absolu fiable, la flèche ne tourne même
pas (seule la distance restante est indiquée) — amélioration possible avec
un filtre de fusion plus avancé (voir point suivant).

**Filtre de fusion de capteurs avancé** — la fusion GPS/boussole (extérieur)
utilise un lissage simple (moyenne circulaire), pas un vrai filtre de Kalman/
complementary filter intégrant le gyroscope. Le gyroscope (`MotionService`)
est câblé mais pas encore consommé. La littérature du domaine (voir
[Navigine/Indoor-Positioning-And-Navigation-Algorithms](https://github.com/Navigine/Indoor-Positioning-And-Navigation-Algorithms),
326 ⭐, référence du secteur) confirme que c'est l'étape naturelle suivante
pour améliorer la précision, en particulier indoor entre deux scans QR.

## Backend (`server/`)

API FastAPI (Python) minimale : stocke les graphes de carte (nœuds + arêtes,
extérieurs et intérieurs indifféremment) et sert de point de partage entre
appareils, en remplacement du copier-coller JSON manuel.

```bash
cd server
python3 -m venv .venv          # une seule fois
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8420
```

En développement, le téléphone accède au serveur qui tourne sur la machine
de dev via un tunnel adb (le serveur n'est pas sur le même réseau wifi que le
téléphone dans cet environnement) :

```bash
adb reverse tcp:8420 tcp:8420
```

Endpoints : `POST/GET /graphs`, `GET /graphs/{id}`, `DELETE /graphs/{id}`,
`POST /anchors`, `GET /anchors/nearby` (ce dernier prévu pour une future
recherche d'ancres Cloud par proximité si on ajoute cette approche en plus
des QR codes).

⚠️ Pour une utilisation réelle multi-appareils (pas juste du dev local), il
faudra déployer ce serveur quelque part de réellement joignable (VPS, cloud)
et changer `MapGraphApiClient.baseUrl` en conséquence.

## Design

Deux couleurs de marque, pas plus : **bleu** (`#3D6FE0`, extérieur/GPS) et
**orange** (`#E08A3C`, intérieur/repères) — chacune garde toujours le même
sens à l'œil. Typographie Space Grotesk (titres) + Inter (texte courant) +
JetBrains Mono (coordonnées/distances, effet "lecture d'instrument"), voir
`lib/src/app/app_theme.dart`. Le repère visuel (`PentamapMark`, pin +
aiguille) revient sur l'accueil, l'écran d'arrivée et le cadre des QR codes
comme fil visuel commun.

⚠️ Tuiles de carte : serveur **OpenStreetMap standard** (`tile.openstreetmap.
org`, via `flutter_map`), gratuit et sans clé/compte. CARTO Voyager avait été
essayé en premier (rendu plus soigné) mais exige désormais une clé API même
sur son offre gratuite — écarté pour rester cohérent avec le choix déjà fait
d'éviter les comptes externes. Le serveur OSM public a une politique d'usage
stricte pour les apps à fort trafic (voir leurs conditions) — à revoir avant
une mise en production réelle (tuiles auto-hébergées, clé CARTO gratuite
jusqu'à 5M requêtes/mois, ou un fournisseur payant).

## Structure du code

- `lib/src/app/` — `PentamapApp`, `HomeScreen`, `app_theme.dart` (palette +
  typo), `pentamap_mark.dart` (repère visuel).
- `lib/src/core/models/` — `MapNode` (avec `floor`)/`MapEdge`/`MapGraph`
  (graphe + Dijkstra + `withVirtualStart`).
- `lib/src/core/services/` — `LocationService`, `CompassService`,
  `MotionService`, `BarometerService`, `GeoUtils`, `MapGraphNotifier` (état
  partagé + persistance), `MapGraphApiClient` (backend), `QrWaypointCodec`.
- `lib/src/features/navigation/` — `RouteCalculator`, `SensorFusionService`,
  `StepCounterService`, `NavigationNotifier`, `DestinationPickerScreen`
  (extérieur), `IndoorDestinationPickerScreen`, `QrScanScreen`,
  `ServerGraphPickerScreen`.
- `lib/src/features/mapping/` — `MappingRecorderScreen`, `QrCodesScreen`.
- `lib/src/features/camera_ar/` — `ArNavigationScreen` (modes extérieur et
  intérieur).
- `assets/models/arrow.glb` — modèle 3D généré par script, format `.glb`
  binaire (le `.gltf`+base64 ne s'affichait pas correctement sur le
  chargeur natif Android — à retenir pour tout futur modèle).
- `server/` — backend FastAPI (voir section dédiée ci-dessus).

## Notes pratiques

1. `ar_flutter_plugin_plus` nécessite un appareil physique compatible ARKit
   (iOS) ou ARCore (Android) — pas de simulateur/émulateur pour la caméra AR.
2. Sur Android, ARCore doit être installé sur l'appareil de test (Play Store).
3. **Debug sans fil** : `flutter run` en tâche non-interactive se détache
   automatiquement juste après le lancement (`Lost connection to device.`) —
   normal (pas de stdin), l'app continue de tourner sur le téléphone. Pour
   garder le hot-reload actif, lancer `flutter run` dans un vrai terminal
   interactif plutôt qu'en arrière-plan.
4. Org Android/iOS : `com.propentatech.pentamap`.
5. Permission `ACTIVITY_RECOGNITION` (Android 10+) requise pour le podomètre
   — déjà ajoutée à `AndroidManifest.xml`.

## Lancer le projet

```bash
flutter pub get
flutter analyze   # vérifie que tout compile avant de lancer sur device
flutter run
```

## Architecture cible (rappel)

- **Cartographie** (une fois, par un opérateur) : parcourir l'établissement,
  enregistrer les repères GPS dehors et poser des ancres + QR codes dedans.
- **Navigation** (utilisateur final) : localisation (GPS dehors, scan QR
  dedans) → calcul d'itinéraire → suivi en continu (fusion GPS/boussole
  dehors, odométrie à pas dedans) → flèche superposée à l'image caméra.

Le point dur du projet reste la précision en conditions réelles (dérive du
PDR entre deux QR trop espacés, GPS en zone dense) — à ajuster avec des
tests sur site (densité des QR codes, calibration de la longueur de foulée).
# pentamap
