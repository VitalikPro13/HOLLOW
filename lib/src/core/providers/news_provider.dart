import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

const kNewsUrl = 'https://anonlisten.com/hollow/releases/news.json';

class NewsPost {
  final String id;
  final String date;
  final String title;
  final String body;

  const NewsPost({
    required this.id,
    required this.date,
    required this.title,
    required this.body,
  });

  factory NewsPost.fromJson(Map<String, dynamic> json) => NewsPost(
        id: json['id'] as String? ?? '',
        date: json['date'] as String? ?? '',
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
      );
}

class NewsState {
  final List<NewsPost> posts;
  final bool hasFetched;

  const NewsState({this.posts = const [], this.hasFetched = false});

  NewsState copyWith({List<NewsPost>? posts, bool? hasFetched}) => NewsState(
        posts: posts ?? this.posts,
        hasFetched: hasFetched ?? this.hasFetched,
      );
}

class NewsNotifier extends Notifier<NewsState> {
  @override
  NewsState build() {
    Future.microtask(() {
      _fetch();
      ref.read(updaterProvider.notifier).checkForUpdates();
    });
    return const NewsState();
  }

  Future<void> _fetch() async {
    if (state.hasFetched) return;
    await _doFetch();
  }

  Future<bool> refresh() async => _doFetch();

  Future<bool> _doFetch() async {
    try {
      final bustCache = DateTime.now().millisecondsSinceEpoch;
      final json = await updater_api.fetchVersionManifest(
          manifestUrl: '$kNewsUrl?t=$bustCache');
      final list = jsonDecode(json) as List<dynamic>;
      final posts = list
          .map((e) => NewsPost.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(posts: posts, hasFetched: true);
      return true;
    } catch (_) {
      state = state.copyWith(hasFetched: true);
      return false;
    }
  }
}

final newsProvider =
    NotifierProvider<NewsNotifier, NewsState>(NewsNotifier.new);
