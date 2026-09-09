import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pentamap/src/app/app.dart';

void main() {
  testWidgets("L'écran d'accueil affiche les deux modes", (tester) async {
    await tester.pumpWidget(const ProviderScope(child: PentamapApp()));

    expect(find.text('Naviguer dehors'), findsOneWidget);
    expect(find.text('Naviguer dedans'), findsOneWidget);
    expect(find.text('Cartographier ce lieu (opérateur)'), findsOneWidget);
  });
}
