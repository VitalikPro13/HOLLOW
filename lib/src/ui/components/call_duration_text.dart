import 'dart:async';

import 'package:flutter/widgets.dart';

/// A self-ticking call-duration label, mm:ss and h:mm:ss past an hour. The
/// tick lives INSIDE this leaf, so a call screen does not rebuild its whole
/// Scaffold once a second for the life of the call.
class CallDurationText extends StatefulWidget {
  final DateTime startedAt;
  final TextStyle? style;

  const CallDurationText({super.key, required this.startedAt, this.style});

  static String format(Duration d) {
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (d.inHours == 0) {
      return '${d.inMinutes.toString().padLeft(2, '0')}:$seconds';
    }
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    return '${d.inHours}:$minutes:$seconds';
  }

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

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt);
    return Text(
      CallDurationText.format(elapsed.isNegative ? Duration.zero : elapsed),
      style: widget.style,
    );
  }
}
