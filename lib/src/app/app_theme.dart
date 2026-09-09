import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette et typographie de Pentamap.
///
/// Deux couleurs de marque, pas plus : [blue] pour l'extérieur/GPS, [orange]
/// pour l'intérieur/repères — chacune a toujours la même signification à
/// l'œil, jamais utilisées pour autre chose. [ink]/[surface] sont des
/// neutres structurels (texte, fonds), pas des choix de marque. [error] est
/// fonctionnel (états d'erreur), volontairement distinct du orange pour ne
/// jamais confondre "repère" et "problème".
class PentamapColors {
  const PentamapColors._();

  static const ink = Color(0xFF14181F);
  static const surface = Color(0xFFF7F4EE);
  static const blue = Color(0xFF3D6FE0);
  static const orange = Color(0xFFE08A3C);
  static const error = Color(0xFFC0392B);
}

class PentamapTheme {
  const PentamapTheme._();

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: PentamapColors.blue,
        brightness: Brightness.light,
        primary: PentamapColors.blue,
        secondary: PentamapColors.orange,
        error: PentamapColors.error,
        surface: PentamapColors.surface,
      ),
      scaffoldBackgroundColor: PentamapColors.surface,
    );

    final display = GoogleFonts.spaceGroteskTextTheme(base.textTheme);
    final body = GoogleFonts.interTextTheme(base.textTheme);

    return base.copyWith(
      textTheme: body.copyWith(
        displayLarge: display.displayLarge,
        displayMedium: display.displayMedium,
        displaySmall: display.displaySmall,
        headlineLarge: display.headlineLarge,
        headlineMedium: display.headlineMedium,
        headlineSmall: display.headlineSmall,
        titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium: display.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: PentamapColors.surface,
        foregroundColor: PentamapColors.ink,
        elevation: 0,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: PentamapColors.ink,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: PentamapColors.blue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: PentamapColors.ink,
          side: BorderSide(color: PentamapColors.ink.withValues(alpha: 0.18)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: PentamapColors.ink.withValues(alpha: 0.08)),
        ),
      ),
      dividerTheme: DividerThemeData(color: PentamapColors.ink.withValues(alpha: 0.08)),
    );
  }

  /// Style "lecture d'instrument" pour les coordonnées GPS/distances —
  /// monospace, pour que les chiffres s'alignent et se lisent comme une
  /// mesure plutôt que du texte courant.
  static TextStyle readout(BuildContext context, {Color? color, double size = 13}) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      color: color ?? PentamapColors.ink.withValues(alpha: 0.65),
    );
  }
}
