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

  // Showcase game-card platform chips (SimpleIcons, codepoints verified against
  // the bundled full SimpleIcons.ttf). Windows, Xbox and Nintendo were REMOVED
  // from Simple Icons, so those three are custom-painted in platform_icons.dart.
  static const IconData playstation = IconData(0xf273, fontFamily: _kFontFamily);
  static const IconData linux = IconData(0xf05b, fontFamily: _kFontFamily);
  static const IconData apple = IconData(0xeadb, fontFamily: _kFontFamily);
  static const IconData android = IconData(0xea9d, fontFamily: _kFontFamily);

  // Showcase game-card credit links (SimpleIcons, codepoints verified).
  static const IconData facebook = IconData(0xed9c, fontFamily: _kFontFamily);
  static const IconData instagram = IconData(0xef66, fontFamily: _kFontFamily);
  static const IconData discord = IconData(0xed04, fontFamily: _kFontFamily);
  static const IconData reddit = IconData(0xf33b, fontFamily: _kFontFamily);
  static const IconData steam = IconData(0xf490, fontFamily: _kFontFamily);
  static const IconData gog = IconData(0xee62, fontFamily: _kFontFamily);
  static const IconData epicGames = IconData(0xed72, fontFamily: _kFontFamily);
  static const IconData itch = IconData(0xef83, fontFamily: _kFontFamily);
  static const IconData bluesky = IconData(0xeb81, fontFamily: _kFontFamily);
  static const IconData wikipedia = IconData(0xf650, fontFamily: _kFontFamily);
}

abstract final class BrandIconColors {
  static const Color twitch = Color(0xFF9146FF);
  static const Color youtube = Color(0xFFFF0000);
  static const Color kick = Color(0xFF53FC19);
  static const Color kofi = Color(0xFFFF6433);
  static const Color patreon = Color(0xFF000000);
}
