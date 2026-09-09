import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Le repère visuel de Pentamap : un point d'ancrage avec une aiguille —
/// littéralement "un endroit précis, avec une direction à suivre", le
/// résumé de ce que fait l'app. Réutilisé sur l'accueil, l'écran d'arrivée
/// et le cadre des QR codes pour donner un fil visuel commun à des écrans
/// par ailleurs très différents (caméra AR, liste, code-barres).
class PentamapMark extends StatelessWidget {
  final double size;

  const PentamapMark({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _MarkPainter()),
    );
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final ringPaint = Paint()
      ..color = PentamapColors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.08;
    canvas.drawCircle(center, radius - ringPaint.strokeWidth / 2, ringPaint);

    // Aiguille pointant "vers l'avant" (haut), pointe en waypoint pour
    // rappeler que c'est toujours elle qui marque un repère fixe.
    final needlePath = Path()
      ..moveTo(center.dx, center.dy - radius * 0.62)
      ..lineTo(center.dx + radius * 0.24, center.dy + radius * 0.18)
      ..lineTo(center.dx, center.dy)
      ..lineTo(center.dx - radius * 0.24, center.dy + radius * 0.18)
      ..close();
    canvas.drawPath(needlePath, Paint()..color = PentamapColors.orange);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
