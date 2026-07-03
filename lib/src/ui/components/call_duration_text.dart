import 'dart:async';

import 'package:flutter/widgets.dart';

/// A self-ticking mm:ss call-duration label.
///
/// The 1-second tick lives INSIDE this leaf widget, so only this Text
/// rebuilds each second — the call screens used to run the timer in their
/// own State and `setState` the entire Scaffold (video tiles, controls,
/// renderer probing) once per second for the life of the call.
class CallDurationText extends StatefulWidget {
  final DateTime startedAt;
  final TextStyle? style;

  const CallDurationText({super.key, required this.startedAt, this.style});

  @override
  State<CallDurationText> createState() => _CallDurationTextState();
}

class _CallDurationTextState extends State<CallDurationText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt);
    return Text(
      _format(elapsed.isNegative ? Duration.zero : elapsed),
      style: widget.style,
    );
  }
}
