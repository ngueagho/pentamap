# Pentamap

Application de navigation en réalité augmentée (Flutter), multi-bâtiments.
Une **seule carte** guide l'utilisateur d'un point A à un point B qu'ils
soient dans le même bâtiment, dans des bâtiments différents, ou en pleine
rue — sans qu'il ait jamais à choisir un "mode" extérieur/intérieur.

## Le modèle : un graphe unique, des bâtiments comme simples repères

Tout le site (campus, établissement) est **un seul graphe** de nœuds
(pièces, intersections, repères GPS) reliés par des arêtes pondérées par une
distance en mètres. Un `Building` n'est **pas** un graphe séparé : c'est un
repère géographique (latitude/longitude, pour l'afficher sur la carte) qui
pointe vers un nœud d'entrée de ce même graphe. Résultat : le trajet "salle
204 du bâtiment A → sortie → rue → entrée du bâtiment B → accueil du
bâtiment B" se calcule **en un seul Dijkstra** (`MapGraph.shortestPath`),
exactement comme n'importe quel autre trajet — il n'y a aucune notion de
mode à gérer séparément.

Côté app, une seule source de suivi ne suffit pas sur tout le trajet (GPS
dehors, odométrie à pas dedans) : les deux tournent en permanence, et c'est
le type du nœud visé par l'étape courante qui détermine laquelle fait
autorité (voir `NavigationNotifier.advanceByDistance`) — la transition est
donc automatique, jamais un bouton à presser.

## ✅ Ce qui fonctionne, testé sur device réel (Pixel 6 Pro, wifi)

**Navigation — un seul écran, bout en bout :**
- Écran d'accueil → **carte vectorielle** (MapLibre GL + tuiles OpenFreeMap,
  gratuit, aucune clé API/compte) avec un style recoloré aux couleurs de
  marque. Épingle **bleue** = point extérieur, épingle **orange** (plus
  grande) = bâtiment.
- Tap sur un point extérieur → "Naviguer jusqu'ici". Tap sur un bâtiment →
  liste ses pièces par étage → en choisir une lance directement la
  navigation, où qu'on soit sur le site.
- Recherche (icône loupe) : toutes les destinations (points + pièces de tous
  les bâtiments) filtrables par nom, pour taper "salle 101" sans chercher le
  bâtiment sur la carte.
- Scanner un QR (icône dédiée) : pour repartir d'un point précis déjà connu
  plutôt que du GPS actuel (plus fiable en intérieur) — aussi utilisable en
  cours de route pour corriger la dérive de l'odométrie à pas.
- La carte se synchronise automatiquement au démarrage avec le site actif
  côté serveur (créé automatiquement s'il n'en existe encore aucun) — plus
  besoin de sélectionner manuellement une carte à charger.
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
  indicateur de source de cap actif ("cap GPS"/"boussole"), suggestion de
  scan QR à l'entrée d'un bâtiment, écran d'arrivée, et gestion d'erreurs
  (permission refusée, GPS indisponible, itinéraire introuvable) avec retour
  à l'accueil.

**Navigation intérieure — QR codes + odométrie à pas :**
- Voir la section dédiée ci-dessous — c'est le résultat d'une recherche
  poussée sur les projets open source et papiers académiques du domaine
  (Google Maps, IndoorAtlas, Navigine, plusieurs projets GitHub Flutter+AR).

**Administration — deux interfaces, mêmes données :**
- **Dashboard web** (`server/admin/`, servi par le backend lui-même à
  `/admin`) : carte Leaflet pour placer les bâtiments à la souris, gérer
  leurs pièces par étage, leurs liaisons, leur nœud d'entrée. Pensé pour une
  utilisation "de bureau" par le client final, sans installer l'app.
- **Écran "Administrer" dans l'app** (`AdminScreen`) : mêmes opérations
  (bâtiments, points extérieurs, liaisons), pour un gestionnaire qui préfère
  rester sur mobile.
- Les deux pilotent la même API granulaire (créer/modifier/supprimer un
  nœud, une arête, un bâtiment un par un) — pas de "tout renvoyer d'un coup"
  comme avant.

**Cartographie physique (optionnelle, plus précise) — AR :**
- Capture de points GPS en extérieur, pose d'ancres AR en intérieur (tap sur
  une surface détectée, avec bâtiment et numéro d'étage sélectionnés),
  chemin reconstitué automatiquement dans l'ordre du parcours. Complémentaire
  du graphe abstrait de l'administration : utile quand la précision d'une
  vraie ancre visuelle compte plus que la rapidité de saisie.
- Le graphe est **persisté localement sur l'appareil** (`shared_preferences`)
  et rechargé automatiquement au démarrage. Export JSON (presse-papiers)
  disponible, et **envoi vers le serveur backend** (voir `server/`) en lot,
  append seulement — jamais de remplacement destructeur des autres
  bâtiments déjà sur le site.

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

1. **Cartographie** : soit via le graphe abstrait de l'administration (web
   ou app — nom de la pièce, étage, liaisons avec distance saisie ou
   calculée), soit physiquement via `MappingRecorderScreen` — l'opérateur
   pose une ancre AR à chaque point clé, avec le bâtiment et l'étage
   (suggéré par le baromètre, voir ci-dessous), puis envoie le lot au
   serveur (`MapGraphApiClient.bulkAddNodes`, en complément des données déjà
   présentes — jamais un remplacement total).
2. **Génération des QR codes** (`QrCodesScreen`) : automatique juste après
   l'envoi côté cartographie AR — chaque point intérieur a son QR
   (`QrWaypointCodec`, format `pentamap://waypoint/<graphId>/<nodeId>`), à
   imprimer et coller physiquement à l'endroit correspondant.
3. **Navigation** : l'utilisateur choisit une destination sur la carte
   unifiée (`DestinationPickerScreen` — tap sur un bâtiment, ou recherche),
   le trajet est calculé d'un coup depuis sa position GPS actuelle jusqu'à
   la pièce visée, même si ça traverse plusieurs bâtiments. Le suivi bascule
   automatiquement du GPS+boussole (étapes extérieures) à l'**odométrie à
   pas** (PDR — Pedestrian Dead Reckoning : nombre de pas × longueur de
   foulée moyenne, `StepCounterService`) dès que l'étape courante vise une
   pièce (voir `NavigationNotifier.advanceByDistance`). En arrivant à
   l'entrée d'un bâtiment, l'app suggère de scanner le QR collé là pour
   caler précisément le PDR qui prend le relais.
4. **Recalage** : le bouton "scanner" (toujours visible pendant la
   navigation) permet de rescanner un QR croisé en chemin pour corriger la
   dérive accumulée par le PDR (`NavigationNotifier.resyncToNode`) — exactement
   le principe validé par la littérature (précision ~0.64 m avec ce combo).

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

API FastAPI (Python) + SQLite : stocke le graphe unifié (nœuds, arêtes,
bâtiments — tables normalisées, pas un blob JSON) et sert de point de
partage entre l'app et les deux interfaces d'administration.

```bash
cd server
python3 -m venv .venv          # une seule fois
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8420
```

Dashboard admin web : http://localhost:8420/admin/ (servi statiquement par
ce même processus, voir `server/admin/index.html`).

En développement, le téléphone accède au serveur qui tourne sur la machine
de dev via un tunnel adb (le serveur n'est pas sur le même réseau wifi que le
téléphone dans cet environnement) :

```bash
adb reverse tcp:8420 tcp:8420
```

Endpoints principaux :
- Sites : `POST/GET /graphs`, `GET/DELETE /graphs/{id}`.
- Nœuds : `POST /graphs/{id}/nodes`, `PUT/DELETE /graphs/{id}/nodes/{node_id}`,
  `POST /graphs/{id}/nodes/bulk` (ajout en lot, utilisé par la cartographie AR).
- Arêtes : `POST /graphs/{id}/edges`, `DELETE /graphs/{id}/edges/{edge_id}`.
- Bâtiments : `POST /graphs/{id}/buildings`,
  `PUT/DELETE /graphs/{id}/buildings/{building_id}`.
- `POST /anchors`, `GET /anchors/nearby` (prévu pour une future recherche
  d'ancres Cloud par proximité si on ajoute cette approche en plus des QR
  codes), `POST /pois/import`, `GET /pois`, `DELETE /pois/{id}`.

Une base existante créée avant cette normalisation (ancienne colonne
`graph_json`) est migrée automatiquement au démarrage
(`_migrate_legacy_blob_graphs`) — aucune donnée perdue.

**Import de points d'intérêt personnalisés** — plutôt que de scraper des
services tiers (refusé, contraire à leurs CGU), l'opérateur importe ses
propres données (fichier GeoJSON) directement **côté serveur**
(`POST /pois/import`) : le parsing et le géocodage restent sur le backend,
le client ne fait que consommer le rendu déjà prêt via `GET /pois` — voir
`server/main.py` et `lib/src/core/models/custom_poi.dart`.

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

⚠️ Tuiles de carte : **tuiles vectorielles OpenFreeMap** (`tiles.openfreemap.
org`, style de base "positron"), rendues par `maplibre_gl` — gratuit, sans
clé/compte, sans limite de requêtes (contrairement à `tile.openstreetmap.org`
utilisé avant, qui a une politique d'usage stricte pour les apps à fort
trafic, ou CARTO Voyager qui exige désormais une clé API). Le style est
recoloré aux couleurs de marque (`assets/map_style.json`, généré par un
script Python à partir du style "positron" — routes, bâtiments, eau, parcs et
libellés retouchés) et son attribution embarquée (source `openmaptiles`)
inclut OpenStreetMap, OpenMapTiles et `www.propentatech.com`, affichée via le
bouton "i" natif de MapLibre.

## Structure du code

- `lib/src/app/` — `PentamapApp`, `HomeScreen` (une seule entrée : "Explorer
  la carte"), `app_theme.dart` (palette + typo), `pentamap_mark.dart`
  (repère visuel).
- `lib/src/core/models/` — `MapNode` (avec `floor`/`buildingId`)/`MapEdge`
  (avec `id`)/`MapGraph` (graphe + Dijkstra + `withVirtualStart` +
  `roomsByFloor`), `Building` (repère géo + nœud d'entrée), `CustomPoi`
  (points d'intérêt importés côté serveur).
- `lib/src/core/services/` — `LocationService`, `CompassService`,
  `MotionService`, `BarometerService`, `GeoUtils`, `MapGraphNotifier` (état
  partagé + persistance + `refreshFromServer`), `MapGraphApiClient`
  (backend, CRUD granulaire nœuds/arêtes/bâtiments), `QrWaypointCodec`,
  `CustomPoiApiClient`/`CustomPoiNotifier`.
- `lib/src/features/navigation/` — `RouteCalculator`, `SensorFusionService`,
  `StepCounterService`, `NavigationNotifier` (bascule GPS/PDR automatique
  par étape), `DestinationPickerScreen` (écran unique : carte + bâtiments +
  recherche + scan QR), `QrScanScreen`.
- `lib/src/features/mapping/` — `MappingRecorderScreen` (cartographie AR,
  avec sélection de bâtiment), `QrCodesScreen`.
- `lib/src/features/admin/` — `AdminScreen` : gestion des bâtiments, points
  extérieurs et liaisons depuis l'app (pendant mobile du dashboard web).
- `lib/src/features/camera_ar/` — `ArNavigationScreen` (un seul trajet
  continu, peut traverser plusieurs bâtiments).
- `assets/models/arrow.glb` — modèle 3D généré par script, format `.glb`
  binaire (le `.gltf`+base64 ne s'affichait pas correctement sur le
  chargeur natif Android — à retenir pour tout futur modèle).
- `assets/map_style.json` — style vectoriel MapLibre recoloré aux couleurs
  de marque (généré depuis le style "positron" d'OpenFreeMap).
- `server/` — backend FastAPI (voir section dédiée ci-dessus).
- `server/admin/index.html` — dashboard web (Leaflet + JS vanilla, aucune
  dépendance de build), servi par le backend à `/admin`.

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
6. `maplibre_gl` nécessite **JDK 21** pour compiler sa partie Android
   (`org.gradle.java.home` fixé dans `android/gradle.properties` — sinon
   erreur Gradle `invalid source release: 21`).

## Lancer le projet

```bash
flutter pub get
flutter analyze   # vérifie que tout compile avant de lancer sur device
flutter run
```

## Architecture cible (rappel)

- **Administration** (le client final, via le dashboard web ou l'app) :
  placer ses bâtiments sur la carte, décrire leurs pièces/étages/liaisons.
- **Cartographie physique** (optionnelle, un opérateur sur site) : parcourir
  l'établissement, poser des ancres AR + QR codes pour une précision fine.
- **Navigation** (utilisateur final) : une recherche/tap sur la carte →
  calcul d'itinéraire unique, même multi-bâtiments → suivi en continu (GPS
  dehors, odométrie à pas dedans, bascule automatique) → flèche superposée à
  l'image caméra.

Le point dur du projet reste la précision en conditions réelles (dérive du
PDR entre deux QR trop espacés, GPS en zone dense) — à ajuster avec des
tests sur site (densité des QR codes, calibration de la longueur de foulée).
# pentamap
