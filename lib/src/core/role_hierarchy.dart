/// Power-role hierarchy shared by every member-management surface
/// (server settings Members tab, profile-card Manage Member dialog).
///
/// Dart-side checks are advisory UI gating only — the authoritative gate is
/// Rust `op_allowed` (`can_change_role`), which validates `op.author`.
library;

/// Whether [actorRole] can change [targetRole] to a different role.
bool canManageRole(String actorRole, String targetRole) {
  const priorities = {'owner': 3, 'admin': 2, 'moderator': 1, 'member': 0};
  final actorPriority = priorities[actorRole] ?? 0;
  final targetPriority = priorities[targetRole] ?? 0;
  if (actorRole == 'owner') return true;
  if (actorPriority <= 1) return false; // Members & moderators can't manage
  return actorPriority > targetPriority;
}

/// Roles that [actorRole] can assign (must be below actor's rank).
List<String> assignableRoles(String actorRole) {
  if (actorRole == 'owner') {
    return ['admin', 'moderator', 'member'];
  }
  if (actorRole == 'admin') {
    return ['moderator', 'member'];
  }
  return [];
}
