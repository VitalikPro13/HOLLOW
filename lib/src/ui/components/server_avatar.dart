import 'package:flutter/material.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/name_initials.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/server_icon_image.dart';

/// A server's icon at list size: its image, else initials on its own colour.
class ServerAvatar extends StatelessWidget {
  final String serverId;
  final String name;
  final double size;

  const ServerAvatar({
    super.key,
    required this.serverId,
    required this.name,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusMd);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: colorFromId(serverId), borderRadius: radius),
      alignment: Alignment.center,
      child: ServerIconImage(
        serverId: serverId,
        size: size,
        borderRadius: radius,
        fallback: Text(
          initialsFromName(name.isNotEmpty ? name : serverId),
          style: HollowTypography.label.copyWith(
            color: Colors.white, // design-ignore: initials on an identity colour, as HollowAvatar
          ),
        ),
      ),
    );
  }
}
