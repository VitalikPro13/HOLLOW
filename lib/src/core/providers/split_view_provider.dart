import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Context for a single pane in split view.
class PaneContext {
  final String? serverId;
  final String? channelId;
  final String? peerId;
  final bool settingsOpen;

  const PaneContext({
    this.serverId,
    this.channelId,
    this.peerId,
    this.settingsOpen = false,
  });

  PaneContext copyWith({
    String? Function()? serverId,
    String? Function()? channelId,
    String? Function()? peerId,
    bool? settingsOpen,
  }) {
    return PaneContext(
      serverId: serverId != null ? serverId() : this.serverId,
      channelId: channelId != null ? channelId() : this.channelId,
      peerId: peerId != null ? peerId() : this.peerId,
      settingsOpen: settingsOpen ?? this.settingsOpen,
    );
  }
}

/// State for the split view system.
class SplitViewState {
  final PaneContext? rightPane;
  final double dividerPosition;
  final int focusedPane;
  /// When non-null, the shell should migrate this context to global providers
  /// and then call clearPendingMigration().
  final PaneContext? pendingMigration;

  const SplitViewState({
    this.rightPane,
    this.dividerPosition = 0.5,
    this.focusedPane = 0,
    this.pendingMigration,
  });

  bool get isSplit => rightPane != null;

  SplitViewState copyWith({
    PaneContext? Function()? rightPane,
    double? dividerPosition,
    int? focusedPane,
    PaneContext? Function()? pendingMigration,
  }) {
    return SplitViewState(
      rightPane: rightPane != null ? rightPane() : this.rightPane,
      dividerPosition: dividerPosition ?? this.dividerPosition,
      focusedPane: focusedPane ?? this.focusedPane,
      pendingMigration: pendingMigration != null
          ? pendingMigration()
          : this.pendingMigration,
    );
  }
}

final splitViewProvider =
    NotifierProvider<SplitViewNotifier, SplitViewState>(
        SplitViewNotifier.new);

class SplitViewNotifier extends Notifier<SplitViewState> {
  @override
  SplitViewState build() => const SplitViewState();

  /// Open split view with an empty right pane.
  void openSplit() {
    state = state.copyWith(
      rightPane: () => const PaneContext(),
      focusedPane: 1,
    );
  }

  /// Close split view entirely (keeps left pane content).
  void closeSplit() {
    state = const SplitViewState();
  }

  /// Close a specific pane. If the left pane (0) is closed, the right pane's
  /// context is stored as pendingMigration so the shell can apply it to
  /// global providers (since the right pane's ref can't access global providers).
  void closePane(int closedPane) {
    if (!state.isSplit) return;
    final rightCtx = state.rightPane;
    if (closedPane == 0 && rightCtx != null) {
      state = SplitViewState(pendingMigration: rightCtx);
    } else {
      state = const SplitViewState();
    }
  }

  /// Clear the pending migration after the shell has applied it.
  void clearPendingMigration() {
    if (state.pendingMigration != null) {
      state = state.copyWith(pendingMigration: () => null);
    }
  }

  /// Set which pane is focused (0 = left, 1 = right).
  void setFocus(int pane) {
    if (pane == state.focusedPane) return;
    state = state.copyWith(focusedPane: pane);
  }

  /// Update the draggable divider position (clamped 0.3–0.7).
  void setDividerPosition(double pos) {
    final clamped = pos.clamp(0.3, 0.7);
    state = state.copyWith(dividerPosition: clamped);
  }

  /// Navigate the right pane to a server + channel.
  void navigateRightToServer(String serverId, {String? channelId}) {
    final right = state.rightPane ?? const PaneContext();
    state = state.copyWith(
      rightPane: () => right.copyWith(
        serverId: () => serverId,
        channelId: () => channelId,
        peerId: () => null,
        settingsOpen: false,
      ),
    );
  }

  /// Navigate the right pane to a DM peer.
  void navigateRightToPeer(String peerId) {
    final right = state.rightPane ?? const PaneContext();
    state = state.copyWith(
      rightPane: () => right.copyWith(
        serverId: () => null,
        channelId: () => null,
        peerId: () => peerId,
        settingsOpen: false,
      ),
    );
  }

  /// Set channel on the right pane (when server is already set).
  void setRightChannel(String? channelId) {
    final right = state.rightPane;
    if (right == null) return;
    state = state.copyWith(
      rightPane: () => right.copyWith(channelId: () => channelId),
    );
  }

  /// Toggle settings on the right pane.
  void toggleRightSettings() {
    final right = state.rightPane;
    if (right == null) return;
    state = state.copyWith(
      rightPane: () => right.copyWith(settingsOpen: !right.settingsOpen),
    );
  }
}
