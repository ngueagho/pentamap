import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/services/qr_waypoint_codec.dart';

/// Ouvre la caméra pour scanner un QR code de repère Pentamap, et retourne
/// (graphId, nodeId) via [Navigator.pop] dès qu'un QR valide est détecté.
///
/// Utilisé à deux moments : pour démarrer une navigation intérieure (on ne
/// connaît pas la position de départ tant qu'aucun QR n'a été scanné), et
/// pendant une navigation en cours pour se recaler si l'odométrie à pas a
/// dérivé (voir `NavigationNotifier.resyncToNode`).
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final decoded = QrWaypointCodec.decode(raw);
      if (decoded != null) {
        _handled = true;
        Navigator.of(context).pop(decoded);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner un repère')),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black.withValues(alpha: 0.6),
              padding: const EdgeInsets.all(16),
              child: const Text(
                'Visez le QR code collé au point de repère',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
