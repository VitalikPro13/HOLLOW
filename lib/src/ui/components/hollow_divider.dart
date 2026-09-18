import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// The hairline, and nothing else.
///
/// There is no colour parameter on purpose: one boundary weight, one boundary
/// colour, everywhere. It occupies exactly its own thickness, unlike Material's
/// [Divider] whose default `height` reserves 16 logical pixels of blank space
/// and silently changes the spacing of whatever it sits in.
class HollowDivider extends StatelessWidget {
  final double indent;
  final double endIndent;

  const HollowDivider({super.key, this.indent = 0, this.endIndent = 0});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, end: endIndent),
      child: Container(
        height: _hairline,
        color: HollowTheme.of(context).border,
      ),
    );
  }
}

/// The hairline, turned. Separates two things side by side.
class HollowVerticalDivider extends StatelessWidget {
  final double indent;
  final double endIndent;

  const HollowVerticalDivider({super.key, this.indent = 0, this.endIndent = 0});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: indent, bottom: endIndent),
      child: Container(
        width: _hairline,
        color: HollowTheme.of(context).border,
      ),
    );
  }
}

/// One logical pixel. The boundary is a line, not a band.
const double _hairline = 1;
