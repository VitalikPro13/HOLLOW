/// What to do with an inbound call invite.
///
/// Pure so the ORDER of the checks can be pinned by a test: the busy guard
/// once ran before the glare check, and since `ringing` is not `idle` the glare
/// branch was unreachable and simultaneous callers busy-rejected each other.
enum InviteAction {
  /// Both sides dialled at once and we are the polite one: abandon our own
  /// outgoing invite and take theirs, exactly like any normal incoming call.
  glarePolite,

  /// Both sides dialled at once and we are the impolite one: keep our own
  /// outgoing invite and drop theirs. They will take ours.
  glareImpolite,

  /// We are occupied with an unrelated call.
  busy,

  /// Nothing in the way: ring.
  ring,
}

/// Decide what an inbound invite means.
///
/// [ringingOutgoingToSamePerson] must be computed through the device->master
/// resolver, never by comparing raw peer ids: an outgoing call targets a MASTER
/// while an inbound signal carries the sender's DEVICE. An unloaded device map
/// reads false and lands on [InviteAction.busy], the old behaviour.
///
/// [ourMaster] and [theirMaster] must BOTH be masters: the tiebreak only works
/// if the two ends compare the same pair of strings.
InviteAction decideInviteAction({
  required bool ringingOutgoingToSamePerson,
  required bool idle,
  required String ourMaster,
  required String theirMaster,
}) {
  // Glare FIRST. This ordering is the whole point of the function.
  if (ringingOutgoingToSamePerson) {
    return ourMaster.compareTo(theirMaster) < 0
        ? InviteAction.glarePolite
        : InviteAction.glareImpolite;
  }
  if (!idle) return InviteAction.busy;
  return InviteAction.ring;
}
