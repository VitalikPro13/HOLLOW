import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_on_screen_provider.dart';

/// Hears every page pushed on the app's navigator, so a phone channel route
/// knows when another page covers it.
final pageRouteObserver = RouteObserver<PageRoute<dynamic>>();

/// Registers a phone chat route's server channel with the on-screen gate only
/// while its page is the top one: a DM, a profile, the media viewer or any
/// other page pushed over it takes the channel off screen until it pops.
/// Dialogs and sheets leave the channel showing behind them.
mixin ChannelOnScreenRoute<T extends ConsumerStatefulWidget> on ConsumerState<T>
    implements RouteAware {
  /// The server channel this page shows, or null (a DM, a meeting).
  ScreenChannel? get onScreenChannel;

  MobileChannelRoutes? _routes;
  ModalRoute<dynamic>? _route;
  bool _top = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    if (onScreenChannel != null) {
      _routes = ref.read(mobileChannelRoutesProvider.notifier);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routes == null) return;
    final route = ModalRoute.of(context);
    if (route == _route) return;
    if (_route is PageRoute) pageRouteObserver.unsubscribe(this);
    _route = route;
    if (route is PageRoute<dynamic>) {
      // Calls didPush at once.
      pageRouteObserver.subscribe(this, route);
    } else {
      // Not on a page of its own: nothing can be pushed over it.
      _show(true);
    }
  }

  /// Provider writes wait out the build or navigation step that reported the
  /// change; the last report wins.
  void _show(bool top) {
    _top = top;
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      final routes = _routes;
      final channel = onScreenChannel;
      if (routes == null || channel == null || !mounted) return;
      try {
        _top ? routes.open(this, channel) : routes.close(this);
      } catch (_) {}
    });
  }

  @override
  void didPush() => _show(true);

  @override
  void didPopNext() => _show(true);

  @override
  void didPushNext() => _show(false);

  @override
  void didPop() => _show(false);

  @override
  void dispose() {
    final routes = _routes;
    if (routes != null) {
      if (_route is PageRoute) pageRouteObserver.unsubscribe(this);
      Future.microtask(() {
        // The whole container may be gone by now (app teardown, a test).
        try {
          routes.close(this);
        } catch (_) {}
      });
    }
    super.dispose();
  }
}
