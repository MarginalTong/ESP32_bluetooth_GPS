import 'package:flutter_test/flutter_test.dart';
import '../tools/configure_google_sign_in.dart';

void main() {
  test('callback generation includes only the validated public iOS scheme', () {
    final result = renderGoogleSignInXcconfig({
      'NAVIO_GOOGLE_IOS_CLIENT_ID': '123-ios.apps.googleusercontent.com',
      'NAVIO_GOOGLE_WEB_CLIENT_ID': '123-web.apps.googleusercontent.com',
      'unrelated_secret': 'must-not-leak',
    });
    expect(result, contains('com.googleusercontent.apps.123-ios'));
    expect(result, isNot(contains('123-web')));
    expect(result, isNot(contains('must-not-leak')));
  });
  test('malformed IDs cannot inject Xcode configuration', () {
    for (final invalid in [
      '',
      '123-ios.apps.googleusercontent.com\nOTHER=bad',
      '123-ios.apps.googleusercontent.com.attacker.invalid',
    ]) {
      expect(
        () => renderGoogleSignInXcconfig({
          'NAVIO_GOOGLE_IOS_CLIENT_ID': invalid,
          'NAVIO_GOOGLE_WEB_CLIENT_ID': '123-web.apps.googleusercontent.com',
        }),
        throwsFormatException,
      );
    }
  });
}
