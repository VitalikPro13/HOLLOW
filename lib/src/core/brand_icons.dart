import 'package:flutter/widgets.dart';

const _kFontFamily = 'SimpleIcons';

abstract final class BrandIcons {
  static const IconData twitch = IconData(0xf58a, fontFamily: _kFontFamily);
  static const IconData youtube = IconData(0xf692, fontFamily: _kFontFamily);
  static const IconData x = IconData(0xf672, fontFamily: _kFontFamily);
  static const IconData kick = IconData(0xefe3, fontFamily: _kFontFamily);
  static const IconData patreon = IconData(0xf223, fontFamily: _kFontFamily);
  static const IconData kofi = IconData(0xeff6, fontFamily: _kFontFamily);
  static const IconData github = IconData(0xee42, fontFamily: _kFontFamily);
}

abstract final class BrandIconColors {
  static const Color twitch = Color(0xFF9146FF);
  static const Color youtube = Color(0xFFFF0000);
  static const Color kick = Color(0xFF53FC19);
  static const Color kofi = Color(0xFFFF6433);
  static const Color patreon = Color(0xFF000000);
}
