/// What to do with an inbound call invite.
///
/// Pure so the ORDER of the checks can be pinned by a test. It shipped wrong:
/// the busy guard ran before the glare check, and `ringing` is not `idle`, so
/// the glare branch was unreachable. Two people pressing Call at the same
/// moment busy-rejected each other and neither call connected, with the code
/// written to handle it sitting right underneath, never reached.
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
/// [ringingOutgoingToSamePerson] must be computed through the device→master
/// resolver, never by comparing raw peer ids: an outgoing call targets a
/// MASTER while an inbound signal carries the sender's DEVICE, so a raw `==`
/// silently reports "not glare" for every multi-device peer. When the device
/// map has not loaded yet it reads false and we land on [InviteAction.busy],
/// which is the old behaviour rather than a wrong one.
///
/// [ourMaster] and [theirMaster] must BOTH be master identities. The tiebreak
/// only works if the two ends compare the same pair of strings: our master
/// against their device would let both sides conclude they are polite, and
/// then nobody is calling anybody.
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
