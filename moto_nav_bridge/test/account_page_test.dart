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
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  late AccountController account;
  late FakeAccountBackend backend;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backend = FakeAccountBackend();
    account = AccountController(
      backend,
      LocalAccountData(await SharedPreferences.getInstance()),
    );
    await account.initialize();
  });
  tearDown(() async {
    account.dispose();
    await backend.events.close();
  });
  Future<void> show(WidgetTester tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: account,
        child: const MaterialApp(home: AccountPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field(String placeholder) => find.byWidgetPredicate(
    (w) => w is CupertinoTextField && w.placeholder == placeholder,
  );
  testWidgets(
    'email login is reachable and signs into the account without touching BLE',
    (tester) async {
      await show(tester);
      await tester.enterText(field('Email'), 'rider@example.test');
      await tester.enterText(field('Password'), 'not-a-real-password');
      await tap(tester, find.text('Sign in').last);
      await tester.pumpAndSettle();
      expect(find.text('rider@example.test'), findsOneWidget);
      expect(find.text('Upload current settings'), findsNothing);
      expect(find.text('Restore from cloud'), findsNothing);
      expect(find.text('Import guest settings'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Automatic sync'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Automatic sync'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('plain account text has a real body style under MaterialApp', (
    tester,
  ) async {
    await account.signIn('rider@example.test', 'password');
    await show(tester);
    final label = find.textContaining('Saved places, map/route preferences');
    final style = DefaultTextStyle.of(tester.element(label)).style;
    expect(style.decoration, TextDecoration.none);
    expect(style.fontSize, 17);
    expect(style.color, isNot(const Color(0xD0FF0000)));
    final rich = tester.widget<RichText>(
      find.descendant(of: label, matching: find.byType(RichText)),
    );
    expect(rich.text.style?.decoration, TextDecoration.none);
  });
  testWidgets(
    'registration exposes an email code flow and never logs a password',
    (tester) async {
      await show(tester);
      await tap(tester, find.text('Register'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Email'), 'rider@example.test');
      await tester.enterText(field('Password'), 'not-a-real-password');
      await tester.enterText(field('Repeat password'), 'not-a-real-password');
      await tap(tester, find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Verify email'), findsOneWidget);
      expect(field('Code from email'), findsOneWidget);
      expect(account.user, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('destructive account deletion requires typing DELETE', (
    tester,
  ) async {
    await account.signIn('rider@example.test', 'not-a-real-password');
    await show(tester);
    await tester.scrollUntilVisible(find.text('Delete account'), 200);
    await tester.pumpAndSettle();
    await tap(tester, find.text('Delete account'));
    await tester.pumpAndSettle();
    final action = find.widgetWithText(CupertinoDialogAction, 'Confirm');
    expect(tester.widget<CupertinoDialogAction>(action).onPressed, isNull);
    expect(backend.deletions, 0);
    await tester.enterText(field('DELETE'), 'DELETE');
    await tester.pump();
    await tap(tester, action);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.deletions, 1);
    expect(account.user, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'registration accepts six characters but rejects five or mismatch',
    (tester) async {
      await show(tester);
      await tap(tester, find.text('Register'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Email'), 'rider@example.test');
      await tester.enterText(field('Password'), 'abcde');
      await tester.enterText(field('Repeat password'), 'abcde');
      await tap(tester, find.text('Create account'));
      await tester.pumpAndSettle();
      expect(field('Code from email'), findsNothing);
      expect(find.textContaining('at least 6'), findsOneWidget);
      await tester.enterText(field('Password'), 'abcdef');
      await tap(tester, find.text('Create account'));
      await tester.pumpAndSettle();
      expect(field('Code from email'), findsNothing);
      await tester.enterText(field('Repeat password'), 'abcdef');
      await tap(tester, find.text('Create account'));
      await tester.pumpAndSettle();
      expect(field('Code from email'), findsOneWidget);
    },
  );
  testWidgets('password recovery accepts a six character replacement', (
    tester,
  ) async {
    await show(tester);
    await tester.enterText(field('Email'), 'rider@example.test');
    await tap(tester, find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tap(tester, find.text('Send recovery code'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Code from email'), '123456');
    await tester.enterText(field('New password'), 'abcdef');
    await tester.enterText(field('Repeat password'), 'abcdef');
    await tester.scrollUntilVisible(
      find.text('Set new password'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tap(tester, find.text('Set new password'));
    await tester.pumpAndSettle();
    expect(account.user?.email, 'rider@example.test');
  });
  testWidgets(
    'unconfigured service shows a clear status rather than a broken login',
    (tester) async {
      backend.available = false;
      await show(tester);
      expect(find.textContaining('not configured'), findsOneWidget);
      expect(field('Email'), findsNothing);
    },
  );
  testWidgets('password visibility can be toggled without changing its value', (
    tester,
  ) async {
    await show(tester);
    await tester.enterText(field('Password'), 'abcdef');
    expect(
      tester.widget<CupertinoTextField>(field('Password')).obscureText,
      isTrue,
    );
    await tap(tester, find.byIcon(CupertinoIcons.eye));
    expect(
      tester.widget<CupertinoTextField>(field('Password')).obscureText,
      isFalse,
    );
    expect(
      tester.widget<CupertinoTextField>(field('Password')).controller!.text,
      'abcdef',
    );
    await tap(tester, find.byIcon(CupertinoIcons.eye_slash));
    expect(
      tester.widget<CupertinoTextField>(field('Password')).obscureText,
      isTrue,
    );
  });
  testWidgets(
    'unconfigured Apple sign in is hidden, email login remains usable',
    (tester) async {
      backend.appleAvailable = false;
      await show(tester);
      expect(find.text('Continue with Apple'), findsNothing);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(field('Email'), findsOneWidget);
    },
  );
  testWidgets('reset rejects five characters and allows returning to sign in', (
    tester,
  ) async {
    await show(tester);
    await tester.enterText(field('Email'), 'rider@example.test');
    await tap(tester, find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tap(tester, find.text('Send recovery code'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Code from email'), '123456');
    await tester.enterText(field('New password'), 'abcde');
    await tester.enterText(field('Repeat password'), 'abcde');
    await tap(tester, find.text('Set new password'));
    await tester.pumpAndSettle();
    expect(account.user, isNull);
    expect(find.textContaining('at least 6'), findsOneWidget);
    await tap(tester, find.text('Back to sign in'));
    await tester.pumpAndSettle();
    expect(field('Code from email'), findsNothing);
    expect(
      tester.widget<CupertinoTextField>(field('Password')).controller!.text,
      isEmpty,
    );
  });
  testWidgets('Google action signs in without an email or password', (
    tester,
  ) async {
    backend.googleAvailable = true;
    await show(tester);
    await tap(tester, find.text('Continue with Google'));
    expect(backend.googleCalls, 1);
    expect(find.text('google@example.test'), findsOneWidget);
    expect(backend.uploads, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Google cancellation stays on the form without an alarming error',
    (tester) async {
      backend.googleAvailable = true;
      backend.cancelGoogle = true;
      await show(tester);
      await tap(tester, find.text('Continue with Google'));
      expect(account.user, isNull);
      expect(account.error, isNull);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.textContaining('Request failed'), findsNothing);
    },
  );
  testWidgets('Google is hidden until configured and omitted from recovery', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Continue with Google'), findsNothing);
    backend.googleAvailable = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester);
    expect(find.text('Continue with Google'), findsOneWidget);
    await tap(tester, find.text('Register'));
    expect(find.text('Continue with Google'), findsOneWidget);
    await tap(tester, find.text('Sign in'));
    await tap(tester, find.text('Forgot password?'));
    expect(find.text('Continue with Google'), findsNothing);
  });
  for (final brightness in Brightness.values) {
    testWidgets('compact $brightness form supports large text and keyboard', (
      tester,
    ) async {
      tester.view.reset();
      backend.googleAvailable = true;
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: account,
          child: CupertinoApp(
            theme: CupertinoThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.6),
                viewInsets: const EdgeInsets.only(bottom: 300),
              ),
              child: child!,
            ),
            home: const AccountPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.text('Register'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Create account').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
