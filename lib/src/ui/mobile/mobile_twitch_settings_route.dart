import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../components/follow_days_steps.dart';

class MobileTwitchSettingsRoute extends ConsumerStatefulWidget {
  final String serverId;

  const MobileTwitchSettingsRoute({super.key, required this.serverId});

  @override
  ConsumerState<MobileTwitchSettingsRoute> createState() =>
      _MobileTwitchSettingsRouteState();
}

class _MobileTwitchSettingsRouteState
    extends ConsumerState<MobileTwitchSettingsRoute> {
  final _channelController = TextEditingController();
  final _channelIdController = TextEditingController();
  final _minDaysController = TextEditingController();
  bool _enabled = false;
  bool _requireSub = false;
  bool _ownerVerify = false;
  bool _saving = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await crdt_api.getServerSetting(
        serverId: widget.serverId, key: 'twitch_verification_enabled',
      );
      final channel = await crdt_api.getServerSetting(
        serverId: widget.serverId, key: 'twitch_channel_name',
      );
      final channelId = await crdt_api.getServerSetting(
        serverId: widget.serverId, key: 'twitch_channel_id',
      );
      final minDays = await crdt_api.getServerSetting(
        serverId: widget.serverId, key: 'twitch_min_follow_days',
      );
      final requireSub = await crdt_api.getServerSetting(
        serverId: widget.serverId, key: 'twitch_require_sub',
      );
      final ownerVerify = await crdt_api.getServerSetting(
        serverId: widget.serverId, key: 'twitch_owner_verify',
      );

      if (mounted) {
        setState(() {
          _enabled = enabled == 'true';
          _channelController.text = channel;
          _channelIdController.text = channelId;
          _minDaysController.text = minDays;
          _requireSub = requireSub == 'true';
          _ownerVerify = ownerVerify == 'true';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fillFromAccount() async {
    try {
      final userId = await twitch_api.twitchGetUserId() ?? '';
      final username = await twitch_api.twitchGetUsername() ?? '';
      if (mounted) {
        setState(() {
          if (userId.isNotEmpty) _channelIdController.text = userId;
          if (username.isNotEmpty) _channelController.text = username;
        });
        HollowToast.show(context, 'Filled from your Twitch account',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Connect your Twitch account first',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final settings = {
        'twitch_verification_enabled': _enabled.toString(),
        'twitch_channel_name': _channelController.text.trim(),
        'twitch_channel_id': _channelIdController.text.trim(),
        'twitch_min_follow_days': _minDaysController.text.trim(),
        'twitch_require_sub': _requireSub.toString(),
        'twitch_owner_verify': _ownerVerify.toString(),
      };
      for (final entry in settings.entries) {
        await crdt_api.updateServerSetting(
          serverId: widget.serverId, key: entry.key, value: entry.value,
        );
      }
      if (mounted) {
        HollowToast.show(context, 'Twitch settings saved',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to save',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _channelController.dispose();
    _channelIdController.dispose();
    _minDaysController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final perms = ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? 0;
    final canManage = (perms & Permission.manageServer) != 0;

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: hollow.surface,
                border: Border(bottom: BorderSide(color: hollow.border)),
              ),
              child: Row(
                children: [
                  HollowPressable(
                    onTap: () => Navigator.pop(context),
                    semanticLabel: 'Back',
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(LucideIcons.arrowLeft, size: 22, color: hollow.textPrimary),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Text('Twitch Verification', style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                  )),
                ],
              ),
            ),

            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.all(HollowSpacing.lg),
                      children: [
                        _ToggleRow(
                          label: 'Enable Twitch Verification',
                          subtitle: 'Require Twitch follow/sub to join',
                          value: _enabled,
                          onChanged: canManage
                              ? (v) => setState(() => _enabled = v)
                              : null,
                          hollow: hollow,
                        ),

                        if (_enabled) ...[
                          const SizedBox(height: HollowSpacing.xl),

                          Align(
                            alignment: Alignment.centerRight,
                            child: HollowButton.ghost(
                              onPressed: _fillFromAccount,
                              compact: true,
                              icon: const Icon(LucideIcons.download, size: 14),
                              child: const Text('Fill from account'),
                            ),
                          ),
                          const SizedBox(height: HollowSpacing.sm),

                          Text('Channel Display Name', style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          )),
                          const SizedBox(height: HollowSpacing.xs),
                          HollowTextField(
                            controller: _channelController,
                            hintText: 'e.g. MyTwitchChannel',
                            maxLength: 64,
                            showCounter: true,
                          ),

                          const SizedBox(height: HollowSpacing.lg),

                          Text('Channel ID', style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          )),
                          const SizedBox(height: HollowSpacing.xs),
                          HollowTextField(
                            controller: _channelIdController,
                            hintText: 'Twitch user ID',
                            maxLength: 32,
                          ),

                          const SizedBox(height: HollowSpacing.lg),

                          Text('Minimum follow days', style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          )),
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            'How many days someone must have been following before they can join. Any means just following.',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(height: HollowSpacing.xs),
                          FollowDaysSteps(
                            value: int.tryParse(_minDaysController.text.trim()) ?? 0,
                            onChanged: (v) => setState(() => _minDaysController.text = '$v'),
                          ),

                          const SizedBox(height: HollowSpacing.lg),

                          _ToggleRow(
                            label: 'Require Subscription',
                            subtitle: 'Must be subscribed, not just following',
                            value: _requireSub,
                            onChanged: canManage
                                ? (v) => setState(() => _requireSub = v)
                                : null,
                            hollow: hollow,
                          ),
                          const SizedBox(height: HollowSpacing.md),
                          _ToggleRow(
                            label: 'Owner-Only Verification',
                            subtitle: 'Only accept joins when owner is online',
                            value: _ownerVerify,
                            onChanged: canManage
                                ? (v) => setState(() => _ownerVerify = v)
                                : null,
                            hollow: hollow,
                          ),

                        ],

                        const SizedBox(height: HollowSpacing.xl),

                        // OUTSIDE the `_enabled` block: inside it, toggling
                        // verification off hides the button and the off state
                        // can never be persisted.
                        if (canManage)
                          HollowButton.filled(
                            onPressed: _saving ? null : _save,
                            expand: true,
                            child: Text(_saving ? 'Saving...' : 'Save Twitch Settings'),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final HollowTheme hollow;

  const _ToggleRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
              )),
              Text(subtitle, style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
              )),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: hollow.accent,
          activeThumbColor: Colors.white,
          inactiveTrackColor: hollow.border,
        ),
      ],
    );
  }
}
