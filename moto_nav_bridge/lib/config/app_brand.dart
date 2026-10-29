/// Public product naming. Package, storage and protocol IDs stay stable.
class AppBrand {
  const AppBrand._();

  static const name = 'NAVIO';
  static const displayPrefix = '$name-';

  static String displayName(String identity) => '$displayPrefix$identity';
}
