import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Settings that govern link previews (issue #45).
///
/// Both live here rather than in the compose panes because all three panes
/// (DM, channel, mobile) have to agree, and both values are pushed into Rust
/// at startup the way `gifProxyUrlProvider` is — see `hollow_shell._bootstrap`.

const _kPreviewsEnabledKey = 'link_previews_enabled';
const _kEmbedProxyKey = 'embed_proxy_url';

/// Whether typing a URL fetches its preview at all.
///
/// On by default. Turning it off means the compose box never touches the
/// pasted URL, so the site learns nothing — the strongest version of the
/// privacy story, at the cost of no cards on anything you send. Receiving
/// is unaffected: cards other people attached still render, because
/// rendering never involves a request.
class LinkPreviewsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> loadCached() async {
    try {
      final saved = await storage_api.loadSetting(key: _kPreviewsEnabledKey);
      if (saved == null || saved.isEmpty) return;
      state = saved == '1';
    } catch (_) {}
  }

  /// Rethrows on a persistence failure — call sites await + toast.
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await storage_api.saveSetting(
        key: _kPreviewsEnabledKey, value: enabled ? '1' : '0');
  }
}

final linkPreviewsEnabledProvider =
    NotifierProvider<LinkPreviewsEnabledNotifier, bool>(
        LinkPreviewsEnabledNotifier.new);

/// Optional proxy for the social-post lookups (X, TikTok). Empty = direct,
/// which is the default and what ships.
///
/// Direct is not a degraded mode. FxEmbed reads the post server-side, so X
/// never sees the user's IP for the metadata either way, and someone pasting
/// an x.com link has almost always just opened it in a browser. What direct
/// does expose is the lookup itself to FxEmbed's operator, which is the
/// reason this override exists for anyone who would rather it didn't.
class EmbedProxyUrlNotifier extends Notifier<String> {
  @override
  String build() => '';

  Future<void> loadCached() async {
    try {
      final saved = await storage_api.loadSetting(key: _kEmbedProxyKey);
      if (saved == null || saved.isEmpty) return;
      // Rust validates (https + host); an invalid persisted value is ignored
      // and lookups stay direct.
      await network_api.setEmbedProxyUrl(base: saved);
      state = saved;
    } catch (_) {}
  }

  /// Rethrows on an invalid URL — call sites await + toast.
  Future<void> setUrl(String raw) async {
    final v = raw.trim();
    if (v.isEmpty) {
      await network_api.setEmbedProxyUrl(base: null);
      state = '';
      await storage_api.saveSetting(key: _kEmbedProxyKey, value: '');
    } else {
      await network_api.setEmbedProxyUrl(base: v); // validates, throws
      state = v;
      await storage_api.saveSetting(key: _kEmbedProxyKey, value: v);
    }
  }
}

final embedProxyUrlProvider =
    NotifierProvider<EmbedProxyUrlNotifier, String>(EmbedProxyUrlNotifier.new);
