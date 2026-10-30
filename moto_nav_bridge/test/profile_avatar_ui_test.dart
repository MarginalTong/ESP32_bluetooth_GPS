import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/account_controller.dart';
import 'package:moto_nav_bridge/controllers/avatar_controller.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';
import 'package:moto_nav_bridge/ui/account_page.dart';
import 'account_test_fakes.dart';
import 'avatar_test_fakes.dart';

void main() {
  testWidgets(
    'photo selection previews before upload and removal requires confirmation',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      SharedPreferences.setMockInitialValues({});
      final auth = FakeAccountBackend();
      final account = AccountController(
        auth,
        LocalAccountData(await SharedPreferences.getInstance()),
      );
      await account.initialize();
      await account.signIn('rider@example.test', 'password');
      final backend = FakeAvatarBackend();
      final avatars = AvatarController(
        account,
        backend,
        source: FakeAvatarSource(),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: account),
            ChangeNotifierProvider.value(value: avatars),
          ],
          child: const CupertinoApp(home: AccountPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose photo'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Use this profile photo?'), findsOneWidget);
      expect(backend.uploads, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.uploads, 0);
      await tester.tap(find.text('Choose photo'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Use photo'));
      await tester.pumpAndSettle();
      expect(backend.uploads, 1);
      expect(find.text('Change photo'), findsOneWidget);
      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();
      expect(backend.removals, 0);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(backend.removals, 1);
      expect(find.text('Choose photo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      avatars.dispose();
      account.dispose();
      await auth.events.close();
    },
  );
}
