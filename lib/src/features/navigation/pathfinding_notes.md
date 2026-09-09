# Notes — module navigation

Ce dossier contiendra :

- `sensor_fusion_service.dart` — combine boussole (`flutter_compass`) + IMU
  (`sensors_plus`) + GPS (`geolocator`) pour estimer en continu la pose de
  l'utilisateur entre deux relocalisations AR.
- `route_calculator.dart` — enveloppe autour de `MapGraph.shortestPath`,
  convertit le chemin en instructions pas à pas ("tourner à droite dans 5 m").
- `navigation_controller.dart` — état de la navigation en cours (position
  actuelle, prochaine instruction, distance restante), exposé via Riverpod.

À faire ensuite une fois le SDK AR branché :
- Écouter la pose caméra ARKit/ARCore à chaque frame.
- Projeter le prochain nœud du chemin dans l'espace 3D de la session AR
  pour positionner la flèche `ar_flutter_plugin_plus`.
