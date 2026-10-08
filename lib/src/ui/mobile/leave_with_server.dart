import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';

/// Closes the phone page around [child] when [serverId] leaves the server
/// list: kicked, banned, deleted or left from any device.
class LeaveWithServer extends ConsumerStatefulWidget {
  /// Null for a page about no listed server (a DM, a meeting).
  final String? serverId;
  final Widget child;

  const LeaveWithServer({
    super.key,
    required this.serverId,
    required this.child,
  });

  @override
  ConsumerState<LeaveWithServer> createState() => _LeaveWithServerState();
}

class _LeaveWithServerState extends ConsumerState<LeaveWithServer> {
  /// A popped route's listeners still fire during the pop frame, where
  /// `ref.read` on the deactivated element throws while `mounted` stays true.
  bool _deactivated = false;

  @override
  void deactivate() {
    _deactivated = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _deactivated = false;
  }

  @override
  Widget build(BuildContext context) {
    final serverId = widget.serverId;
    if (serverId != null) {
      ref.listen(serverListProvider.select((s) => s.containsKey(serverId)),
          _onListedChanged);
    }
    return widget.child;
  }

  void _onListedChanged(bool? wasListed, bool listed) {
    if (listed || !mounted || _deactivated) return;
    // A list that has not finished loading is filling in, not losing a server.
    if (!ref.read(serverListLoadStateProvider).loaded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _leaveRoute());
  }

  /// Leaves the stack wherever this route sits in it, so a page opened above
  /// it (a DM from a member's profile) is not the one that goes.
  void _leaveRoute() {
    if (!mounted || _deactivated) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive || route.isFirst) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }
}
