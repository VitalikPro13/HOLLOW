import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage;

import 'probe_dump.dart';

/// A probe op that could not do what it was asked; its text is the answer.
class SessionOpFailure implements Exception {
  SessionOpFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Ops the relay-session fleet tooling needs inside the app: lifecycle, how long
/// the app takes to be healthy again, and counted DM streams whose loss a run can
/// measure (`scripts/fleet_time_to_healthy.ps1`, `scripts/fleet_soak.ps1`).
///
/// | op | args | does |
/// |---|---|---|
/// | `lifecycle` | `state` (`resumed`, `inactive`) | delivers that app lifecycle state |
/// | `clock` | | the device's wall clock, for the host's offset |
/// | `friend` | `action` (`request`, `accept`), `contact` | the friends provider's own call |
/// | `autoreply` | `contact`, `on`, `reply`, `off` | answers `ping:` DMs from `contact` with `pong:` |
/// | `health` | `rt_peer`, `timeout_ms`, `poll_ms` | time to `connected`, then a DM round trip |
/// | `stream_start` | `contact`, `tag`, `every_ms` | sends `soak:<tag>:<n>` to `contact` on a timer |
/// | `stream_stop` | `tag` | stops that stream |
/// | `stream_stats` | `contact`, `tag` | what this app sent and what it holds from `contact` |
///
/// `contact` is a master peer id; `peer` names the fleet instance and never
/// reaches the app.
class SessionOps {
  SessionOps(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer? container;

  ProviderSubscription<Map<String, List<ChatMessage>>>? _autoreply;
  final Set<String> _answered = {};
  final Map<String, _Stream> _streams = {};

  static const ops = {
    'lifecycle',
    'clock',
    'friend',
    'autoreply',
    'health',
    'stream_start',
    'stream_stop',
    'stream_stats',
  };

  ProviderContainer get _container {
    final c = container;
    if (c == null) throw SessionOpFailure('this op needs the provider container');
    return c;
  }

  Future<String> run(String op, Map<String, dynamic> step, Map<String, dynamic> extra) {
    switch (op) {
      case 'lifecycle':
        return _lifecycle(step);
      case 'clock':
        extra['epoch_ms'] = DateTime.now().millisecondsSinceEpoch;
        return Future.value('clock ${extra['epoch_ms']}');
      case 'friend':
        return _friend(step);
      case 'autoreply':
        return Future.value(_autoreplyOp(step));
      case 'health':
        return _health(step, extra);
      case 'stream_start':
        return Future.value(_streamStart(step));
      case 'stream_stop':
        return Future.value(_streamStop(step, extra));
      case 'stream_stats':
        return _streamStats(step, extra);
    }
    throw SessionOpFailure('unknown session op "$op"');
  }

  /// Ends every timer and listener, so a quitting session leaves none pending.
  void dispose() {
    _autoreply?.close();
    _autoreply = null;
    for (final stream in _streams.values) {
      stream.timer.cancel();
    }
  }

  /// Walks the framework through the same transitions the engine would send.
  /// Only states that keep frames on: a probe in `hidden` or `paused` draws no
  /// frame and so can never answer the step that would bring it back.
  Future<String> _lifecycle(Map<String, dynamic> step) async {
    final name = '${step['state'] ?? ''}';
    final target = switch (name) {
      'resumed' => AppLifecycleState.resumed,
      'inactive' => AppLifecycleState.inactive,
      _ => throw SessionOpFailure(
          'lifecycle takes "resumed" or "inactive"; "$name" would stop the '
          'frames the probe answers with'),
    };
    final binding = WidgetsBinding.instance;
    const order = [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ];
    final current = binding.lifecycleState;
    final path = <AppLifecycleState>[];
    var index = current == null ? -1 : order.indexOf(current);
    final goal = order.indexOf(target);
    if (index < 0) {
      path.add(target);
    } else {
      while (index != goal) {
        index += goal > index ? 1 : -1;
        path.add(order[index]);
      }
    }
    for (final state in path) {
      // ignore: invalid_use_of_protected_member
      binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(milliseconds: 50));
    return 'lifecycle ${current?.name ?? 'unset'} -> '
        '${path.isEmpty ? 'no change' : path.map((s) => s.name).join(' -> ')}';
  }

  Future<String> _friend(Map<String, dynamic> step) async {
    final peer = '${step['contact'] ?? ''}';
    if (peer.isEmpty) throw SessionOpFailure('friend needs a "contact"');
    final notifier = _container.read(friendsProvider.notifier);
    final action = '${step['action'] ?? ''}';
    switch (action) {
      case 'request':
        await tester.runAsync(() => notifier.sendRequest(peer));
      case 'accept':
        await tester.runAsync(() => notifier.acceptRequest(peer));
      default:
        throw SessionOpFailure('friend takes action "request" or "accept"');
    }
    return 'friend $action $peer';
  }

  String _autoreplyOp(Map<String, dynamic> step) {
    _autoreply?.close();
    _autoreply = null;
    if (step['off'] == true) return 'autoreply off';
    final peer = '${step['contact'] ?? ''}';
    if (peer.isEmpty) throw SessionOpFailure('autoreply needs a "contact"');
    final on = '${step['on'] ?? 'ping:'}';
    final reply = '${step['reply'] ?? 'pong:'}';
    final c = _container;
    // Pings already held are history, not questions.
    for (final m in c.read(chatProvider)[peer] ?? const <ChatMessage>[]) {
      if (!m.isMe && m.text.startsWith(on)) _answered.add(m.messageId ?? m.text);
    }
    _autoreply = c.listen<Map<String, List<ChatMessage>>>(chatProvider, (_, next) {
      for (final m in next[peer] ?? const <ChatMessage>[]) {
        if (m.isMe || !m.text.startsWith(on)) continue;
        if (!_answered.add(m.messageId ?? m.text)) continue;
        final answer = '$reply${m.text.substring(on.length)}';
        // Outside the listener: the send itself changes this provider.
        Future(() => c.read(chatProvider.notifier).sendMessage(peer, answer))
            .catchError((Object e) {
          debugPrint('[ui-probe] autoreply to $peer failed: $e');
          return '';
        });
      }
    });
    return 'autoreply to $peer: "$on..." -> "$reply..."';
  }

  /// From the moment this step runs: when the connection reads `connected`, and
  /// with `rt_peer`, when a ping sent then comes back answered (`autoreply` on
  /// the other side). Every time is also given as the device's epoch, so the
  /// host can measure from the moment it acted.
  Future<String> _health(Map<String, dynamic> step, Map<String, dynamic> extra) async {
    final c = _container;
    final timeout = Duration(milliseconds: (step['timeout_ms'] as num?)?.toInt() ?? 120000);
    final poll = Duration(milliseconds: (step['poll_ms'] as num?)?.toInt() ?? 25);
    final rtPeer = step['rt_peer'] as String?;
    final t0 = DateTime.now();
    extra['t0_epoch_ms'] = t0.millisecondsSinceEpoch;

    final states = <String>[];
    DateTime? connectedAt;
    while (true) {
      final now = '${ProbeDump.providerSnapshot(c)['connection'] ?? 'unknown'}';
      if (states.isEmpty || states.last != now) states.add(now);
      if (now == 'connected') {
        connectedAt = DateTime.now();
        break;
      }
      if (DateTime.now().difference(t0) >= timeout) break;
      await tester.pump(poll);
    }
    extra['states'] = states;
    // Read connected on the very first look: it may be a state from before the
    // trip away that nothing has corrected yet. The round trip settles it.
    extra['first_poll_connected'] = states.length == 1 && connectedAt != null;
    if (connectedAt == null) {
      throw SessionOpFailure('never connected within ${timeout.inMilliseconds}ms '
          '(states ${states.join(' -> ')})');
    }
    extra['connected_epoch_ms'] = connectedAt.millisecondsSinceEpoch;
    extra['connected_ms'] = connectedAt.difference(t0).inMilliseconds;
    if (rtPeer == null || rtPeer.isEmpty) {
      return 'connected after ${extra['connected_ms']}ms (${states.join(' -> ')})';
    }

    final token = '${DateTime.now().microsecondsSinceEpoch}';
    final pong = 'pong:$token';
    await tester.runAsync(() => c.read(chatProvider.notifier).sendMessage(rtPeer, 'ping:$token'));
    DateTime? answeredAt;
    var lastDbCheck = DateTime.now();
    while (DateTime.now().difference(t0) < timeout) {
      final held = c.read(chatProvider)[rtPeer] ?? const <ChatMessage>[];
      if (held.any((m) => !m.isMe && m.text == pong)) {
        answeredAt = DateTime.now();
        break;
      }
      // A reply that came by sync rather than live sits in the database only.
      if (DateTime.now().difference(lastDbCheck) > const Duration(seconds: 2)) {
        lastDbCheck = DateTime.now();
        final rows = await tester.runAsync(() => storage.loadMessages(peerId: rtPeer, limit: 50));
        if ((rows ?? const []).any((r) => !r.isMine && r.text == pong)) {
          answeredAt = DateTime.now();
          break;
        }
      }
      await tester.pump(poll);
    }
    if (answeredAt == null) {
      extra['rt_ms'] = null;
      throw SessionOpFailure('connected after ${extra['connected_ms']}ms, but no answer to '
          'ping:$token within ${timeout.inMilliseconds}ms');
    }
    extra['rt_epoch_ms'] = answeredAt.millisecondsSinceEpoch;
    extra['rt_ms'] = answeredAt.difference(t0).inMilliseconds;
    return 'connected after ${extra['connected_ms']}ms, round trip done after '
        '${extra['rt_ms']}ms (${states.join(' -> ')})';
  }

  String _streamStart(Map<String, dynamic> step) {
    final peer = '${step['contact'] ?? ''}';
    final tag = '${step['tag'] ?? ''}';
    if (peer.isEmpty || tag.isEmpty) throw SessionOpFailure('stream_start needs "contact" and "tag"');
    if (_streams.containsKey(tag)) throw SessionOpFailure('stream $tag is already running');
    final every = Duration(milliseconds: (step['every_ms'] as num?)?.toInt() ?? 3000);
    final c = _container;
    final stream = _Stream(peer);
    stream.timer = Timer.periodic(every, (_) {
      final seq = stream.next++;
      c
          .read(chatProvider.notifier)
          .sendMessage(peer, 'soak:$tag:$seq')
          .then((_) => stream.sent.add(seq), onError: (Object e) {
        stream.failed.add(seq);
        debugPrint('[ui-probe] stream $tag send $seq failed: $e');
      });
    });
    _streams[tag] = stream;
    return 'stream $tag -> $peer every ${every.inMilliseconds}ms';
  }

  String _streamStop(Map<String, dynamic> step, Map<String, dynamic> extra) {
    final tag = '${step['tag'] ?? ''}';
    final stream = _streams[tag];
    if (stream == null) throw SessionOpFailure('no stream $tag');
    stream.timer.cancel();
    extra['sent'] = stream.sent.length;
    return 'stream $tag stopped after ${stream.next - 1} sends '
        '(${stream.sent.length} handed to the node, ${stream.failed.length} refused)';
  }

  /// `sent` = what this app's stream handed to the node; `received` = the
  /// sequence numbers of `soak:<tag>:` messages from `peer` in this app's
  /// database, which is where every delivery path ends (live, sync, push fetch).
  Future<String> _streamStats(Map<String, dynamic> step, Map<String, dynamic> extra) async {
    final peer = '${step['contact'] ?? ''}';
    final tag = '${step['tag'] ?? ''}';
    if (peer.isEmpty || tag.isEmpty) throw SessionOpFailure('stream_stats needs "contact" and "tag"');
    final stream = _streams[tag];
    final sent = stream == null ? <int>[] : ([...stream.sent]..sort());
    final rows = await tester.runAsync(() => storage.loadAllDmMessages(peerId: peer)) ?? const [];
    final prefix = 'soak:$tag:';
    final counts = <int, int>{};
    for (final row in rows) {
      if (row.isMine || !row.text.startsWith(prefix)) continue;
      final seq = int.tryParse(row.text.substring(prefix.length));
      if (seq != null) counts[seq] = (counts[seq] ?? 0) + 1;
    }
    final received = counts.keys.toList()..sort();
    extra['sent'] = sent;
    extra['failed'] = stream == null ? <int>[] : ([...stream.failed]..sort());
    extra['received'] = received;
    extra['received_dupes'] = counts.values.where((n) => n > 1).length;
    return 'stream $tag: sent ${sent.length} to ${stream?.peer ?? '-'}, '
        'holds ${received.length} from $peer';
  }
}

class _Stream {
  _Stream(this.peer);
  final String peer;
  late Timer timer;
  int next = 1;
  final List<int> sent = [];
  final List<int> failed = [];
}
