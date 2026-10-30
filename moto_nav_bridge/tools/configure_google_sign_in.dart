import 'dart:convert';
import 'dart:io';
import 'package:moto_nav_bridge/config/account_config.dart';

/// Derives the iOS callback from the same public IDs used by the Dart build.
/// This tool never accepts or writes an OAuth Client Secret.
String renderGoogleSignInXcconfig(Map<String, dynamic> values) {
  final ios = values['NAVIO_GOOGLE_IOS_CLIENT_ID'];
  final web = values['NAVIO_GOOGLE_WEB_CLIENT_ID'];
  if (ios is! String ||
      web is! String ||
      !AccountConfig.isGoogleClientId(ios) ||
      !AccountConfig.isGoogleClientId(web)) {
    throw const FormatException('Supply valid public Web and iOS client IDs.');
  }
  final config = AccountConfig(
    url: '',
    publishableKey: '',
    googleIosClientId: ios,
  );
  return '// Generated from public OAuth IDs; do not edit by hand.\n'
      'NAVIO_GOOGLE_IOS_URL_SCHEME = ${config.googleIosUrlScheme}\n';
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tools/configure_google_sign_in.dart <dart-defines.json>',
    );
    exitCode = 64;
    return;
  }
  try {
    final values = jsonDecode(await File(arguments.single).readAsString());
    if (values is! Map<String, dynamic>) throw const FormatException();
    final rendered = renderGoogleSignInXcconfig(values);
    final output = File.fromUri(
      Platform.script.resolve('../ios/Flutter/GoogleSignIn.local.xcconfig'),
    );
    await output.writeAsString(rendered);
    stdout.writeln(
      'Configured the local iOS Google callback. Rebuild with the same dart-defines file.',
    );
  } on Object {
    // Configuration may contain other credentials. Never print input/exception.
    stderr.writeln(
      'Could not configure Google sign-in. Check the JSON file and public client IDs; no configuration values were logged.',
    );
    exitCode = 1;
  }
}
