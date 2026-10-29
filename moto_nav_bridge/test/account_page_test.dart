import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:moto_nav_bridge/ui/account_page.dart';
import 'account_test_fakes.dart';

void main() {
  late AccountController account;
  late FakeAccountBackend backend;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backend = FakeAccountBackend();
    account = AccountController(
        backend, LocalAccountData(await SharedPreferences.getInstance()));
    await account.initialize();
  });
  tearDown(() async {
    account.dispose();
    await backend.events.close();
  });
  Future<void> show(WidgetTester tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: account, child: const MaterialApp(home: AccountPage())));
    await tester.pumpAndSettle();
  }

  Finder field(String placeholder) => find.byWidgetPredicate(
      (w) => w is CupertinoTextField && w.placeholder == placeholder);
  testWidgets(
      'email login is reachable and signs into the account without touching BLE',
      (tester) async {
    await show(tester);
    await tester.enterText(field('Email'), 'rider@example.test');
    await tester.enterText(field('Password'), 'not-a-real-password');
    await tester.tap(find.text('Sign in').last);
    await tester.pumpAndSettle();
    expect(find.text('rider@example.test'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Upload current settings'), 200);
    expect(find.text('Upload current settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'registration exposes an email code flow and never logs a password',
      (tester) async {
    await show(tester);
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Email'), 'rider@example.test');
    await tester.enterText(field('Password'), 'not-a-real-password');
    await tester.enterText(field('Repeat password'), 'not-a-real-password');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Verify email'), findsOneWidget);
    expect(field('Code from email'), findsOneWidget);
    expect(account.user, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('destructive account deletion requires typing DELETE',
      (tester) async {
    await account.signIn('rider@example.test', 'not-a-real-password');
    await show(tester);
    await tester.scrollUntilVisible(find.text('Delete account'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    final action = find.widgetWithText(CupertinoDialogAction, 'Confirm');
    expect(tester.widget<CupertinoDialogAction>(action).onPressed, isNull);
    expect(backend.deletions, 0);
    await tester.enterText(field('DELETE'), 'DELETE');
    await tester.pump();
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.deletions, 1);
    expect(account.user, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'unconfigured service shows a clear status rather than a broken login',
      (tester) async {
    backend.available = false;
    await show(tester);
    expect(find.textContaining('not configured'), findsOneWidget);
    expect(field('Email'), findsNothing);
  });
}
