import 'package:flutter/painting.dart';

/// The one shadow, for things that float above the app: menus, the message
/// hover bar, popovers. Nothing below the `overlay` surface casts one.
abstract final class HollowShadows {
  static const List<BoxShadow> float = [
    BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
  ];
}
