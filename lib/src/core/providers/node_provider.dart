import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Node state: status + last error.
class NodeState {
  final NodeStatus status;
  final String? error;

  const NodeState({this.status = NodeStatus.loading, this.error});

  NodeState copyWith({NodeStatus? status, String? error}) {
    return NodeState(
      status: status ?? this.status,
      error: error,
    );
  }
}

class NodeNotifier extends Notifier<NodeState> {
  @override
  NodeState build() => const NodeState();

  /// Start the libp2p node and begin event polling.
  Future<void> start() async {
    state = state.copyWith(status: NodeStatus.starting, error: null);
    try {
      final networkService = ref.read(networkServiceProvider);
      final peerId = await networkService.startNode();

      // Update identity with the peer ID from the node.
      final identity = ref.read(identityProvider.notifier);
      identity.state = identity.state.copyWith(peerId: peerId);

      state = state.copyWith(status: NodeStatus.connected);

      // Reset stale file paths (files marked complete but missing on disk).
      // Cleared entries are re-fetched by the viewport sweep
      // (requestVisibleFiles) when their messages scroll into view.
      try {
        final resetCount = await storage_api.resetStaleFiles();
        if (resetCount > 0) {
          debugPrint('[HOLLOW] Reset $resetCount stale file paths for re-download');
        }
      } catch (e) {
        debugPrint('[HOLLOW] Failed to reset stale files: $e');
      }

      // Start polling for network events. Stale files (reset above) are
      // re-fetched on demand by the viewport sweep (requestVisibleFiles).
      ref.read(eventStreamProvider.notifier).start();

      // Auto-join saved guest rooms (realtime + onLaunch).
      autoJoinGuestRooms(ref);

      // Initialize push notifications on mobile (registers FCM token with relay).
      //
      // Both guards are needed. The Firebase getters throw SYNCHRONOUSLY when
      // no Firebase app exists (a probe launch, a build without the config
      // file), and a synchronous throw never reaches catchError: it fell
      // straight through to the outer catch below and marked a node that was
      // up and connected as NodeStatus.error. Push is optional; the node is
      // not, so nothing here may fail it.
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          PushNotificationService().initialize().catchError((e) {
            debugPrint('[HOLLOW] Push notification init failed: $e');
          });
        } catch (e) {
          debugPrint('[HOLLOW] Push notification init failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[HOLLOW] Node start error: $e');
      state = state.copyWith(status: NodeStatus.error, error: e.toString());
    }
  }

  /// Stop the node and event polling.
  Future<void> stop() async {
    ref.read(eventStreamProvider.notifier).stop();
    try {
      await ref.read(networkServiceProvider).stopNode();
    } catch (e) {
      debugPrint('[HOLLOW] Node stop error: $e');
    }
    state = state.copyWith(status: NodeStatus.loading);
  }

  /// Clear error state.
  void clearError() {
    state = state.copyWith(error: null);
  }
}

final nodeProvider =
    NotifierProvider<NodeNotifier, NodeState>(NodeNotifier.new);
