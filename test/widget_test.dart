import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tgg_mobile/auth/auth_repository.dart';
import 'package:tgg_mobile/main.dart';

void main() {
  testWidgets('shows a loading indicator before auth status resolves', (WidgetTester tester) async {
    await tester.pumpWidget(TggApp(authRepository: AuthRepository()));

    // Single pump only (not pumpAndSettle): tryAutoLogin() is async and
    // touches secure-storage/biometric platform channels that aren't mocked
    // in a plain widget test, so we only assert on the synchronous first
    // frame -- status is still AuthStatus.unknown until that resolves.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
