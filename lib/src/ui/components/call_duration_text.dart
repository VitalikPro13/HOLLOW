import 'dart:async';

import 'package:flutter/widgets.dart';

/// A self-ticking mm:ss call-duration label. The tick lives INSIDE this leaf
/// widget, so a call screen does not rebuild its whole Scaffold once a second
/// for the life of the call.
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
