import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const _storageKey = 'server_strip_layout';

class ServerStripLayoutNotifier extends Notifier<List<StripItem>> {
  @override
  List<StripItem> build() => [];

  /// Load layout from local settings and sync with current server list.
  Future<void> loadLayout() async {
    try {
      final json = await storage_api.loadSetting(key: _storageKey);
      if (json != null && json.isNotEmpty) {
        final list = (jsonDecode(json) as List)
            .map((e) => StripItem.fromJson(e as Map<String, dynamic>))
            .toList();
        state = list;
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load strip layout: $e');
    }
    _syncWithServers();
  }

  /// Reconcile layout with current server list.
  void _syncWithServers() {
    final servers = ref.read(serverListProvider);
    final validIds = servers.keys.toSet();
    var changed = false;
    final items = List<StripItem>.from(state);

    // Collect all server IDs in layout
    final layoutIds = <String>{};
    for (final item in items) {
      switch (item) {
        case ServerStripItem(:final serverId):
          layoutIds.add(serverId);
        case FolderStripItem(:final serverIds):
          layoutIds.addAll(serverIds);
      }
    }

    // Remove deleted servers from top-level
    final toRemove = <int>[];
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is ServerStripItem && !validIds.contains(item.serverId)) {
        toRemove.add(i);
        changed = true;
      }
    }
    for (final i in toRemove.reversed) {
      items.removeAt(i);
    }

    // Remove deleted servers from folders, dissolve empty/single folders
    for (int i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is FolderStripItem) {
        final filtered =
            item.serverIds.where((id) => validIds.contains(id)).toList();
        if (filtered.length != item.serverIds.length) changed = true;
        if (filtered.isEmpty) {
          items.removeAt(i);
          changed = true;
        } else if (filtered.length == 1) {
          items[i] = ServerStripItem(serverId: filtered.first);
          changed = true;
        } else if (filtered.length != item.serverIds.length) {
          items[i] = item.copyWith(serverIds: filtered);
        }
      }
    }

    // Append new servers not in layout
    for (final id in validIds) {
      if (!layoutIds.contains(id)) {
        items.add(ServerStripItem(serverId: id));
        changed = true;
      }
    }

    if (changed) {
      state = items;
      _save();
    } else if (state.isEmpty && validIds.isNotEmpty) {
      // First launch — no saved layout
      state = validIds.map((id) => ServerStripItem(serverId: id)).toList();
      _save();
    }
  }

  Future<void> _save() async {
    try {
      final json = jsonEncode(state.map((e) => e.toJson()).toList());
      await storage_api.saveSetting(key: _storageKey, value: json);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save strip layout: $e');
    }
  }

  /// Reorder a top-level item.
  void reorder(int oldIndex, int newIndex) {
    final items = List<StripItem>.from(state);
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex < 0 ||
        oldIndex >= items.length ||
        newIndex < 0 ||
        newIndex >= items.length) {
      return;
    }
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);
    state = items;
    _save();
  }

  /// Create a folder by merging two servers.
  void createFolder(String serverId1, String serverId2) {
    final items = List<StripItem>.from(state);
    final idx1 =
        items.indexWhere((e) => e is ServerStripItem && e.serverId == serverId1);
    final idx2 =
        items.indexWhere((e) => e is ServerStripItem && e.serverId == serverId2);
    if (idx1 < 0 || idx2 < 0) return;

    final insertAt = idx1 < idx2 ? idx1 : idx2;
    // Remove both (higher index first to avoid shift)
    if (idx1 > idx2) {
      items.removeAt(idx1);
      items.removeAt(idx2);
    } else {
      items.removeAt(idx2);
      items.removeAt(idx1);
    }

    final folder = FolderStripItem(
      id: DateTime.now().millisecondsSinceEpoch.toRadixString(16),
      name: 'Folder',
      serverIds: [serverId1, serverId2],
    );
    items.insert(insertAt.clamp(0, items.length), folder);
    state = items;
    _save();
  }

  /// Add a server to an existing folder.
  void addToFolder(String folderId, String serverId) {
    final items = List<StripItem>.from(state);

    // Remove server from top-level
    items.removeWhere((e) => e is ServerStripItem && e.serverId == serverId);

    // Also remove from any other folder
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is FolderStripItem && item.id != folderId) {
        final filtered =
            item.serverIds.where((id) => id != serverId).toList();
        if (filtered.length != item.serverIds.length) {
          if (filtered.isEmpty) {
            items.removeAt(i);
            i--;
          } else if (filtered.length == 1) {
            items[i] = ServerStripItem(serverId: filtered.first);
          } else {
            items[i] = item.copyWith(serverIds: filtered);
          }
        }
      }
    }

    // Add to target folder
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is FolderStripItem && item.id == folderId) {
        if (!item.serverIds.contains(serverId)) {
          items[i] =
              item.copyWith(serverIds: [...item.serverIds, serverId]);
        }
        break;
      }
    }

    state = items;
    _save();
  }

  /// Remove a server from a folder and insert at a top-level position.
  void removeFromFolder(String folderId, String serverId, int insertIndex) {
    final items = List<StripItem>.from(state);

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is FolderStripItem && item.id == folderId) {
        final filtered =
            item.serverIds.where((id) => id != serverId).toList();
        if (filtered.isEmpty) {
          items.removeAt(i);
        } else if (filtered.length == 1) {
          items[i] = ServerStripItem(serverId: filtered.first);
        } else {
          items[i] = item.copyWith(serverIds: filtered);
        }
        break;
      }
    }

    // Insert the removed server at the target position
    final clampedIndex = insertIndex.clamp(0, items.length);
    items.insert(clampedIndex, ServerStripItem(serverId: serverId));

    state = items;
    _save();
  }

  /// Rename a folder.
  void renameFolder(String folderId, String name) {
    final items = List<StripItem>.from(state);
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is FolderStripItem && item.id == folderId) {
        items[i] = item.copyWith(name: name);
        break;
      }
    }
    state = items;
    _save();
  }

  /// Reorder servers within a folder.
  void reorderInsideFolder(String folderId, int oldIndex, int newIndex) {
    final items = List<StripItem>.from(state);
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is FolderStripItem && item.id == folderId) {
        final sids = List<String>.from(item.serverIds);
        if (newIndex > oldIndex) newIndex--;
        final id = sids.removeAt(oldIndex);
        sids.insert(newIndex, id);
        items[i] = item.copyWith(serverIds: sids);
        break;
      }
    }
    state = items;
    _save();
  }

  /// Called when a new server is created/joined.
  void onServerCreated(String serverId) {
    // Check if already in layout
    for (final item in state) {
      if (item is ServerStripItem && item.serverId == serverId) return;
      if (item is FolderStripItem && item.serverIds.contains(serverId)) return;
    }
    state = [...state, ServerStripItem(serverId: serverId)];
    _save();
  }

  /// Called when a server is deleted or user is kicked.
  void onServerDeleted(String serverId) {
    final items = List<StripItem>.from(state);

    // Remove from top-level
    items.removeWhere((e) => e is ServerStripItem && e.serverId == serverId);

    // Remove from folders
    for (int i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is FolderStripItem && item.serverIds.contains(serverId)) {
        final filtered =
            item.serverIds.where((id) => id != serverId).toList();
        if (filtered.isEmpty) {
          items.removeAt(i);
        } else if (filtered.length == 1) {
          items[i] = ServerStripItem(serverId: filtered.first);
        } else {
          items[i] = item.copyWith(serverIds: filtered);
        }
      }
    }

    state = items;
    _save();
  }

  /// Get all server IDs in the layout (top-level + inside folders).
  Set<String> allServerIds() {
    final ids = <String>{};
    for (final item in state) {
      switch (item) {
        case ServerStripItem(:final serverId):
          ids.add(serverId);
        case FolderStripItem(:final serverIds):
          ids.addAll(serverIds);
      }
    }
    return ids;
  }
}

final serverStripLayoutProvider =
    NotifierProvider<ServerStripLayoutNotifier, List<StripItem>>(
  ServerStripLayoutNotifier.new,
);
