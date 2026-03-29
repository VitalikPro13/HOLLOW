// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'network.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$NetworkEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'NetworkEvent()';
}


}

/// @nodoc
class $NetworkEventCopyWith<$Res>  {
$NetworkEventCopyWith(NetworkEvent _, $Res Function(NetworkEvent) __);
}


/// Adds pattern-matching-related methods to [NetworkEvent].
extension NetworkEventPatterns on NetworkEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( NetworkEvent_PeerDiscovered value)?  peerDiscovered,TResult Function( NetworkEvent_PeerExpired value)?  peerExpired,TResult Function( NetworkEvent_PeerDisconnected value)?  peerDisconnected,TResult Function( NetworkEvent_RoomCleared value)?  roomCleared,TResult Function( NetworkEvent_Listening value)?  listening,TResult Function( NetworkEvent_MessageReceived value)?  messageReceived,TResult Function( NetworkEvent_ChannelMessageReceived value)?  channelMessageReceived,TResult Function( NetworkEvent_MessageSent value)?  messageSent,TResult Function( NetworkEvent_MessageSendFailed value)?  messageSendFailed,TResult Function( NetworkEvent_SessionEstablished value)?  sessionEstablished,TResult Function( NetworkEvent_Error value)?  error,TResult Function( NetworkEvent_ServerCreated value)?  serverCreated,TResult Function( NetworkEvent_ServerUpdated value)?  serverUpdated,TResult Function( NetworkEvent_ChannelAdded value)?  channelAdded,TResult Function( NetworkEvent_ChannelRemoved value)?  channelRemoved,TResult Function( NetworkEvent_ChannelRenamed value)?  channelRenamed,TResult Function( NetworkEvent_ServerDeleted value)?  serverDeleted,TResult Function( NetworkEvent_MemberJoined value)?  memberJoined,TResult Function( NetworkEvent_MemberLeft value)?  memberLeft,TResult Function( NetworkEvent_SyncCompleted value)?  syncCompleted,TResult Function( NetworkEvent_ServerJoined value)?  serverJoined,TResult Function( NetworkEvent_MessageSyncStarted value)?  messageSyncStarted,TResult Function( NetworkEvent_MessageSyncCompleted value)?  messageSyncCompleted,TResult Function( NetworkEvent_MessageSyncFailed value)?  messageSyncFailed,TResult Function( NetworkEvent_MessageSyncProgress value)?  messageSyncProgress,TResult Function( NetworkEvent_RoleChanged value)?  roleChanged,TResult Function( NetworkEvent_DmSyncCompleted value)?  dmSyncCompleted,TResult Function( NetworkEvent_ProfileUpdated value)?  profileUpdated,TResult Function( NetworkEvent_ChannelMessageEdited value)?  channelMessageEdited,TResult Function( NetworkEvent_DmMessageEdited value)?  dmMessageEdited,TResult Function( NetworkEvent_ChannelMessageDeleted value)?  channelMessageDeleted,TResult Function( NetworkEvent_DmMessageDeleted value)?  dmMessageDeleted,TResult Function( NetworkEvent_ChannelReactionAdded value)?  channelReactionAdded,TResult Function( NetworkEvent_DmReactionAdded value)?  dmReactionAdded,TResult Function( NetworkEvent_ChannelReactionRemoved value)?  channelReactionRemoved,TResult Function( NetworkEvent_DmReactionRemoved value)?  dmReactionRemoved,TResult Function( NetworkEvent_FriendRequestReceived value)?  friendRequestReceived,TResult Function( NetworkEvent_FriendRequestAccepted value)?  friendRequestAccepted,TResult Function( NetworkEvent_FriendRequestRejected value)?  friendRequestRejected,TResult Function( NetworkEvent_FriendRemoved value)?  friendRemoved,TResult Function( NetworkEvent_TypingStarted value)?  typingStarted,TResult Function( NetworkEvent_MessagePinned value)?  messagePinned,TResult Function( NetworkEvent_MessageUnpinned value)?  messageUnpinned,TResult Function( NetworkEvent_FileHeaderReceived value)?  fileHeaderReceived,TResult Function( NetworkEvent_FileProgress value)?  fileProgress,TResult Function( NetworkEvent_FileCompleted value)?  fileCompleted,TResult Function( NetworkEvent_FileFailed value)?  fileFailed,TResult Function( NetworkEvent_ShardStored value)?  shardStored,TResult Function( NetworkEvent_ShardStoreAckReceived value)?  shardStoreAckReceived,TResult Function( NetworkEvent_ShardStoreFailed value)?  shardStoreFailed,TResult Function( NetworkEvent_ShardDeleted value)?  shardDeleted,TResult Function( NetworkEvent_ShardReceived value)?  shardReceived,TResult Function( NetworkEvent_ShardRequestFailed value)?  shardRequestFailed,TResult Function( NetworkEvent_VaultUploadProgress value)?  vaultUploadProgress,TResult Function( NetworkEvent_VaultUploadComplete value)?  vaultUploadComplete,TResult Function( NetworkEvent_VaultUploadFailed value)?  vaultUploadFailed,TResult Function( NetworkEvent_VaultDownloadProgress value)?  vaultDownloadProgress,TResult Function( NetworkEvent_VaultDownloadComplete value)?  vaultDownloadComplete,TResult Function( NetworkEvent_VaultDownloadFailed value)?  vaultDownloadFailed,TResult Function( NetworkEvent_RebalanceStarted value)?  rebalanceStarted,TResult Function( NetworkEvent_RebalanceProgress value)?  rebalanceProgress,TResult Function( NetworkEvent_RebalanceCompleted value)?  rebalanceCompleted,TResult Function( NetworkEvent_VaultUploadReplicationFallback value)?  vaultUploadReplicationFallback,TResult Function( NetworkEvent_KeyExchangeStarted value)?  keyExchangeStarted,TResult Function( NetworkEvent_KeyExchangeProgress value)?  keyExchangeProgress,TResult Function( NetworkEvent_WebRtcSignal value)?  webRtcSignal,TResult Function( NetworkEvent_WebRtcSendFile value)?  webRtcSendFile,required TResult orElse(),}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared(_that);case NetworkEvent_Listening() when listening != null:
return listening(_that);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that);case NetworkEvent_ChannelMessageReceived() when channelMessageReceived != null:
return channelMessageReceived(_that);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that);case NetworkEvent_Error() when error != null:
return error(_that);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that);case NetworkEvent_ChannelRenamed() when channelRenamed != null:
return channelRenamed(_that);case NetworkEvent_ServerDeleted() when serverDeleted != null:
return serverDeleted(_that);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case NetworkEvent_ServerJoined() when serverJoined != null:
return serverJoined(_that);case NetworkEvent_MessageSyncStarted() when messageSyncStarted != null:
return messageSyncStarted(_that);case NetworkEvent_MessageSyncCompleted() when messageSyncCompleted != null:
return messageSyncCompleted(_that);case NetworkEvent_MessageSyncFailed() when messageSyncFailed != null:
return messageSyncFailed(_that);case NetworkEvent_MessageSyncProgress() when messageSyncProgress != null:
return messageSyncProgress(_that);case NetworkEvent_RoleChanged() when roleChanged != null:
return roleChanged(_that);case NetworkEvent_DmSyncCompleted() when dmSyncCompleted != null:
return dmSyncCompleted(_that);case NetworkEvent_ProfileUpdated() when profileUpdated != null:
return profileUpdated(_that);case NetworkEvent_ChannelMessageEdited() when channelMessageEdited != null:
return channelMessageEdited(_that);case NetworkEvent_DmMessageEdited() when dmMessageEdited != null:
return dmMessageEdited(_that);case NetworkEvent_ChannelMessageDeleted() when channelMessageDeleted != null:
return channelMessageDeleted(_that);case NetworkEvent_DmMessageDeleted() when dmMessageDeleted != null:
return dmMessageDeleted(_that);case NetworkEvent_ChannelReactionAdded() when channelReactionAdded != null:
return channelReactionAdded(_that);case NetworkEvent_DmReactionAdded() when dmReactionAdded != null:
return dmReactionAdded(_that);case NetworkEvent_ChannelReactionRemoved() when channelReactionRemoved != null:
return channelReactionRemoved(_that);case NetworkEvent_DmReactionRemoved() when dmReactionRemoved != null:
return dmReactionRemoved(_that);case NetworkEvent_FriendRequestReceived() when friendRequestReceived != null:
return friendRequestReceived(_that);case NetworkEvent_FriendRequestAccepted() when friendRequestAccepted != null:
return friendRequestAccepted(_that);case NetworkEvent_FriendRequestRejected() when friendRequestRejected != null:
return friendRequestRejected(_that);case NetworkEvent_FriendRemoved() when friendRemoved != null:
return friendRemoved(_that);case NetworkEvent_TypingStarted() when typingStarted != null:
return typingStarted(_that);case NetworkEvent_MessagePinned() when messagePinned != null:
return messagePinned(_that);case NetworkEvent_MessageUnpinned() when messageUnpinned != null:
return messageUnpinned(_that);case NetworkEvent_FileHeaderReceived() when fileHeaderReceived != null:
return fileHeaderReceived(_that);case NetworkEvent_FileProgress() when fileProgress != null:
return fileProgress(_that);case NetworkEvent_FileCompleted() when fileCompleted != null:
return fileCompleted(_that);case NetworkEvent_FileFailed() when fileFailed != null:
return fileFailed(_that);case NetworkEvent_ShardStored() when shardStored != null:
return shardStored(_that);case NetworkEvent_ShardStoreAckReceived() when shardStoreAckReceived != null:
return shardStoreAckReceived(_that);case NetworkEvent_ShardStoreFailed() when shardStoreFailed != null:
return shardStoreFailed(_that);case NetworkEvent_ShardDeleted() when shardDeleted != null:
return shardDeleted(_that);case NetworkEvent_ShardReceived() when shardReceived != null:
return shardReceived(_that);case NetworkEvent_ShardRequestFailed() when shardRequestFailed != null:
return shardRequestFailed(_that);case NetworkEvent_VaultUploadProgress() when vaultUploadProgress != null:
return vaultUploadProgress(_that);case NetworkEvent_VaultUploadComplete() when vaultUploadComplete != null:
return vaultUploadComplete(_that);case NetworkEvent_VaultUploadFailed() when vaultUploadFailed != null:
return vaultUploadFailed(_that);case NetworkEvent_VaultDownloadProgress() when vaultDownloadProgress != null:
return vaultDownloadProgress(_that);case NetworkEvent_VaultDownloadComplete() when vaultDownloadComplete != null:
return vaultDownloadComplete(_that);case NetworkEvent_VaultDownloadFailed() when vaultDownloadFailed != null:
return vaultDownloadFailed(_that);case NetworkEvent_RebalanceStarted() when rebalanceStarted != null:
return rebalanceStarted(_that);case NetworkEvent_RebalanceProgress() when rebalanceProgress != null:
return rebalanceProgress(_that);case NetworkEvent_RebalanceCompleted() when rebalanceCompleted != null:
return rebalanceCompleted(_that);case NetworkEvent_VaultUploadReplicationFallback() when vaultUploadReplicationFallback != null:
return vaultUploadReplicationFallback(_that);case NetworkEvent_KeyExchangeStarted() when keyExchangeStarted != null:
return keyExchangeStarted(_that);case NetworkEvent_KeyExchangeProgress() when keyExchangeProgress != null:
return keyExchangeProgress(_that);case NetworkEvent_WebRtcSignal() when webRtcSignal != null:
return webRtcSignal(_that);case NetworkEvent_WebRtcSendFile() when webRtcSendFile != null:
return webRtcSendFile(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( NetworkEvent_PeerDiscovered value)  peerDiscovered,required TResult Function( NetworkEvent_PeerExpired value)  peerExpired,required TResult Function( NetworkEvent_PeerDisconnected value)  peerDisconnected,required TResult Function( NetworkEvent_RoomCleared value)  roomCleared,required TResult Function( NetworkEvent_Listening value)  listening,required TResult Function( NetworkEvent_MessageReceived value)  messageReceived,required TResult Function( NetworkEvent_ChannelMessageReceived value)  channelMessageReceived,required TResult Function( NetworkEvent_MessageSent value)  messageSent,required TResult Function( NetworkEvent_MessageSendFailed value)  messageSendFailed,required TResult Function( NetworkEvent_SessionEstablished value)  sessionEstablished,required TResult Function( NetworkEvent_Error value)  error,required TResult Function( NetworkEvent_ServerCreated value)  serverCreated,required TResult Function( NetworkEvent_ServerUpdated value)  serverUpdated,required TResult Function( NetworkEvent_ChannelAdded value)  channelAdded,required TResult Function( NetworkEvent_ChannelRemoved value)  channelRemoved,required TResult Function( NetworkEvent_ChannelRenamed value)  channelRenamed,required TResult Function( NetworkEvent_ServerDeleted value)  serverDeleted,required TResult Function( NetworkEvent_MemberJoined value)  memberJoined,required TResult Function( NetworkEvent_MemberLeft value)  memberLeft,required TResult Function( NetworkEvent_SyncCompleted value)  syncCompleted,required TResult Function( NetworkEvent_ServerJoined value)  serverJoined,required TResult Function( NetworkEvent_MessageSyncStarted value)  messageSyncStarted,required TResult Function( NetworkEvent_MessageSyncCompleted value)  messageSyncCompleted,required TResult Function( NetworkEvent_MessageSyncFailed value)  messageSyncFailed,required TResult Function( NetworkEvent_MessageSyncProgress value)  messageSyncProgress,required TResult Function( NetworkEvent_RoleChanged value)  roleChanged,required TResult Function( NetworkEvent_DmSyncCompleted value)  dmSyncCompleted,required TResult Function( NetworkEvent_ProfileUpdated value)  profileUpdated,required TResult Function( NetworkEvent_ChannelMessageEdited value)  channelMessageEdited,required TResult Function( NetworkEvent_DmMessageEdited value)  dmMessageEdited,required TResult Function( NetworkEvent_ChannelMessageDeleted value)  channelMessageDeleted,required TResult Function( NetworkEvent_DmMessageDeleted value)  dmMessageDeleted,required TResult Function( NetworkEvent_ChannelReactionAdded value)  channelReactionAdded,required TResult Function( NetworkEvent_DmReactionAdded value)  dmReactionAdded,required TResult Function( NetworkEvent_ChannelReactionRemoved value)  channelReactionRemoved,required TResult Function( NetworkEvent_DmReactionRemoved value)  dmReactionRemoved,required TResult Function( NetworkEvent_FriendRequestReceived value)  friendRequestReceived,required TResult Function( NetworkEvent_FriendRequestAccepted value)  friendRequestAccepted,required TResult Function( NetworkEvent_FriendRequestRejected value)  friendRequestRejected,required TResult Function( NetworkEvent_FriendRemoved value)  friendRemoved,required TResult Function( NetworkEvent_TypingStarted value)  typingStarted,required TResult Function( NetworkEvent_MessagePinned value)  messagePinned,required TResult Function( NetworkEvent_MessageUnpinned value)  messageUnpinned,required TResult Function( NetworkEvent_FileHeaderReceived value)  fileHeaderReceived,required TResult Function( NetworkEvent_FileProgress value)  fileProgress,required TResult Function( NetworkEvent_FileCompleted value)  fileCompleted,required TResult Function( NetworkEvent_FileFailed value)  fileFailed,required TResult Function( NetworkEvent_ShardStored value)  shardStored,required TResult Function( NetworkEvent_ShardStoreAckReceived value)  shardStoreAckReceived,required TResult Function( NetworkEvent_ShardStoreFailed value)  shardStoreFailed,required TResult Function( NetworkEvent_ShardDeleted value)  shardDeleted,required TResult Function( NetworkEvent_ShardReceived value)  shardReceived,required TResult Function( NetworkEvent_ShardRequestFailed value)  shardRequestFailed,required TResult Function( NetworkEvent_VaultUploadProgress value)  vaultUploadProgress,required TResult Function( NetworkEvent_VaultUploadComplete value)  vaultUploadComplete,required TResult Function( NetworkEvent_VaultUploadFailed value)  vaultUploadFailed,required TResult Function( NetworkEvent_VaultDownloadProgress value)  vaultDownloadProgress,required TResult Function( NetworkEvent_VaultDownloadComplete value)  vaultDownloadComplete,required TResult Function( NetworkEvent_VaultDownloadFailed value)  vaultDownloadFailed,required TResult Function( NetworkEvent_RebalanceStarted value)  rebalanceStarted,required TResult Function( NetworkEvent_RebalanceProgress value)  rebalanceProgress,required TResult Function( NetworkEvent_RebalanceCompleted value)  rebalanceCompleted,required TResult Function( NetworkEvent_VaultUploadReplicationFallback value)  vaultUploadReplicationFallback,required TResult Function( NetworkEvent_KeyExchangeStarted value)  keyExchangeStarted,required TResult Function( NetworkEvent_KeyExchangeProgress value)  keyExchangeProgress,required TResult Function( NetworkEvent_WebRtcSignal value)  webRtcSignal,required TResult Function( NetworkEvent_WebRtcSendFile value)  webRtcSendFile,}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered():
return peerDiscovered(_that);case NetworkEvent_PeerExpired():
return peerExpired(_that);case NetworkEvent_PeerDisconnected():
return peerDisconnected(_that);case NetworkEvent_RoomCleared():
return roomCleared(_that);case NetworkEvent_Listening():
return listening(_that);case NetworkEvent_MessageReceived():
return messageReceived(_that);case NetworkEvent_ChannelMessageReceived():
return channelMessageReceived(_that);case NetworkEvent_MessageSent():
return messageSent(_that);case NetworkEvent_MessageSendFailed():
return messageSendFailed(_that);case NetworkEvent_SessionEstablished():
return sessionEstablished(_that);case NetworkEvent_Error():
return error(_that);case NetworkEvent_ServerCreated():
return serverCreated(_that);case NetworkEvent_ServerUpdated():
return serverUpdated(_that);case NetworkEvent_ChannelAdded():
return channelAdded(_that);case NetworkEvent_ChannelRemoved():
return channelRemoved(_that);case NetworkEvent_ChannelRenamed():
return channelRenamed(_that);case NetworkEvent_ServerDeleted():
return serverDeleted(_that);case NetworkEvent_MemberJoined():
return memberJoined(_that);case NetworkEvent_MemberLeft():
return memberLeft(_that);case NetworkEvent_SyncCompleted():
return syncCompleted(_that);case NetworkEvent_ServerJoined():
return serverJoined(_that);case NetworkEvent_MessageSyncStarted():
return messageSyncStarted(_that);case NetworkEvent_MessageSyncCompleted():
return messageSyncCompleted(_that);case NetworkEvent_MessageSyncFailed():
return messageSyncFailed(_that);case NetworkEvent_MessageSyncProgress():
return messageSyncProgress(_that);case NetworkEvent_RoleChanged():
return roleChanged(_that);case NetworkEvent_DmSyncCompleted():
return dmSyncCompleted(_that);case NetworkEvent_ProfileUpdated():
return profileUpdated(_that);case NetworkEvent_ChannelMessageEdited():
return channelMessageEdited(_that);case NetworkEvent_DmMessageEdited():
return dmMessageEdited(_that);case NetworkEvent_ChannelMessageDeleted():
return channelMessageDeleted(_that);case NetworkEvent_DmMessageDeleted():
return dmMessageDeleted(_that);case NetworkEvent_ChannelReactionAdded():
return channelReactionAdded(_that);case NetworkEvent_DmReactionAdded():
return dmReactionAdded(_that);case NetworkEvent_ChannelReactionRemoved():
return channelReactionRemoved(_that);case NetworkEvent_DmReactionRemoved():
return dmReactionRemoved(_that);case NetworkEvent_FriendRequestReceived():
return friendRequestReceived(_that);case NetworkEvent_FriendRequestAccepted():
return friendRequestAccepted(_that);case NetworkEvent_FriendRequestRejected():
return friendRequestRejected(_that);case NetworkEvent_FriendRemoved():
return friendRemoved(_that);case NetworkEvent_TypingStarted():
return typingStarted(_that);case NetworkEvent_MessagePinned():
return messagePinned(_that);case NetworkEvent_MessageUnpinned():
return messageUnpinned(_that);case NetworkEvent_FileHeaderReceived():
return fileHeaderReceived(_that);case NetworkEvent_FileProgress():
return fileProgress(_that);case NetworkEvent_FileCompleted():
return fileCompleted(_that);case NetworkEvent_FileFailed():
return fileFailed(_that);case NetworkEvent_ShardStored():
return shardStored(_that);case NetworkEvent_ShardStoreAckReceived():
return shardStoreAckReceived(_that);case NetworkEvent_ShardStoreFailed():
return shardStoreFailed(_that);case NetworkEvent_ShardDeleted():
return shardDeleted(_that);case NetworkEvent_ShardReceived():
return shardReceived(_that);case NetworkEvent_ShardRequestFailed():
return shardRequestFailed(_that);case NetworkEvent_VaultUploadProgress():
return vaultUploadProgress(_that);case NetworkEvent_VaultUploadComplete():
return vaultUploadComplete(_that);case NetworkEvent_VaultUploadFailed():
return vaultUploadFailed(_that);case NetworkEvent_VaultDownloadProgress():
return vaultDownloadProgress(_that);case NetworkEvent_VaultDownloadComplete():
return vaultDownloadComplete(_that);case NetworkEvent_VaultDownloadFailed():
return vaultDownloadFailed(_that);case NetworkEvent_RebalanceStarted():
return rebalanceStarted(_that);case NetworkEvent_RebalanceProgress():
return rebalanceProgress(_that);case NetworkEvent_RebalanceCompleted():
return rebalanceCompleted(_that);case NetworkEvent_VaultUploadReplicationFallback():
return vaultUploadReplicationFallback(_that);case NetworkEvent_KeyExchangeStarted():
return keyExchangeStarted(_that);case NetworkEvent_KeyExchangeProgress():
return keyExchangeProgress(_that);case NetworkEvent_WebRtcSignal():
return webRtcSignal(_that);case NetworkEvent_WebRtcSendFile():
return webRtcSendFile(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( NetworkEvent_PeerDiscovered value)?  peerDiscovered,TResult? Function( NetworkEvent_PeerExpired value)?  peerExpired,TResult? Function( NetworkEvent_PeerDisconnected value)?  peerDisconnected,TResult? Function( NetworkEvent_RoomCleared value)?  roomCleared,TResult? Function( NetworkEvent_Listening value)?  listening,TResult? Function( NetworkEvent_MessageReceived value)?  messageReceived,TResult? Function( NetworkEvent_ChannelMessageReceived value)?  channelMessageReceived,TResult? Function( NetworkEvent_MessageSent value)?  messageSent,TResult? Function( NetworkEvent_MessageSendFailed value)?  messageSendFailed,TResult? Function( NetworkEvent_SessionEstablished value)?  sessionEstablished,TResult? Function( NetworkEvent_Error value)?  error,TResult? Function( NetworkEvent_ServerCreated value)?  serverCreated,TResult? Function( NetworkEvent_ServerUpdated value)?  serverUpdated,TResult? Function( NetworkEvent_ChannelAdded value)?  channelAdded,TResult? Function( NetworkEvent_ChannelRemoved value)?  channelRemoved,TResult? Function( NetworkEvent_ChannelRenamed value)?  channelRenamed,TResult? Function( NetworkEvent_ServerDeleted value)?  serverDeleted,TResult? Function( NetworkEvent_MemberJoined value)?  memberJoined,TResult? Function( NetworkEvent_MemberLeft value)?  memberLeft,TResult? Function( NetworkEvent_SyncCompleted value)?  syncCompleted,TResult? Function( NetworkEvent_ServerJoined value)?  serverJoined,TResult? Function( NetworkEvent_MessageSyncStarted value)?  messageSyncStarted,TResult? Function( NetworkEvent_MessageSyncCompleted value)?  messageSyncCompleted,TResult? Function( NetworkEvent_MessageSyncFailed value)?  messageSyncFailed,TResult? Function( NetworkEvent_MessageSyncProgress value)?  messageSyncProgress,TResult? Function( NetworkEvent_RoleChanged value)?  roleChanged,TResult? Function( NetworkEvent_DmSyncCompleted value)?  dmSyncCompleted,TResult? Function( NetworkEvent_ProfileUpdated value)?  profileUpdated,TResult? Function( NetworkEvent_ChannelMessageEdited value)?  channelMessageEdited,TResult? Function( NetworkEvent_DmMessageEdited value)?  dmMessageEdited,TResult? Function( NetworkEvent_ChannelMessageDeleted value)?  channelMessageDeleted,TResult? Function( NetworkEvent_DmMessageDeleted value)?  dmMessageDeleted,TResult? Function( NetworkEvent_ChannelReactionAdded value)?  channelReactionAdded,TResult? Function( NetworkEvent_DmReactionAdded value)?  dmReactionAdded,TResult? Function( NetworkEvent_ChannelReactionRemoved value)?  channelReactionRemoved,TResult? Function( NetworkEvent_DmReactionRemoved value)?  dmReactionRemoved,TResult? Function( NetworkEvent_FriendRequestReceived value)?  friendRequestReceived,TResult? Function( NetworkEvent_FriendRequestAccepted value)?  friendRequestAccepted,TResult? Function( NetworkEvent_FriendRequestRejected value)?  friendRequestRejected,TResult? Function( NetworkEvent_FriendRemoved value)?  friendRemoved,TResult? Function( NetworkEvent_TypingStarted value)?  typingStarted,TResult? Function( NetworkEvent_MessagePinned value)?  messagePinned,TResult? Function( NetworkEvent_MessageUnpinned value)?  messageUnpinned,TResult? Function( NetworkEvent_FileHeaderReceived value)?  fileHeaderReceived,TResult? Function( NetworkEvent_FileProgress value)?  fileProgress,TResult? Function( NetworkEvent_FileCompleted value)?  fileCompleted,TResult? Function( NetworkEvent_FileFailed value)?  fileFailed,TResult? Function( NetworkEvent_ShardStored value)?  shardStored,TResult? Function( NetworkEvent_ShardStoreAckReceived value)?  shardStoreAckReceived,TResult? Function( NetworkEvent_ShardStoreFailed value)?  shardStoreFailed,TResult? Function( NetworkEvent_ShardDeleted value)?  shardDeleted,TResult? Function( NetworkEvent_ShardReceived value)?  shardReceived,TResult? Function( NetworkEvent_ShardRequestFailed value)?  shardRequestFailed,TResult? Function( NetworkEvent_VaultUploadProgress value)?  vaultUploadProgress,TResult? Function( NetworkEvent_VaultUploadComplete value)?  vaultUploadComplete,TResult? Function( NetworkEvent_VaultUploadFailed value)?  vaultUploadFailed,TResult? Function( NetworkEvent_VaultDownloadProgress value)?  vaultDownloadProgress,TResult? Function( NetworkEvent_VaultDownloadComplete value)?  vaultDownloadComplete,TResult? Function( NetworkEvent_VaultDownloadFailed value)?  vaultDownloadFailed,TResult? Function( NetworkEvent_RebalanceStarted value)?  rebalanceStarted,TResult? Function( NetworkEvent_RebalanceProgress value)?  rebalanceProgress,TResult? Function( NetworkEvent_RebalanceCompleted value)?  rebalanceCompleted,TResult? Function( NetworkEvent_VaultUploadReplicationFallback value)?  vaultUploadReplicationFallback,TResult? Function( NetworkEvent_KeyExchangeStarted value)?  keyExchangeStarted,TResult? Function( NetworkEvent_KeyExchangeProgress value)?  keyExchangeProgress,TResult? Function( NetworkEvent_WebRtcSignal value)?  webRtcSignal,TResult? Function( NetworkEvent_WebRtcSendFile value)?  webRtcSendFile,}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared(_that);case NetworkEvent_Listening() when listening != null:
return listening(_that);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that);case NetworkEvent_ChannelMessageReceived() when channelMessageReceived != null:
return channelMessageReceived(_that);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that);case NetworkEvent_Error() when error != null:
return error(_that);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that);case NetworkEvent_ChannelRenamed() when channelRenamed != null:
return channelRenamed(_that);case NetworkEvent_ServerDeleted() when serverDeleted != null:
return serverDeleted(_that);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case NetworkEvent_ServerJoined() when serverJoined != null:
return serverJoined(_that);case NetworkEvent_MessageSyncStarted() when messageSyncStarted != null:
return messageSyncStarted(_that);case NetworkEvent_MessageSyncCompleted() when messageSyncCompleted != null:
return messageSyncCompleted(_that);case NetworkEvent_MessageSyncFailed() when messageSyncFailed != null:
return messageSyncFailed(_that);case NetworkEvent_MessageSyncProgress() when messageSyncProgress != null:
return messageSyncProgress(_that);case NetworkEvent_RoleChanged() when roleChanged != null:
return roleChanged(_that);case NetworkEvent_DmSyncCompleted() when dmSyncCompleted != null:
return dmSyncCompleted(_that);case NetworkEvent_ProfileUpdated() when profileUpdated != null:
return profileUpdated(_that);case NetworkEvent_ChannelMessageEdited() when channelMessageEdited != null:
return channelMessageEdited(_that);case NetworkEvent_DmMessageEdited() when dmMessageEdited != null:
return dmMessageEdited(_that);case NetworkEvent_ChannelMessageDeleted() when channelMessageDeleted != null:
return channelMessageDeleted(_that);case NetworkEvent_DmMessageDeleted() when dmMessageDeleted != null:
return dmMessageDeleted(_that);case NetworkEvent_ChannelReactionAdded() when channelReactionAdded != null:
return channelReactionAdded(_that);case NetworkEvent_DmReactionAdded() when dmReactionAdded != null:
return dmReactionAdded(_that);case NetworkEvent_ChannelReactionRemoved() when channelReactionRemoved != null:
return channelReactionRemoved(_that);case NetworkEvent_DmReactionRemoved() when dmReactionRemoved != null:
return dmReactionRemoved(_that);case NetworkEvent_FriendRequestReceived() when friendRequestReceived != null:
return friendRequestReceived(_that);case NetworkEvent_FriendRequestAccepted() when friendRequestAccepted != null:
return friendRequestAccepted(_that);case NetworkEvent_FriendRequestRejected() when friendRequestRejected != null:
return friendRequestRejected(_that);case NetworkEvent_FriendRemoved() when friendRemoved != null:
return friendRemoved(_that);case NetworkEvent_TypingStarted() when typingStarted != null:
return typingStarted(_that);case NetworkEvent_MessagePinned() when messagePinned != null:
return messagePinned(_that);case NetworkEvent_MessageUnpinned() when messageUnpinned != null:
return messageUnpinned(_that);case NetworkEvent_FileHeaderReceived() when fileHeaderReceived != null:
return fileHeaderReceived(_that);case NetworkEvent_FileProgress() when fileProgress != null:
return fileProgress(_that);case NetworkEvent_FileCompleted() when fileCompleted != null:
return fileCompleted(_that);case NetworkEvent_FileFailed() when fileFailed != null:
return fileFailed(_that);case NetworkEvent_ShardStored() when shardStored != null:
return shardStored(_that);case NetworkEvent_ShardStoreAckReceived() when shardStoreAckReceived != null:
return shardStoreAckReceived(_that);case NetworkEvent_ShardStoreFailed() when shardStoreFailed != null:
return shardStoreFailed(_that);case NetworkEvent_ShardDeleted() when shardDeleted != null:
return shardDeleted(_that);case NetworkEvent_ShardReceived() when shardReceived != null:
return shardReceived(_that);case NetworkEvent_ShardRequestFailed() when shardRequestFailed != null:
return shardRequestFailed(_that);case NetworkEvent_VaultUploadProgress() when vaultUploadProgress != null:
return vaultUploadProgress(_that);case NetworkEvent_VaultUploadComplete() when vaultUploadComplete != null:
return vaultUploadComplete(_that);case NetworkEvent_VaultUploadFailed() when vaultUploadFailed != null:
return vaultUploadFailed(_that);case NetworkEvent_VaultDownloadProgress() when vaultDownloadProgress != null:
return vaultDownloadProgress(_that);case NetworkEvent_VaultDownloadComplete() when vaultDownloadComplete != null:
return vaultDownloadComplete(_that);case NetworkEvent_VaultDownloadFailed() when vaultDownloadFailed != null:
return vaultDownloadFailed(_that);case NetworkEvent_RebalanceStarted() when rebalanceStarted != null:
return rebalanceStarted(_that);case NetworkEvent_RebalanceProgress() when rebalanceProgress != null:
return rebalanceProgress(_that);case NetworkEvent_RebalanceCompleted() when rebalanceCompleted != null:
return rebalanceCompleted(_that);case NetworkEvent_VaultUploadReplicationFallback() when vaultUploadReplicationFallback != null:
return vaultUploadReplicationFallback(_that);case NetworkEvent_KeyExchangeStarted() when keyExchangeStarted != null:
return keyExchangeStarted(_that);case NetworkEvent_KeyExchangeProgress() when keyExchangeProgress != null:
return keyExchangeProgress(_that);case NetworkEvent_WebRtcSignal() when webRtcSignal != null:
return webRtcSignal(_that);case NetworkEvent_WebRtcSendFile() when webRtcSendFile != null:
return webRtcSendFile(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( DiscoveredPeer peer)?  peerDiscovered,TResult Function( String peerId)?  peerExpired,TResult Function( String peerId)?  peerDisconnected,TResult Function()?  roomCleared,TResult Function( String address)?  listening,TResult Function( String fromPeer,  String text,  PlatformInt64 timestamp,  String messageId,  String replyToMid)?  messageReceived,TResult Function( String serverId,  String channelId,  String fromPeer,  String text,  PlatformInt64 timestamp,  String messageId,  String replyToMid)?  channelMessageReceived,TResult Function( String toPeer)?  messageSent,TResult Function( String toPeer,  String error)?  messageSendFailed,TResult Function( String peerId)?  sessionEstablished,TResult Function( String message)?  error,TResult Function( String serverId,  String name)?  serverCreated,TResult Function( String serverId)?  serverUpdated,TResult Function( String serverId,  String channelId,  String name)?  channelAdded,TResult Function( String serverId,  String channelId)?  channelRemoved,TResult Function( String serverId,  String channelId,  String newName)?  channelRenamed,TResult Function( String serverId)?  serverDeleted,TResult Function( String serverId,  String peerId)?  memberJoined,TResult Function( String serverId,  String peerId)?  memberLeft,TResult Function( String serverId,  int opsApplied)?  syncCompleted,TResult Function( String serverId,  String name)?  serverJoined,TResult Function( String serverId,  String peerId)?  messageSyncStarted,TResult Function( String serverId,  int newMessageCount)?  messageSyncCompleted,TResult Function( String serverId,  String error)?  messageSyncFailed,TResult Function( String serverId,  String channelId,  int receivedCount,  int totalCount)?  messageSyncProgress,TResult Function( String serverId,  String peerId,  String newRole)?  roleChanged,TResult Function( String peerId,  int newMessageCount)?  dmSyncCompleted,TResult Function( String peerId)?  profileUpdated,TResult Function( String serverId,  String channelId,  String messageId,  String newText,  PlatformInt64 editedAt)?  channelMessageEdited,TResult Function( String peerId,  String messageId,  String newText,  PlatformInt64 editedAt)?  dmMessageEdited,TResult Function( String serverId,  String channelId,  String messageId,  PlatformInt64 deletedAt)?  channelMessageDeleted,TResult Function( String peerId,  String messageId,  PlatformInt64 deletedAt)?  dmMessageDeleted,TResult Function( String serverId,  String channelId,  String messageId,  String emoji,  String reactor,  PlatformInt64 addedAt)?  channelReactionAdded,TResult Function( String peerId,  String messageId,  String emoji,  String reactor,  PlatformInt64 addedAt)?  dmReactionAdded,TResult Function( String serverId,  String channelId,  String messageId,  String emoji,  String reactor,  PlatformInt64 removedAt)?  channelReactionRemoved,TResult Function( String peerId,  String messageId,  String emoji,  String reactor,  PlatformInt64 removedAt)?  dmReactionRemoved,TResult Function( String peerId)?  friendRequestReceived,TResult Function( String peerId)?  friendRequestAccepted,TResult Function( String peerId)?  friendRequestRejected,TResult Function( String peerId)?  friendRemoved,TResult Function( String peerId,  String serverId,  String channelId)?  typingStarted,TResult Function( String serverId,  String channelId,  String messageId)?  messagePinned,TResult Function( String serverId,  String channelId,  String messageId)?  messageUnpinned,TResult Function( String fileId,  String fileName,  BigInt sizeBytes,  bool isImage,  int? width,  int? height,  String messageId,  String senderId,  String serverId,  String channelId)?  fileHeaderReceived,TResult Function( String fileId,  int chunksReceived,  int totalChunks)?  fileProgress,TResult Function( String fileId,  String diskPath)?  fileCompleted,TResult Function( String fileId,  String error)?  fileFailed,TResult Function( String serverId,  String contentId,  int shardIndex,  String fromPeer)?  shardStored,TResult Function( String serverId,  String contentId,  int shardIndex,  bool success,  String error)?  shardStoreAckReceived,TResult Function( String serverId,  String contentId,  int shardIndex,  String targetPeer,  String error)?  shardStoreFailed,TResult Function( String serverId,  String contentId)?  shardDeleted,TResult Function( String serverId,  String contentId,  int shardIndex,  String fromPeer)?  shardReceived,TResult Function( String serverId,  String contentId,  int shardIndex,  String error)?  shardRequestFailed,TResult Function( String serverId,  String contentId,  String phase,  double progress)?  vaultUploadProgress,TResult Function( String serverId,  String contentId,  String channelId)?  vaultUploadComplete,TResult Function( String serverId,  String contentId,  String error)?  vaultUploadFailed,TResult Function( String serverId,  String contentId,  String phase,  double progress)?  vaultDownloadProgress,TResult Function( String serverId,  String contentId,  String diskPath)?  vaultDownloadComplete,TResult Function( String serverId,  String contentId,  String error)?  vaultDownloadFailed,TResult Function( String serverId,  int shardsToMove)?  rebalanceStarted,TResult Function( String serverId,  int moved,  int total)?  rebalanceProgress,TResult Function( String serverId)?  rebalanceCompleted,TResult Function( String serverId,  String contentId,  BigInt online,  BigInt needed)?  vaultUploadReplicationFallback,TResult Function( String peerId)?  keyExchangeStarted,TResult Function( String peerId,  String stage)?  keyExchangeProgress,TResult Function( String peerId,  String signalType,  String payload,  String connId)?  webRtcSignal,TResult Function( String peerId,  String transferId,  String filePath,  BigInt totalSize,  String kind,  int shardIndex)?  webRtcSendFile,required TResult orElse(),}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that.peerId);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared();case NetworkEvent_Listening() when listening != null:
return listening(_that.address);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that.fromPeer,_that.text,_that.timestamp,_that.messageId,_that.replyToMid);case NetworkEvent_ChannelMessageReceived() when channelMessageReceived != null:
return channelMessageReceived(_that.serverId,_that.channelId,_that.fromPeer,_that.text,_that.timestamp,_that.messageId,_that.replyToMid);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that.peerId);case NetworkEvent_Error() when error != null:
return error(_that.message);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that.serverId,_that.name);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that.serverId);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that.serverId,_that.channelId,_that.name);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that.serverId,_that.channelId);case NetworkEvent_ChannelRenamed() when channelRenamed != null:
return channelRenamed(_that.serverId,_that.channelId,_that.newName);case NetworkEvent_ServerDeleted() when serverDeleted != null:
return serverDeleted(_that.serverId);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that.serverId,_that.peerId);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that.serverId,_that.peerId);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that.serverId,_that.opsApplied);case NetworkEvent_ServerJoined() when serverJoined != null:
return serverJoined(_that.serverId,_that.name);case NetworkEvent_MessageSyncStarted() when messageSyncStarted != null:
return messageSyncStarted(_that.serverId,_that.peerId);case NetworkEvent_MessageSyncCompleted() when messageSyncCompleted != null:
return messageSyncCompleted(_that.serverId,_that.newMessageCount);case NetworkEvent_MessageSyncFailed() when messageSyncFailed != null:
return messageSyncFailed(_that.serverId,_that.error);case NetworkEvent_MessageSyncProgress() when messageSyncProgress != null:
return messageSyncProgress(_that.serverId,_that.channelId,_that.receivedCount,_that.totalCount);case NetworkEvent_RoleChanged() when roleChanged != null:
return roleChanged(_that.serverId,_that.peerId,_that.newRole);case NetworkEvent_DmSyncCompleted() when dmSyncCompleted != null:
return dmSyncCompleted(_that.peerId,_that.newMessageCount);case NetworkEvent_ProfileUpdated() when profileUpdated != null:
return profileUpdated(_that.peerId);case NetworkEvent_ChannelMessageEdited() when channelMessageEdited != null:
return channelMessageEdited(_that.serverId,_that.channelId,_that.messageId,_that.newText,_that.editedAt);case NetworkEvent_DmMessageEdited() when dmMessageEdited != null:
return dmMessageEdited(_that.peerId,_that.messageId,_that.newText,_that.editedAt);case NetworkEvent_ChannelMessageDeleted() when channelMessageDeleted != null:
return channelMessageDeleted(_that.serverId,_that.channelId,_that.messageId,_that.deletedAt);case NetworkEvent_DmMessageDeleted() when dmMessageDeleted != null:
return dmMessageDeleted(_that.peerId,_that.messageId,_that.deletedAt);case NetworkEvent_ChannelReactionAdded() when channelReactionAdded != null:
return channelReactionAdded(_that.serverId,_that.channelId,_that.messageId,_that.emoji,_that.reactor,_that.addedAt);case NetworkEvent_DmReactionAdded() when dmReactionAdded != null:
return dmReactionAdded(_that.peerId,_that.messageId,_that.emoji,_that.reactor,_that.addedAt);case NetworkEvent_ChannelReactionRemoved() when channelReactionRemoved != null:
return channelReactionRemoved(_that.serverId,_that.channelId,_that.messageId,_that.emoji,_that.reactor,_that.removedAt);case NetworkEvent_DmReactionRemoved() when dmReactionRemoved != null:
return dmReactionRemoved(_that.peerId,_that.messageId,_that.emoji,_that.reactor,_that.removedAt);case NetworkEvent_FriendRequestReceived() when friendRequestReceived != null:
return friendRequestReceived(_that.peerId);case NetworkEvent_FriendRequestAccepted() when friendRequestAccepted != null:
return friendRequestAccepted(_that.peerId);case NetworkEvent_FriendRequestRejected() when friendRequestRejected != null:
return friendRequestRejected(_that.peerId);case NetworkEvent_FriendRemoved() when friendRemoved != null:
return friendRemoved(_that.peerId);case NetworkEvent_TypingStarted() when typingStarted != null:
return typingStarted(_that.peerId,_that.serverId,_that.channelId);case NetworkEvent_MessagePinned() when messagePinned != null:
return messagePinned(_that.serverId,_that.channelId,_that.messageId);case NetworkEvent_MessageUnpinned() when messageUnpinned != null:
return messageUnpinned(_that.serverId,_that.channelId,_that.messageId);case NetworkEvent_FileHeaderReceived() when fileHeaderReceived != null:
return fileHeaderReceived(_that.fileId,_that.fileName,_that.sizeBytes,_that.isImage,_that.width,_that.height,_that.messageId,_that.senderId,_that.serverId,_that.channelId);case NetworkEvent_FileProgress() when fileProgress != null:
return fileProgress(_that.fileId,_that.chunksReceived,_that.totalChunks);case NetworkEvent_FileCompleted() when fileCompleted != null:
return fileCompleted(_that.fileId,_that.diskPath);case NetworkEvent_FileFailed() when fileFailed != null:
return fileFailed(_that.fileId,_that.error);case NetworkEvent_ShardStored() when shardStored != null:
return shardStored(_that.serverId,_that.contentId,_that.shardIndex,_that.fromPeer);case NetworkEvent_ShardStoreAckReceived() when shardStoreAckReceived != null:
return shardStoreAckReceived(_that.serverId,_that.contentId,_that.shardIndex,_that.success,_that.error);case NetworkEvent_ShardStoreFailed() when shardStoreFailed != null:
return shardStoreFailed(_that.serverId,_that.contentId,_that.shardIndex,_that.targetPeer,_that.error);case NetworkEvent_ShardDeleted() when shardDeleted != null:
return shardDeleted(_that.serverId,_that.contentId);case NetworkEvent_ShardReceived() when shardReceived != null:
return shardReceived(_that.serverId,_that.contentId,_that.shardIndex,_that.fromPeer);case NetworkEvent_ShardRequestFailed() when shardRequestFailed != null:
return shardRequestFailed(_that.serverId,_that.contentId,_that.shardIndex,_that.error);case NetworkEvent_VaultUploadProgress() when vaultUploadProgress != null:
return vaultUploadProgress(_that.serverId,_that.contentId,_that.phase,_that.progress);case NetworkEvent_VaultUploadComplete() when vaultUploadComplete != null:
return vaultUploadComplete(_that.serverId,_that.contentId,_that.channelId);case NetworkEvent_VaultUploadFailed() when vaultUploadFailed != null:
return vaultUploadFailed(_that.serverId,_that.contentId,_that.error);case NetworkEvent_VaultDownloadProgress() when vaultDownloadProgress != null:
return vaultDownloadProgress(_that.serverId,_that.contentId,_that.phase,_that.progress);case NetworkEvent_VaultDownloadComplete() when vaultDownloadComplete != null:
return vaultDownloadComplete(_that.serverId,_that.contentId,_that.diskPath);case NetworkEvent_VaultDownloadFailed() when vaultDownloadFailed != null:
return vaultDownloadFailed(_that.serverId,_that.contentId,_that.error);case NetworkEvent_RebalanceStarted() when rebalanceStarted != null:
return rebalanceStarted(_that.serverId,_that.shardsToMove);case NetworkEvent_RebalanceProgress() when rebalanceProgress != null:
return rebalanceProgress(_that.serverId,_that.moved,_that.total);case NetworkEvent_RebalanceCompleted() when rebalanceCompleted != null:
return rebalanceCompleted(_that.serverId);case NetworkEvent_VaultUploadReplicationFallback() when vaultUploadReplicationFallback != null:
return vaultUploadReplicationFallback(_that.serverId,_that.contentId,_that.online,_that.needed);case NetworkEvent_KeyExchangeStarted() when keyExchangeStarted != null:
return keyExchangeStarted(_that.peerId);case NetworkEvent_KeyExchangeProgress() when keyExchangeProgress != null:
return keyExchangeProgress(_that.peerId,_that.stage);case NetworkEvent_WebRtcSignal() when webRtcSignal != null:
return webRtcSignal(_that.peerId,_that.signalType,_that.payload,_that.connId);case NetworkEvent_WebRtcSendFile() when webRtcSendFile != null:
return webRtcSendFile(_that.peerId,_that.transferId,_that.filePath,_that.totalSize,_that.kind,_that.shardIndex);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( DiscoveredPeer peer)  peerDiscovered,required TResult Function( String peerId)  peerExpired,required TResult Function( String peerId)  peerDisconnected,required TResult Function()  roomCleared,required TResult Function( String address)  listening,required TResult Function( String fromPeer,  String text,  PlatformInt64 timestamp,  String messageId,  String replyToMid)  messageReceived,required TResult Function( String serverId,  String channelId,  String fromPeer,  String text,  PlatformInt64 timestamp,  String messageId,  String replyToMid)  channelMessageReceived,required TResult Function( String toPeer)  messageSent,required TResult Function( String toPeer,  String error)  messageSendFailed,required TResult Function( String peerId)  sessionEstablished,required TResult Function( String message)  error,required TResult Function( String serverId,  String name)  serverCreated,required TResult Function( String serverId)  serverUpdated,required TResult Function( String serverId,  String channelId,  String name)  channelAdded,required TResult Function( String serverId,  String channelId)  channelRemoved,required TResult Function( String serverId,  String channelId,  String newName)  channelRenamed,required TResult Function( String serverId)  serverDeleted,required TResult Function( String serverId,  String peerId)  memberJoined,required TResult Function( String serverId,  String peerId)  memberLeft,required TResult Function( String serverId,  int opsApplied)  syncCompleted,required TResult Function( String serverId,  String name)  serverJoined,required TResult Function( String serverId,  String peerId)  messageSyncStarted,required TResult Function( String serverId,  int newMessageCount)  messageSyncCompleted,required TResult Function( String serverId,  String error)  messageSyncFailed,required TResult Function( String serverId,  String channelId,  int receivedCount,  int totalCount)  messageSyncProgress,required TResult Function( String serverId,  String peerId,  String newRole)  roleChanged,required TResult Function( String peerId,  int newMessageCount)  dmSyncCompleted,required TResult Function( String peerId)  profileUpdated,required TResult Function( String serverId,  String channelId,  String messageId,  String newText,  PlatformInt64 editedAt)  channelMessageEdited,required TResult Function( String peerId,  String messageId,  String newText,  PlatformInt64 editedAt)  dmMessageEdited,required TResult Function( String serverId,  String channelId,  String messageId,  PlatformInt64 deletedAt)  channelMessageDeleted,required TResult Function( String peerId,  String messageId,  PlatformInt64 deletedAt)  dmMessageDeleted,required TResult Function( String serverId,  String channelId,  String messageId,  String emoji,  String reactor,  PlatformInt64 addedAt)  channelReactionAdded,required TResult Function( String peerId,  String messageId,  String emoji,  String reactor,  PlatformInt64 addedAt)  dmReactionAdded,required TResult Function( String serverId,  String channelId,  String messageId,  String emoji,  String reactor,  PlatformInt64 removedAt)  channelReactionRemoved,required TResult Function( String peerId,  String messageId,  String emoji,  String reactor,  PlatformInt64 removedAt)  dmReactionRemoved,required TResult Function( String peerId)  friendRequestReceived,required TResult Function( String peerId)  friendRequestAccepted,required TResult Function( String peerId)  friendRequestRejected,required TResult Function( String peerId)  friendRemoved,required TResult Function( String peerId,  String serverId,  String channelId)  typingStarted,required TResult Function( String serverId,  String channelId,  String messageId)  messagePinned,required TResult Function( String serverId,  String channelId,  String messageId)  messageUnpinned,required TResult Function( String fileId,  String fileName,  BigInt sizeBytes,  bool isImage,  int? width,  int? height,  String messageId,  String senderId,  String serverId,  String channelId)  fileHeaderReceived,required TResult Function( String fileId,  int chunksReceived,  int totalChunks)  fileProgress,required TResult Function( String fileId,  String diskPath)  fileCompleted,required TResult Function( String fileId,  String error)  fileFailed,required TResult Function( String serverId,  String contentId,  int shardIndex,  String fromPeer)  shardStored,required TResult Function( String serverId,  String contentId,  int shardIndex,  bool success,  String error)  shardStoreAckReceived,required TResult Function( String serverId,  String contentId,  int shardIndex,  String targetPeer,  String error)  shardStoreFailed,required TResult Function( String serverId,  String contentId)  shardDeleted,required TResult Function( String serverId,  String contentId,  int shardIndex,  String fromPeer)  shardReceived,required TResult Function( String serverId,  String contentId,  int shardIndex,  String error)  shardRequestFailed,required TResult Function( String serverId,  String contentId,  String phase,  double progress)  vaultUploadProgress,required TResult Function( String serverId,  String contentId,  String channelId)  vaultUploadComplete,required TResult Function( String serverId,  String contentId,  String error)  vaultUploadFailed,required TResult Function( String serverId,  String contentId,  String phase,  double progress)  vaultDownloadProgress,required TResult Function( String serverId,  String contentId,  String diskPath)  vaultDownloadComplete,required TResult Function( String serverId,  String contentId,  String error)  vaultDownloadFailed,required TResult Function( String serverId,  int shardsToMove)  rebalanceStarted,required TResult Function( String serverId,  int moved,  int total)  rebalanceProgress,required TResult Function( String serverId)  rebalanceCompleted,required TResult Function( String serverId,  String contentId,  BigInt online,  BigInt needed)  vaultUploadReplicationFallback,required TResult Function( String peerId)  keyExchangeStarted,required TResult Function( String peerId,  String stage)  keyExchangeProgress,required TResult Function( String peerId,  String signalType,  String payload,  String connId)  webRtcSignal,required TResult Function( String peerId,  String transferId,  String filePath,  BigInt totalSize,  String kind,  int shardIndex)  webRtcSendFile,}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered():
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired():
return peerExpired(_that.peerId);case NetworkEvent_PeerDisconnected():
return peerDisconnected(_that.peerId);case NetworkEvent_RoomCleared():
return roomCleared();case NetworkEvent_Listening():
return listening(_that.address);case NetworkEvent_MessageReceived():
return messageReceived(_that.fromPeer,_that.text,_that.timestamp,_that.messageId,_that.replyToMid);case NetworkEvent_ChannelMessageReceived():
return channelMessageReceived(_that.serverId,_that.channelId,_that.fromPeer,_that.text,_that.timestamp,_that.messageId,_that.replyToMid);case NetworkEvent_MessageSent():
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed():
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_SessionEstablished():
return sessionEstablished(_that.peerId);case NetworkEvent_Error():
return error(_that.message);case NetworkEvent_ServerCreated():
return serverCreated(_that.serverId,_that.name);case NetworkEvent_ServerUpdated():
return serverUpdated(_that.serverId);case NetworkEvent_ChannelAdded():
return channelAdded(_that.serverId,_that.channelId,_that.name);case NetworkEvent_ChannelRemoved():
return channelRemoved(_that.serverId,_that.channelId);case NetworkEvent_ChannelRenamed():
return channelRenamed(_that.serverId,_that.channelId,_that.newName);case NetworkEvent_ServerDeleted():
return serverDeleted(_that.serverId);case NetworkEvent_MemberJoined():
return memberJoined(_that.serverId,_that.peerId);case NetworkEvent_MemberLeft():
return memberLeft(_that.serverId,_that.peerId);case NetworkEvent_SyncCompleted():
return syncCompleted(_that.serverId,_that.opsApplied);case NetworkEvent_ServerJoined():
return serverJoined(_that.serverId,_that.name);case NetworkEvent_MessageSyncStarted():
return messageSyncStarted(_that.serverId,_that.peerId);case NetworkEvent_MessageSyncCompleted():
return messageSyncCompleted(_that.serverId,_that.newMessageCount);case NetworkEvent_MessageSyncFailed():
return messageSyncFailed(_that.serverId,_that.error);case NetworkEvent_MessageSyncProgress():
return messageSyncProgress(_that.serverId,_that.channelId,_that.receivedCount,_that.totalCount);case NetworkEvent_RoleChanged():
return roleChanged(_that.serverId,_that.peerId,_that.newRole);case NetworkEvent_DmSyncCompleted():
return dmSyncCompleted(_that.peerId,_that.newMessageCount);case NetworkEvent_ProfileUpdated():
return profileUpdated(_that.peerId);case NetworkEvent_ChannelMessageEdited():
return channelMessageEdited(_that.serverId,_that.channelId,_that.messageId,_that.newText,_that.editedAt);case NetworkEvent_DmMessageEdited():
return dmMessageEdited(_that.peerId,_that.messageId,_that.newText,_that.editedAt);case NetworkEvent_ChannelMessageDeleted():
return channelMessageDeleted(_that.serverId,_that.channelId,_that.messageId,_that.deletedAt);case NetworkEvent_DmMessageDeleted():
return dmMessageDeleted(_that.peerId,_that.messageId,_that.deletedAt);case NetworkEvent_ChannelReactionAdded():
return channelReactionAdded(_that.serverId,_that.channelId,_that.messageId,_that.emoji,_that.reactor,_that.addedAt);case NetworkEvent_DmReactionAdded():
return dmReactionAdded(_that.peerId,_that.messageId,_that.emoji,_that.reactor,_that.addedAt);case NetworkEvent_ChannelReactionRemoved():
return channelReactionRemoved(_that.serverId,_that.channelId,_that.messageId,_that.emoji,_that.reactor,_that.removedAt);case NetworkEvent_DmReactionRemoved():
return dmReactionRemoved(_that.peerId,_that.messageId,_that.emoji,_that.reactor,_that.removedAt);case NetworkEvent_FriendRequestReceived():
return friendRequestReceived(_that.peerId);case NetworkEvent_FriendRequestAccepted():
return friendRequestAccepted(_that.peerId);case NetworkEvent_FriendRequestRejected():
return friendRequestRejected(_that.peerId);case NetworkEvent_FriendRemoved():
return friendRemoved(_that.peerId);case NetworkEvent_TypingStarted():
return typingStarted(_that.peerId,_that.serverId,_that.channelId);case NetworkEvent_MessagePinned():
return messagePinned(_that.serverId,_that.channelId,_that.messageId);case NetworkEvent_MessageUnpinned():
return messageUnpinned(_that.serverId,_that.channelId,_that.messageId);case NetworkEvent_FileHeaderReceived():
return fileHeaderReceived(_that.fileId,_that.fileName,_that.sizeBytes,_that.isImage,_that.width,_that.height,_that.messageId,_that.senderId,_that.serverId,_that.channelId);case NetworkEvent_FileProgress():
return fileProgress(_that.fileId,_that.chunksReceived,_that.totalChunks);case NetworkEvent_FileCompleted():
return fileCompleted(_that.fileId,_that.diskPath);case NetworkEvent_FileFailed():
return fileFailed(_that.fileId,_that.error);case NetworkEvent_ShardStored():
return shardStored(_that.serverId,_that.contentId,_that.shardIndex,_that.fromPeer);case NetworkEvent_ShardStoreAckReceived():
return shardStoreAckReceived(_that.serverId,_that.contentId,_that.shardIndex,_that.success,_that.error);case NetworkEvent_ShardStoreFailed():
return shardStoreFailed(_that.serverId,_that.contentId,_that.shardIndex,_that.targetPeer,_that.error);case NetworkEvent_ShardDeleted():
return shardDeleted(_that.serverId,_that.contentId);case NetworkEvent_ShardReceived():
return shardReceived(_that.serverId,_that.contentId,_that.shardIndex,_that.fromPeer);case NetworkEvent_ShardRequestFailed():
return shardRequestFailed(_that.serverId,_that.contentId,_that.shardIndex,_that.error);case NetworkEvent_VaultUploadProgress():
return vaultUploadProgress(_that.serverId,_that.contentId,_that.phase,_that.progress);case NetworkEvent_VaultUploadComplete():
return vaultUploadComplete(_that.serverId,_that.contentId,_that.channelId);case NetworkEvent_VaultUploadFailed():
return vaultUploadFailed(_that.serverId,_that.contentId,_that.error);case NetworkEvent_VaultDownloadProgress():
return vaultDownloadProgress(_that.serverId,_that.contentId,_that.phase,_that.progress);case NetworkEvent_VaultDownloadComplete():
return vaultDownloadComplete(_that.serverId,_that.contentId,_that.diskPath);case NetworkEvent_VaultDownloadFailed():
return vaultDownloadFailed(_that.serverId,_that.contentId,_that.error);case NetworkEvent_RebalanceStarted():
return rebalanceStarted(_that.serverId,_that.shardsToMove);case NetworkEvent_RebalanceProgress():
return rebalanceProgress(_that.serverId,_that.moved,_that.total);case NetworkEvent_RebalanceCompleted():
return rebalanceCompleted(_that.serverId);case NetworkEvent_VaultUploadReplicationFallback():
return vaultUploadReplicationFallback(_that.serverId,_that.contentId,_that.online,_that.needed);case NetworkEvent_KeyExchangeStarted():
return keyExchangeStarted(_that.peerId);case NetworkEvent_KeyExchangeProgress():
return keyExchangeProgress(_that.peerId,_that.stage);case NetworkEvent_WebRtcSignal():
return webRtcSignal(_that.peerId,_that.signalType,_that.payload,_that.connId);case NetworkEvent_WebRtcSendFile():
return webRtcSendFile(_that.peerId,_that.transferId,_that.filePath,_that.totalSize,_that.kind,_that.shardIndex);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( DiscoveredPeer peer)?  peerDiscovered,TResult? Function( String peerId)?  peerExpired,TResult? Function( String peerId)?  peerDisconnected,TResult? Function()?  roomCleared,TResult? Function( String address)?  listening,TResult? Function( String fromPeer,  String text,  PlatformInt64 timestamp,  String messageId,  String replyToMid)?  messageReceived,TResult? Function( String serverId,  String channelId,  String fromPeer,  String text,  PlatformInt64 timestamp,  String messageId,  String replyToMid)?  channelMessageReceived,TResult? Function( String toPeer)?  messageSent,TResult? Function( String toPeer,  String error)?  messageSendFailed,TResult? Function( String peerId)?  sessionEstablished,TResult? Function( String message)?  error,TResult? Function( String serverId,  String name)?  serverCreated,TResult? Function( String serverId)?  serverUpdated,TResult? Function( String serverId,  String channelId,  String name)?  channelAdded,TResult? Function( String serverId,  String channelId)?  channelRemoved,TResult? Function( String serverId,  String channelId,  String newName)?  channelRenamed,TResult? Function( String serverId)?  serverDeleted,TResult? Function( String serverId,  String peerId)?  memberJoined,TResult? Function( String serverId,  String peerId)?  memberLeft,TResult? Function( String serverId,  int opsApplied)?  syncCompleted,TResult? Function( String serverId,  String name)?  serverJoined,TResult? Function( String serverId,  String peerId)?  messageSyncStarted,TResult? Function( String serverId,  int newMessageCount)?  messageSyncCompleted,TResult? Function( String serverId,  String error)?  messageSyncFailed,TResult? Function( String serverId,  String channelId,  int receivedCount,  int totalCount)?  messageSyncProgress,TResult? Function( String serverId,  String peerId,  String newRole)?  roleChanged,TResult? Function( String peerId,  int newMessageCount)?  dmSyncCompleted,TResult? Function( String peerId)?  profileUpdated,TResult? Function( String serverId,  String channelId,  String messageId,  String newText,  PlatformInt64 editedAt)?  channelMessageEdited,TResult? Function( String peerId,  String messageId,  String newText,  PlatformInt64 editedAt)?  dmMessageEdited,TResult? Function( String serverId,  String channelId,  String messageId,  PlatformInt64 deletedAt)?  channelMessageDeleted,TResult? Function( String peerId,  String messageId,  PlatformInt64 deletedAt)?  dmMessageDeleted,TResult? Function( String serverId,  String channelId,  String messageId,  String emoji,  String reactor,  PlatformInt64 addedAt)?  channelReactionAdded,TResult? Function( String peerId,  String messageId,  String emoji,  String reactor,  PlatformInt64 addedAt)?  dmReactionAdded,TResult? Function( String serverId,  String channelId,  String messageId,  String emoji,  String reactor,  PlatformInt64 removedAt)?  channelReactionRemoved,TResult? Function( String peerId,  String messageId,  String emoji,  String reactor,  PlatformInt64 removedAt)?  dmReactionRemoved,TResult? Function( String peerId)?  friendRequestReceived,TResult? Function( String peerId)?  friendRequestAccepted,TResult? Function( String peerId)?  friendRequestRejected,TResult? Function( String peerId)?  friendRemoved,TResult? Function( String peerId,  String serverId,  String channelId)?  typingStarted,TResult? Function( String serverId,  String channelId,  String messageId)?  messagePinned,TResult? Function( String serverId,  String channelId,  String messageId)?  messageUnpinned,TResult? Function( String fileId,  String fileName,  BigInt sizeBytes,  bool isImage,  int? width,  int? height,  String messageId,  String senderId,  String serverId,  String channelId)?  fileHeaderReceived,TResult? Function( String fileId,  int chunksReceived,  int totalChunks)?  fileProgress,TResult? Function( String fileId,  String diskPath)?  fileCompleted,TResult? Function( String fileId,  String error)?  fileFailed,TResult? Function( String serverId,  String contentId,  int shardIndex,  String fromPeer)?  shardStored,TResult? Function( String serverId,  String contentId,  int shardIndex,  bool success,  String error)?  shardStoreAckReceived,TResult? Function( String serverId,  String contentId,  int shardIndex,  String targetPeer,  String error)?  shardStoreFailed,TResult? Function( String serverId,  String contentId)?  shardDeleted,TResult? Function( String serverId,  String contentId,  int shardIndex,  String fromPeer)?  shardReceived,TResult? Function( String serverId,  String contentId,  int shardIndex,  String error)?  shardRequestFailed,TResult? Function( String serverId,  String contentId,  String phase,  double progress)?  vaultUploadProgress,TResult? Function( String serverId,  String contentId,  String channelId)?  vaultUploadComplete,TResult? Function( String serverId,  String contentId,  String error)?  vaultUploadFailed,TResult? Function( String serverId,  String contentId,  String phase,  double progress)?  vaultDownloadProgress,TResult? Function( String serverId,  String contentId,  String diskPath)?  vaultDownloadComplete,TResult? Function( String serverId,  String contentId,  String error)?  vaultDownloadFailed,TResult? Function( String serverId,  int shardsToMove)?  rebalanceStarted,TResult? Function( String serverId,  int moved,  int total)?  rebalanceProgress,TResult? Function( String serverId)?  rebalanceCompleted,TResult? Function( String serverId,  String contentId,  BigInt online,  BigInt needed)?  vaultUploadReplicationFallback,TResult? Function( String peerId)?  keyExchangeStarted,TResult? Function( String peerId,  String stage)?  keyExchangeProgress,TResult? Function( String peerId,  String signalType,  String payload,  String connId)?  webRtcSignal,TResult? Function( String peerId,  String transferId,  String filePath,  BigInt totalSize,  String kind,  int shardIndex)?  webRtcSendFile,}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that.peerId);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared();case NetworkEvent_Listening() when listening != null:
return listening(_that.address);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that.fromPeer,_that.text,_that.timestamp,_that.messageId,_that.replyToMid);case NetworkEvent_ChannelMessageReceived() when channelMessageReceived != null:
return channelMessageReceived(_that.serverId,_that.channelId,_that.fromPeer,_that.text,_that.timestamp,_that.messageId,_that.replyToMid);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that.peerId);case NetworkEvent_Error() when error != null:
return error(_that.message);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that.serverId,_that.name);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that.serverId);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that.serverId,_that.channelId,_that.name);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that.serverId,_that.channelId);case NetworkEvent_ChannelRenamed() when channelRenamed != null:
return channelRenamed(_that.serverId,_that.channelId,_that.newName);case NetworkEvent_ServerDeleted() when serverDeleted != null:
return serverDeleted(_that.serverId);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that.serverId,_that.peerId);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that.serverId,_that.peerId);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that.serverId,_that.opsApplied);case NetworkEvent_ServerJoined() when serverJoined != null:
return serverJoined(_that.serverId,_that.name);case NetworkEvent_MessageSyncStarted() when messageSyncStarted != null:
return messageSyncStarted(_that.serverId,_that.peerId);case NetworkEvent_MessageSyncCompleted() when messageSyncCompleted != null:
return messageSyncCompleted(_that.serverId,_that.newMessageCount);case NetworkEvent_MessageSyncFailed() when messageSyncFailed != null:
return messageSyncFailed(_that.serverId,_that.error);case NetworkEvent_MessageSyncProgress() when messageSyncProgress != null:
return messageSyncProgress(_that.serverId,_that.channelId,_that.receivedCount,_that.totalCount);case NetworkEvent_RoleChanged() when roleChanged != null:
return roleChanged(_that.serverId,_that.peerId,_that.newRole);case NetworkEvent_DmSyncCompleted() when dmSyncCompleted != null:
return dmSyncCompleted(_that.peerId,_that.newMessageCount);case NetworkEvent_ProfileUpdated() when profileUpdated != null:
return profileUpdated(_that.peerId);case NetworkEvent_ChannelMessageEdited() when channelMessageEdited != null:
return channelMessageEdited(_that.serverId,_that.channelId,_that.messageId,_that.newText,_that.editedAt);case NetworkEvent_DmMessageEdited() when dmMessageEdited != null:
return dmMessageEdited(_that.peerId,_that.messageId,_that.newText,_that.editedAt);case NetworkEvent_ChannelMessageDeleted() when channelMessageDeleted != null:
return channelMessageDeleted(_that.serverId,_that.channelId,_that.messageId,_that.deletedAt);case NetworkEvent_DmMessageDeleted() when dmMessageDeleted != null:
return dmMessageDeleted(_that.peerId,_that.messageId,_that.deletedAt);case NetworkEvent_ChannelReactionAdded() when channelReactionAdded != null:
return channelReactionAdded(_that.serverId,_that.channelId,_that.messageId,_that.emoji,_that.reactor,_that.addedAt);case NetworkEvent_DmReactionAdded() when dmReactionAdded != null:
return dmReactionAdded(_that.peerId,_that.messageId,_that.emoji,_that.reactor,_that.addedAt);case NetworkEvent_ChannelReactionRemoved() when channelReactionRemoved != null:
return channelReactionRemoved(_that.serverId,_that.channelId,_that.messageId,_that.emoji,_that.reactor,_that.removedAt);case NetworkEvent_DmReactionRemoved() when dmReactionRemoved != null:
return dmReactionRemoved(_that.peerId,_that.messageId,_that.emoji,_that.reactor,_that.removedAt);case NetworkEvent_FriendRequestReceived() when friendRequestReceived != null:
return friendRequestReceived(_that.peerId);case NetworkEvent_FriendRequestAccepted() when friendRequestAccepted != null:
return friendRequestAccepted(_that.peerId);case NetworkEvent_FriendRequestRejected() when friendRequestRejected != null:
return friendRequestRejected(_that.peerId);case NetworkEvent_FriendRemoved() when friendRemoved != null:
return friendRemoved(_that.peerId);case NetworkEvent_TypingStarted() when typingStarted != null:
return typingStarted(_that.peerId,_that.serverId,_that.channelId);case NetworkEvent_MessagePinned() when messagePinned != null:
return messagePinned(_that.serverId,_that.channelId,_that.messageId);case NetworkEvent_MessageUnpinned() when messageUnpinned != null:
return messageUnpinned(_that.serverId,_that.channelId,_that.messageId);case NetworkEvent_FileHeaderReceived() when fileHeaderReceived != null:
return fileHeaderReceived(_that.fileId,_that.fileName,_that.sizeBytes,_that.isImage,_that.width,_that.height,_that.messageId,_that.senderId,_that.serverId,_that.channelId);case NetworkEvent_FileProgress() when fileProgress != null:
return fileProgress(_that.fileId,_that.chunksReceived,_that.totalChunks);case NetworkEvent_FileCompleted() when fileCompleted != null:
return fileCompleted(_that.fileId,_that.diskPath);case NetworkEvent_FileFailed() when fileFailed != null:
return fileFailed(_that.fileId,_that.error);case NetworkEvent_ShardStored() when shardStored != null:
return shardStored(_that.serverId,_that.contentId,_that.shardIndex,_that.fromPeer);case NetworkEvent_ShardStoreAckReceived() when shardStoreAckReceived != null:
return shardStoreAckReceived(_that.serverId,_that.contentId,_that.shardIndex,_that.success,_that.error);case NetworkEvent_ShardStoreFailed() when shardStoreFailed != null:
return shardStoreFailed(_that.serverId,_that.contentId,_that.shardIndex,_that.targetPeer,_that.error);case NetworkEvent_ShardDeleted() when shardDeleted != null:
return shardDeleted(_that.serverId,_that.contentId);case NetworkEvent_ShardReceived() when shardReceived != null:
return shardReceived(_that.serverId,_that.contentId,_that.shardIndex,_that.fromPeer);case NetworkEvent_ShardRequestFailed() when shardRequestFailed != null:
return shardRequestFailed(_that.serverId,_that.contentId,_that.shardIndex,_that.error);case NetworkEvent_VaultUploadProgress() when vaultUploadProgress != null:
return vaultUploadProgress(_that.serverId,_that.contentId,_that.phase,_that.progress);case NetworkEvent_VaultUploadComplete() when vaultUploadComplete != null:
return vaultUploadComplete(_that.serverId,_that.contentId,_that.channelId);case NetworkEvent_VaultUploadFailed() when vaultUploadFailed != null:
return vaultUploadFailed(_that.serverId,_that.contentId,_that.error);case NetworkEvent_VaultDownloadProgress() when vaultDownloadProgress != null:
return vaultDownloadProgress(_that.serverId,_that.contentId,_that.phase,_that.progress);case NetworkEvent_VaultDownloadComplete() when vaultDownloadComplete != null:
return vaultDownloadComplete(_that.serverId,_that.contentId,_that.diskPath);case NetworkEvent_VaultDownloadFailed() when vaultDownloadFailed != null:
return vaultDownloadFailed(_that.serverId,_that.contentId,_that.error);case NetworkEvent_RebalanceStarted() when rebalanceStarted != null:
return rebalanceStarted(_that.serverId,_that.shardsToMove);case NetworkEvent_RebalanceProgress() when rebalanceProgress != null:
return rebalanceProgress(_that.serverId,_that.moved,_that.total);case NetworkEvent_RebalanceCompleted() when rebalanceCompleted != null:
return rebalanceCompleted(_that.serverId);case NetworkEvent_VaultUploadReplicationFallback() when vaultUploadReplicationFallback != null:
return vaultUploadReplicationFallback(_that.serverId,_that.contentId,_that.online,_that.needed);case NetworkEvent_KeyExchangeStarted() when keyExchangeStarted != null:
return keyExchangeStarted(_that.peerId);case NetworkEvent_KeyExchangeProgress() when keyExchangeProgress != null:
return keyExchangeProgress(_that.peerId,_that.stage);case NetworkEvent_WebRtcSignal() when webRtcSignal != null:
return webRtcSignal(_that.peerId,_that.signalType,_that.payload,_that.connId);case NetworkEvent_WebRtcSendFile() when webRtcSendFile != null:
return webRtcSendFile(_that.peerId,_that.transferId,_that.filePath,_that.totalSize,_that.kind,_that.shardIndex);case _:
  return null;

}
}

}

/// @nodoc


class NetworkEvent_PeerDiscovered extends NetworkEvent {
  const NetworkEvent_PeerDiscovered({required this.peer}): super._();
  

 final  DiscoveredPeer peer;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_PeerDiscoveredCopyWith<NetworkEvent_PeerDiscovered> get copyWith => _$NetworkEvent_PeerDiscoveredCopyWithImpl<NetworkEvent_PeerDiscovered>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_PeerDiscovered&&(identical(other.peer, peer) || other.peer == peer));
}


@override
int get hashCode => Object.hash(runtimeType,peer);

@override
String toString() {
  return 'NetworkEvent.peerDiscovered(peer: $peer)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_PeerDiscoveredCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_PeerDiscoveredCopyWith(NetworkEvent_PeerDiscovered value, $Res Function(NetworkEvent_PeerDiscovered) _then) = _$NetworkEvent_PeerDiscoveredCopyWithImpl;
@useResult
$Res call({
 DiscoveredPeer peer
});




}
/// @nodoc
class _$NetworkEvent_PeerDiscoveredCopyWithImpl<$Res>
    implements $NetworkEvent_PeerDiscoveredCopyWith<$Res> {
  _$NetworkEvent_PeerDiscoveredCopyWithImpl(this._self, this._then);

  final NetworkEvent_PeerDiscovered _self;
  final $Res Function(NetworkEvent_PeerDiscovered) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peer = null,}) {
  return _then(NetworkEvent_PeerDiscovered(
peer: null == peer ? _self.peer : peer // ignore: cast_nullable_to_non_nullable
as DiscoveredPeer,
  ));
}


}

/// @nodoc


class NetworkEvent_PeerExpired extends NetworkEvent {
  const NetworkEvent_PeerExpired({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_PeerExpiredCopyWith<NetworkEvent_PeerExpired> get copyWith => _$NetworkEvent_PeerExpiredCopyWithImpl<NetworkEvent_PeerExpired>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_PeerExpired&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.peerExpired(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_PeerExpiredCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_PeerExpiredCopyWith(NetworkEvent_PeerExpired value, $Res Function(NetworkEvent_PeerExpired) _then) = _$NetworkEvent_PeerExpiredCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_PeerExpiredCopyWithImpl<$Res>
    implements $NetworkEvent_PeerExpiredCopyWith<$Res> {
  _$NetworkEvent_PeerExpiredCopyWithImpl(this._self, this._then);

  final NetworkEvent_PeerExpired _self;
  final $Res Function(NetworkEvent_PeerExpired) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_PeerExpired(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_PeerDisconnected extends NetworkEvent {
  const NetworkEvent_PeerDisconnected({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_PeerDisconnectedCopyWith<NetworkEvent_PeerDisconnected> get copyWith => _$NetworkEvent_PeerDisconnectedCopyWithImpl<NetworkEvent_PeerDisconnected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_PeerDisconnected&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.peerDisconnected(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_PeerDisconnectedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_PeerDisconnectedCopyWith(NetworkEvent_PeerDisconnected value, $Res Function(NetworkEvent_PeerDisconnected) _then) = _$NetworkEvent_PeerDisconnectedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_PeerDisconnectedCopyWithImpl<$Res>
    implements $NetworkEvent_PeerDisconnectedCopyWith<$Res> {
  _$NetworkEvent_PeerDisconnectedCopyWithImpl(this._self, this._then);

  final NetworkEvent_PeerDisconnected _self;
  final $Res Function(NetworkEvent_PeerDisconnected) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_PeerDisconnected(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_RoomCleared extends NetworkEvent {
  const NetworkEvent_RoomCleared(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_RoomCleared);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'NetworkEvent.roomCleared()';
}


}




/// @nodoc


class NetworkEvent_Listening extends NetworkEvent {
  const NetworkEvent_Listening({required this.address}): super._();
  

 final  String address;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ListeningCopyWith<NetworkEvent_Listening> get copyWith => _$NetworkEvent_ListeningCopyWithImpl<NetworkEvent_Listening>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_Listening&&(identical(other.address, address) || other.address == address));
}


@override
int get hashCode => Object.hash(runtimeType,address);

@override
String toString() {
  return 'NetworkEvent.listening(address: $address)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ListeningCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ListeningCopyWith(NetworkEvent_Listening value, $Res Function(NetworkEvent_Listening) _then) = _$NetworkEvent_ListeningCopyWithImpl;
@useResult
$Res call({
 String address
});




}
/// @nodoc
class _$NetworkEvent_ListeningCopyWithImpl<$Res>
    implements $NetworkEvent_ListeningCopyWith<$Res> {
  _$NetworkEvent_ListeningCopyWithImpl(this._self, this._then);

  final NetworkEvent_Listening _self;
  final $Res Function(NetworkEvent_Listening) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? address = null,}) {
  return _then(NetworkEvent_Listening(
address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageReceived extends NetworkEvent {
  const NetworkEvent_MessageReceived({required this.fromPeer, required this.text, required this.timestamp, required this.messageId, required this.replyToMid}): super._();
  

 final  String fromPeer;
 final  String text;
 final  PlatformInt64 timestamp;
 final  String messageId;
 final  String replyToMid;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageReceivedCopyWith<NetworkEvent_MessageReceived> get copyWith => _$NetworkEvent_MessageReceivedCopyWithImpl<NetworkEvent_MessageReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageReceived&&(identical(other.fromPeer, fromPeer) || other.fromPeer == fromPeer)&&(identical(other.text, text) || other.text == text)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.replyToMid, replyToMid) || other.replyToMid == replyToMid));
}


@override
int get hashCode => Object.hash(runtimeType,fromPeer,text,timestamp,messageId,replyToMid);

@override
String toString() {
  return 'NetworkEvent.messageReceived(fromPeer: $fromPeer, text: $text, timestamp: $timestamp, messageId: $messageId, replyToMid: $replyToMid)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageReceivedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageReceivedCopyWith(NetworkEvent_MessageReceived value, $Res Function(NetworkEvent_MessageReceived) _then) = _$NetworkEvent_MessageReceivedCopyWithImpl;
@useResult
$Res call({
 String fromPeer, String text, PlatformInt64 timestamp, String messageId, String replyToMid
});




}
/// @nodoc
class _$NetworkEvent_MessageReceivedCopyWithImpl<$Res>
    implements $NetworkEvent_MessageReceivedCopyWith<$Res> {
  _$NetworkEvent_MessageReceivedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageReceived _self;
  final $Res Function(NetworkEvent_MessageReceived) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fromPeer = null,Object? text = null,Object? timestamp = null,Object? messageId = null,Object? replyToMid = null,}) {
  return _then(NetworkEvent_MessageReceived(
fromPeer: null == fromPeer ? _self.fromPeer : fromPeer // ignore: cast_nullable_to_non_nullable
as String,text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as PlatformInt64,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,replyToMid: null == replyToMid ? _self.replyToMid : replyToMid // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelMessageReceived extends NetworkEvent {
  const NetworkEvent_ChannelMessageReceived({required this.serverId, required this.channelId, required this.fromPeer, required this.text, required this.timestamp, required this.messageId, required this.replyToMid}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String fromPeer;
 final  String text;
 final  PlatformInt64 timestamp;
 final  String messageId;
 final  String replyToMid;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelMessageReceivedCopyWith<NetworkEvent_ChannelMessageReceived> get copyWith => _$NetworkEvent_ChannelMessageReceivedCopyWithImpl<NetworkEvent_ChannelMessageReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelMessageReceived&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.fromPeer, fromPeer) || other.fromPeer == fromPeer)&&(identical(other.text, text) || other.text == text)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.replyToMid, replyToMid) || other.replyToMid == replyToMid));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,fromPeer,text,timestamp,messageId,replyToMid);

@override
String toString() {
  return 'NetworkEvent.channelMessageReceived(serverId: $serverId, channelId: $channelId, fromPeer: $fromPeer, text: $text, timestamp: $timestamp, messageId: $messageId, replyToMid: $replyToMid)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelMessageReceivedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelMessageReceivedCopyWith(NetworkEvent_ChannelMessageReceived value, $Res Function(NetworkEvent_ChannelMessageReceived) _then) = _$NetworkEvent_ChannelMessageReceivedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String fromPeer, String text, PlatformInt64 timestamp, String messageId, String replyToMid
});




}
/// @nodoc
class _$NetworkEvent_ChannelMessageReceivedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelMessageReceivedCopyWith<$Res> {
  _$NetworkEvent_ChannelMessageReceivedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelMessageReceived _self;
  final $Res Function(NetworkEvent_ChannelMessageReceived) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? fromPeer = null,Object? text = null,Object? timestamp = null,Object? messageId = null,Object? replyToMid = null,}) {
  return _then(NetworkEvent_ChannelMessageReceived(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,fromPeer: null == fromPeer ? _self.fromPeer : fromPeer // ignore: cast_nullable_to_non_nullable
as String,text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as PlatformInt64,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,replyToMid: null == replyToMid ? _self.replyToMid : replyToMid // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageSent extends NetworkEvent {
  const NetworkEvent_MessageSent({required this.toPeer}): super._();
  

 final  String toPeer;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageSentCopyWith<NetworkEvent_MessageSent> get copyWith => _$NetworkEvent_MessageSentCopyWithImpl<NetworkEvent_MessageSent>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageSent&&(identical(other.toPeer, toPeer) || other.toPeer == toPeer));
}


@override
int get hashCode => Object.hash(runtimeType,toPeer);

@override
String toString() {
  return 'NetworkEvent.messageSent(toPeer: $toPeer)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageSentCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageSentCopyWith(NetworkEvent_MessageSent value, $Res Function(NetworkEvent_MessageSent) _then) = _$NetworkEvent_MessageSentCopyWithImpl;
@useResult
$Res call({
 String toPeer
});




}
/// @nodoc
class _$NetworkEvent_MessageSentCopyWithImpl<$Res>
    implements $NetworkEvent_MessageSentCopyWith<$Res> {
  _$NetworkEvent_MessageSentCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageSent _self;
  final $Res Function(NetworkEvent_MessageSent) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? toPeer = null,}) {
  return _then(NetworkEvent_MessageSent(
toPeer: null == toPeer ? _self.toPeer : toPeer // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageSendFailed extends NetworkEvent {
  const NetworkEvent_MessageSendFailed({required this.toPeer, required this.error}): super._();
  

 final  String toPeer;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageSendFailedCopyWith<NetworkEvent_MessageSendFailed> get copyWith => _$NetworkEvent_MessageSendFailedCopyWithImpl<NetworkEvent_MessageSendFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageSendFailed&&(identical(other.toPeer, toPeer) || other.toPeer == toPeer)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,toPeer,error);

@override
String toString() {
  return 'NetworkEvent.messageSendFailed(toPeer: $toPeer, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageSendFailedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageSendFailedCopyWith(NetworkEvent_MessageSendFailed value, $Res Function(NetworkEvent_MessageSendFailed) _then) = _$NetworkEvent_MessageSendFailedCopyWithImpl;
@useResult
$Res call({
 String toPeer, String error
});




}
/// @nodoc
class _$NetworkEvent_MessageSendFailedCopyWithImpl<$Res>
    implements $NetworkEvent_MessageSendFailedCopyWith<$Res> {
  _$NetworkEvent_MessageSendFailedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageSendFailed _self;
  final $Res Function(NetworkEvent_MessageSendFailed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? toPeer = null,Object? error = null,}) {
  return _then(NetworkEvent_MessageSendFailed(
toPeer: null == toPeer ? _self.toPeer : toPeer // ignore: cast_nullable_to_non_nullable
as String,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_SessionEstablished extends NetworkEvent {
  const NetworkEvent_SessionEstablished({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_SessionEstablishedCopyWith<NetworkEvent_SessionEstablished> get copyWith => _$NetworkEvent_SessionEstablishedCopyWithImpl<NetworkEvent_SessionEstablished>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_SessionEstablished&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.sessionEstablished(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_SessionEstablishedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_SessionEstablishedCopyWith(NetworkEvent_SessionEstablished value, $Res Function(NetworkEvent_SessionEstablished) _then) = _$NetworkEvent_SessionEstablishedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_SessionEstablishedCopyWithImpl<$Res>
    implements $NetworkEvent_SessionEstablishedCopyWith<$Res> {
  _$NetworkEvent_SessionEstablishedCopyWithImpl(this._self, this._then);

  final NetworkEvent_SessionEstablished _self;
  final $Res Function(NetworkEvent_SessionEstablished) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_SessionEstablished(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_Error extends NetworkEvent {
  const NetworkEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ErrorCopyWith<NetworkEvent_Error> get copyWith => _$NetworkEvent_ErrorCopyWithImpl<NetworkEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'NetworkEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ErrorCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ErrorCopyWith(NetworkEvent_Error value, $Res Function(NetworkEvent_Error) _then) = _$NetworkEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$NetworkEvent_ErrorCopyWithImpl<$Res>
    implements $NetworkEvent_ErrorCopyWith<$Res> {
  _$NetworkEvent_ErrorCopyWithImpl(this._self, this._then);

  final NetworkEvent_Error _self;
  final $Res Function(NetworkEvent_Error) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(NetworkEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ServerCreated extends NetworkEvent {
  const NetworkEvent_ServerCreated({required this.serverId, required this.name}): super._();
  

 final  String serverId;
 final  String name;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ServerCreatedCopyWith<NetworkEvent_ServerCreated> get copyWith => _$NetworkEvent_ServerCreatedCopyWithImpl<NetworkEvent_ServerCreated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ServerCreated&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.name, name) || other.name == name));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,name);

@override
String toString() {
  return 'NetworkEvent.serverCreated(serverId: $serverId, name: $name)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ServerCreatedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ServerCreatedCopyWith(NetworkEvent_ServerCreated value, $Res Function(NetworkEvent_ServerCreated) _then) = _$NetworkEvent_ServerCreatedCopyWithImpl;
@useResult
$Res call({
 String serverId, String name
});




}
/// @nodoc
class _$NetworkEvent_ServerCreatedCopyWithImpl<$Res>
    implements $NetworkEvent_ServerCreatedCopyWith<$Res> {
  _$NetworkEvent_ServerCreatedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ServerCreated _self;
  final $Res Function(NetworkEvent_ServerCreated) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? name = null,}) {
  return _then(NetworkEvent_ServerCreated(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ServerUpdated extends NetworkEvent {
  const NetworkEvent_ServerUpdated({required this.serverId}): super._();
  

 final  String serverId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ServerUpdatedCopyWith<NetworkEvent_ServerUpdated> get copyWith => _$NetworkEvent_ServerUpdatedCopyWithImpl<NetworkEvent_ServerUpdated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ServerUpdated&&(identical(other.serverId, serverId) || other.serverId == serverId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId);

@override
String toString() {
  return 'NetworkEvent.serverUpdated(serverId: $serverId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ServerUpdatedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ServerUpdatedCopyWith(NetworkEvent_ServerUpdated value, $Res Function(NetworkEvent_ServerUpdated) _then) = _$NetworkEvent_ServerUpdatedCopyWithImpl;
@useResult
$Res call({
 String serverId
});




}
/// @nodoc
class _$NetworkEvent_ServerUpdatedCopyWithImpl<$Res>
    implements $NetworkEvent_ServerUpdatedCopyWith<$Res> {
  _$NetworkEvent_ServerUpdatedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ServerUpdated _self;
  final $Res Function(NetworkEvent_ServerUpdated) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,}) {
  return _then(NetworkEvent_ServerUpdated(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelAdded extends NetworkEvent {
  const NetworkEvent_ChannelAdded({required this.serverId, required this.channelId, required this.name}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String name;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelAddedCopyWith<NetworkEvent_ChannelAdded> get copyWith => _$NetworkEvent_ChannelAddedCopyWithImpl<NetworkEvent_ChannelAdded>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelAdded&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.name, name) || other.name == name));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,name);

@override
String toString() {
  return 'NetworkEvent.channelAdded(serverId: $serverId, channelId: $channelId, name: $name)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelAddedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelAddedCopyWith(NetworkEvent_ChannelAdded value, $Res Function(NetworkEvent_ChannelAdded) _then) = _$NetworkEvent_ChannelAddedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String name
});




}
/// @nodoc
class _$NetworkEvent_ChannelAddedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelAddedCopyWith<$Res> {
  _$NetworkEvent_ChannelAddedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelAdded _self;
  final $Res Function(NetworkEvent_ChannelAdded) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? name = null,}) {
  return _then(NetworkEvent_ChannelAdded(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelRemoved extends NetworkEvent {
  const NetworkEvent_ChannelRemoved({required this.serverId, required this.channelId}): super._();
  

 final  String serverId;
 final  String channelId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelRemovedCopyWith<NetworkEvent_ChannelRemoved> get copyWith => _$NetworkEvent_ChannelRemovedCopyWithImpl<NetworkEvent_ChannelRemoved>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelRemoved&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId);

@override
String toString() {
  return 'NetworkEvent.channelRemoved(serverId: $serverId, channelId: $channelId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelRemovedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelRemovedCopyWith(NetworkEvent_ChannelRemoved value, $Res Function(NetworkEvent_ChannelRemoved) _then) = _$NetworkEvent_ChannelRemovedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId
});




}
/// @nodoc
class _$NetworkEvent_ChannelRemovedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelRemovedCopyWith<$Res> {
  _$NetworkEvent_ChannelRemovedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelRemoved _self;
  final $Res Function(NetworkEvent_ChannelRemoved) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,}) {
  return _then(NetworkEvent_ChannelRemoved(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelRenamed extends NetworkEvent {
  const NetworkEvent_ChannelRenamed({required this.serverId, required this.channelId, required this.newName}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String newName;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelRenamedCopyWith<NetworkEvent_ChannelRenamed> get copyWith => _$NetworkEvent_ChannelRenamedCopyWithImpl<NetworkEvent_ChannelRenamed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelRenamed&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.newName, newName) || other.newName == newName));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,newName);

@override
String toString() {
  return 'NetworkEvent.channelRenamed(serverId: $serverId, channelId: $channelId, newName: $newName)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelRenamedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelRenamedCopyWith(NetworkEvent_ChannelRenamed value, $Res Function(NetworkEvent_ChannelRenamed) _then) = _$NetworkEvent_ChannelRenamedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String newName
});




}
/// @nodoc
class _$NetworkEvent_ChannelRenamedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelRenamedCopyWith<$Res> {
  _$NetworkEvent_ChannelRenamedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelRenamed _self;
  final $Res Function(NetworkEvent_ChannelRenamed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? newName = null,}) {
  return _then(NetworkEvent_ChannelRenamed(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,newName: null == newName ? _self.newName : newName // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ServerDeleted extends NetworkEvent {
  const NetworkEvent_ServerDeleted({required this.serverId}): super._();
  

 final  String serverId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ServerDeletedCopyWith<NetworkEvent_ServerDeleted> get copyWith => _$NetworkEvent_ServerDeletedCopyWithImpl<NetworkEvent_ServerDeleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ServerDeleted&&(identical(other.serverId, serverId) || other.serverId == serverId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId);

@override
String toString() {
  return 'NetworkEvent.serverDeleted(serverId: $serverId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ServerDeletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ServerDeletedCopyWith(NetworkEvent_ServerDeleted value, $Res Function(NetworkEvent_ServerDeleted) _then) = _$NetworkEvent_ServerDeletedCopyWithImpl;
@useResult
$Res call({
 String serverId
});




}
/// @nodoc
class _$NetworkEvent_ServerDeletedCopyWithImpl<$Res>
    implements $NetworkEvent_ServerDeletedCopyWith<$Res> {
  _$NetworkEvent_ServerDeletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ServerDeleted _self;
  final $Res Function(NetworkEvent_ServerDeleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,}) {
  return _then(NetworkEvent_ServerDeleted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MemberJoined extends NetworkEvent {
  const NetworkEvent_MemberJoined({required this.serverId, required this.peerId}): super._();
  

 final  String serverId;
 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MemberJoinedCopyWith<NetworkEvent_MemberJoined> get copyWith => _$NetworkEvent_MemberJoinedCopyWithImpl<NetworkEvent_MemberJoined>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MemberJoined&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,peerId);

@override
String toString() {
  return 'NetworkEvent.memberJoined(serverId: $serverId, peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MemberJoinedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MemberJoinedCopyWith(NetworkEvent_MemberJoined value, $Res Function(NetworkEvent_MemberJoined) _then) = _$NetworkEvent_MemberJoinedCopyWithImpl;
@useResult
$Res call({
 String serverId, String peerId
});




}
/// @nodoc
class _$NetworkEvent_MemberJoinedCopyWithImpl<$Res>
    implements $NetworkEvent_MemberJoinedCopyWith<$Res> {
  _$NetworkEvent_MemberJoinedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MemberJoined _self;
  final $Res Function(NetworkEvent_MemberJoined) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? peerId = null,}) {
  return _then(NetworkEvent_MemberJoined(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MemberLeft extends NetworkEvent {
  const NetworkEvent_MemberLeft({required this.serverId, required this.peerId}): super._();
  

 final  String serverId;
 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MemberLeftCopyWith<NetworkEvent_MemberLeft> get copyWith => _$NetworkEvent_MemberLeftCopyWithImpl<NetworkEvent_MemberLeft>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MemberLeft&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,peerId);

@override
String toString() {
  return 'NetworkEvent.memberLeft(serverId: $serverId, peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MemberLeftCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MemberLeftCopyWith(NetworkEvent_MemberLeft value, $Res Function(NetworkEvent_MemberLeft) _then) = _$NetworkEvent_MemberLeftCopyWithImpl;
@useResult
$Res call({
 String serverId, String peerId
});




}
/// @nodoc
class _$NetworkEvent_MemberLeftCopyWithImpl<$Res>
    implements $NetworkEvent_MemberLeftCopyWith<$Res> {
  _$NetworkEvent_MemberLeftCopyWithImpl(this._self, this._then);

  final NetworkEvent_MemberLeft _self;
  final $Res Function(NetworkEvent_MemberLeft) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? peerId = null,}) {
  return _then(NetworkEvent_MemberLeft(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_SyncCompleted extends NetworkEvent {
  const NetworkEvent_SyncCompleted({required this.serverId, required this.opsApplied}): super._();
  

 final  String serverId;
 final  int opsApplied;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_SyncCompletedCopyWith<NetworkEvent_SyncCompleted> get copyWith => _$NetworkEvent_SyncCompletedCopyWithImpl<NetworkEvent_SyncCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_SyncCompleted&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.opsApplied, opsApplied) || other.opsApplied == opsApplied));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,opsApplied);

@override
String toString() {
  return 'NetworkEvent.syncCompleted(serverId: $serverId, opsApplied: $opsApplied)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_SyncCompletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_SyncCompletedCopyWith(NetworkEvent_SyncCompleted value, $Res Function(NetworkEvent_SyncCompleted) _then) = _$NetworkEvent_SyncCompletedCopyWithImpl;
@useResult
$Res call({
 String serverId, int opsApplied
});




}
/// @nodoc
class _$NetworkEvent_SyncCompletedCopyWithImpl<$Res>
    implements $NetworkEvent_SyncCompletedCopyWith<$Res> {
  _$NetworkEvent_SyncCompletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_SyncCompleted _self;
  final $Res Function(NetworkEvent_SyncCompleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? opsApplied = null,}) {
  return _then(NetworkEvent_SyncCompleted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,opsApplied: null == opsApplied ? _self.opsApplied : opsApplied // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NetworkEvent_ServerJoined extends NetworkEvent {
  const NetworkEvent_ServerJoined({required this.serverId, required this.name}): super._();
  

 final  String serverId;
 final  String name;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ServerJoinedCopyWith<NetworkEvent_ServerJoined> get copyWith => _$NetworkEvent_ServerJoinedCopyWithImpl<NetworkEvent_ServerJoined>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ServerJoined&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.name, name) || other.name == name));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,name);

@override
String toString() {
  return 'NetworkEvent.serverJoined(serverId: $serverId, name: $name)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ServerJoinedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ServerJoinedCopyWith(NetworkEvent_ServerJoined value, $Res Function(NetworkEvent_ServerJoined) _then) = _$NetworkEvent_ServerJoinedCopyWithImpl;
@useResult
$Res call({
 String serverId, String name
});




}
/// @nodoc
class _$NetworkEvent_ServerJoinedCopyWithImpl<$Res>
    implements $NetworkEvent_ServerJoinedCopyWith<$Res> {
  _$NetworkEvent_ServerJoinedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ServerJoined _self;
  final $Res Function(NetworkEvent_ServerJoined) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? name = null,}) {
  return _then(NetworkEvent_ServerJoined(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageSyncStarted extends NetworkEvent {
  const NetworkEvent_MessageSyncStarted({required this.serverId, required this.peerId}): super._();
  

 final  String serverId;
 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageSyncStartedCopyWith<NetworkEvent_MessageSyncStarted> get copyWith => _$NetworkEvent_MessageSyncStartedCopyWithImpl<NetworkEvent_MessageSyncStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageSyncStarted&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,peerId);

@override
String toString() {
  return 'NetworkEvent.messageSyncStarted(serverId: $serverId, peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageSyncStartedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageSyncStartedCopyWith(NetworkEvent_MessageSyncStarted value, $Res Function(NetworkEvent_MessageSyncStarted) _then) = _$NetworkEvent_MessageSyncStartedCopyWithImpl;
@useResult
$Res call({
 String serverId, String peerId
});




}
/// @nodoc
class _$NetworkEvent_MessageSyncStartedCopyWithImpl<$Res>
    implements $NetworkEvent_MessageSyncStartedCopyWith<$Res> {
  _$NetworkEvent_MessageSyncStartedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageSyncStarted _self;
  final $Res Function(NetworkEvent_MessageSyncStarted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? peerId = null,}) {
  return _then(NetworkEvent_MessageSyncStarted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageSyncCompleted extends NetworkEvent {
  const NetworkEvent_MessageSyncCompleted({required this.serverId, required this.newMessageCount}): super._();
  

 final  String serverId;
 final  int newMessageCount;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageSyncCompletedCopyWith<NetworkEvent_MessageSyncCompleted> get copyWith => _$NetworkEvent_MessageSyncCompletedCopyWithImpl<NetworkEvent_MessageSyncCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageSyncCompleted&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.newMessageCount, newMessageCount) || other.newMessageCount == newMessageCount));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,newMessageCount);

@override
String toString() {
  return 'NetworkEvent.messageSyncCompleted(serverId: $serverId, newMessageCount: $newMessageCount)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageSyncCompletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageSyncCompletedCopyWith(NetworkEvent_MessageSyncCompleted value, $Res Function(NetworkEvent_MessageSyncCompleted) _then) = _$NetworkEvent_MessageSyncCompletedCopyWithImpl;
@useResult
$Res call({
 String serverId, int newMessageCount
});




}
/// @nodoc
class _$NetworkEvent_MessageSyncCompletedCopyWithImpl<$Res>
    implements $NetworkEvent_MessageSyncCompletedCopyWith<$Res> {
  _$NetworkEvent_MessageSyncCompletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageSyncCompleted _self;
  final $Res Function(NetworkEvent_MessageSyncCompleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? newMessageCount = null,}) {
  return _then(NetworkEvent_MessageSyncCompleted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,newMessageCount: null == newMessageCount ? _self.newMessageCount : newMessageCount // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageSyncFailed extends NetworkEvent {
  const NetworkEvent_MessageSyncFailed({required this.serverId, required this.error}): super._();
  

 final  String serverId;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageSyncFailedCopyWith<NetworkEvent_MessageSyncFailed> get copyWith => _$NetworkEvent_MessageSyncFailedCopyWithImpl<NetworkEvent_MessageSyncFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageSyncFailed&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,error);

@override
String toString() {
  return 'NetworkEvent.messageSyncFailed(serverId: $serverId, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageSyncFailedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageSyncFailedCopyWith(NetworkEvent_MessageSyncFailed value, $Res Function(NetworkEvent_MessageSyncFailed) _then) = _$NetworkEvent_MessageSyncFailedCopyWithImpl;
@useResult
$Res call({
 String serverId, String error
});




}
/// @nodoc
class _$NetworkEvent_MessageSyncFailedCopyWithImpl<$Res>
    implements $NetworkEvent_MessageSyncFailedCopyWith<$Res> {
  _$NetworkEvent_MessageSyncFailedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageSyncFailed _self;
  final $Res Function(NetworkEvent_MessageSyncFailed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? error = null,}) {
  return _then(NetworkEvent_MessageSyncFailed(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageSyncProgress extends NetworkEvent {
  const NetworkEvent_MessageSyncProgress({required this.serverId, required this.channelId, required this.receivedCount, required this.totalCount}): super._();
  

 final  String serverId;
 final  String channelId;
 final  int receivedCount;
 final  int totalCount;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageSyncProgressCopyWith<NetworkEvent_MessageSyncProgress> get copyWith => _$NetworkEvent_MessageSyncProgressCopyWithImpl<NetworkEvent_MessageSyncProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageSyncProgress&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.receivedCount, receivedCount) || other.receivedCount == receivedCount)&&(identical(other.totalCount, totalCount) || other.totalCount == totalCount));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,receivedCount,totalCount);

@override
String toString() {
  return 'NetworkEvent.messageSyncProgress(serverId: $serverId, channelId: $channelId, receivedCount: $receivedCount, totalCount: $totalCount)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageSyncProgressCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageSyncProgressCopyWith(NetworkEvent_MessageSyncProgress value, $Res Function(NetworkEvent_MessageSyncProgress) _then) = _$NetworkEvent_MessageSyncProgressCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, int receivedCount, int totalCount
});




}
/// @nodoc
class _$NetworkEvent_MessageSyncProgressCopyWithImpl<$Res>
    implements $NetworkEvent_MessageSyncProgressCopyWith<$Res> {
  _$NetworkEvent_MessageSyncProgressCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageSyncProgress _self;
  final $Res Function(NetworkEvent_MessageSyncProgress) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? receivedCount = null,Object? totalCount = null,}) {
  return _then(NetworkEvent_MessageSyncProgress(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,receivedCount: null == receivedCount ? _self.receivedCount : receivedCount // ignore: cast_nullable_to_non_nullable
as int,totalCount: null == totalCount ? _self.totalCount : totalCount // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NetworkEvent_RoleChanged extends NetworkEvent {
  const NetworkEvent_RoleChanged({required this.serverId, required this.peerId, required this.newRole}): super._();
  

 final  String serverId;
 final  String peerId;
 final  String newRole;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_RoleChangedCopyWith<NetworkEvent_RoleChanged> get copyWith => _$NetworkEvent_RoleChangedCopyWithImpl<NetworkEvent_RoleChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_RoleChanged&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.newRole, newRole) || other.newRole == newRole));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,peerId,newRole);

@override
String toString() {
  return 'NetworkEvent.roleChanged(serverId: $serverId, peerId: $peerId, newRole: $newRole)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_RoleChangedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_RoleChangedCopyWith(NetworkEvent_RoleChanged value, $Res Function(NetworkEvent_RoleChanged) _then) = _$NetworkEvent_RoleChangedCopyWithImpl;
@useResult
$Res call({
 String serverId, String peerId, String newRole
});




}
/// @nodoc
class _$NetworkEvent_RoleChangedCopyWithImpl<$Res>
    implements $NetworkEvent_RoleChangedCopyWith<$Res> {
  _$NetworkEvent_RoleChangedCopyWithImpl(this._self, this._then);

  final NetworkEvent_RoleChanged _self;
  final $Res Function(NetworkEvent_RoleChanged) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? peerId = null,Object? newRole = null,}) {
  return _then(NetworkEvent_RoleChanged(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,newRole: null == newRole ? _self.newRole : newRole // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_DmSyncCompleted extends NetworkEvent {
  const NetworkEvent_DmSyncCompleted({required this.peerId, required this.newMessageCount}): super._();
  

 final  String peerId;
 final  int newMessageCount;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_DmSyncCompletedCopyWith<NetworkEvent_DmSyncCompleted> get copyWith => _$NetworkEvent_DmSyncCompletedCopyWithImpl<NetworkEvent_DmSyncCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_DmSyncCompleted&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.newMessageCount, newMessageCount) || other.newMessageCount == newMessageCount));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,newMessageCount);

@override
String toString() {
  return 'NetworkEvent.dmSyncCompleted(peerId: $peerId, newMessageCount: $newMessageCount)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_DmSyncCompletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_DmSyncCompletedCopyWith(NetworkEvent_DmSyncCompleted value, $Res Function(NetworkEvent_DmSyncCompleted) _then) = _$NetworkEvent_DmSyncCompletedCopyWithImpl;
@useResult
$Res call({
 String peerId, int newMessageCount
});




}
/// @nodoc
class _$NetworkEvent_DmSyncCompletedCopyWithImpl<$Res>
    implements $NetworkEvent_DmSyncCompletedCopyWith<$Res> {
  _$NetworkEvent_DmSyncCompletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_DmSyncCompleted _self;
  final $Res Function(NetworkEvent_DmSyncCompleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? newMessageCount = null,}) {
  return _then(NetworkEvent_DmSyncCompleted(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,newMessageCount: null == newMessageCount ? _self.newMessageCount : newMessageCount // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NetworkEvent_ProfileUpdated extends NetworkEvent {
  const NetworkEvent_ProfileUpdated({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ProfileUpdatedCopyWith<NetworkEvent_ProfileUpdated> get copyWith => _$NetworkEvent_ProfileUpdatedCopyWithImpl<NetworkEvent_ProfileUpdated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ProfileUpdated&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.profileUpdated(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ProfileUpdatedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ProfileUpdatedCopyWith(NetworkEvent_ProfileUpdated value, $Res Function(NetworkEvent_ProfileUpdated) _then) = _$NetworkEvent_ProfileUpdatedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_ProfileUpdatedCopyWithImpl<$Res>
    implements $NetworkEvent_ProfileUpdatedCopyWith<$Res> {
  _$NetworkEvent_ProfileUpdatedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ProfileUpdated _self;
  final $Res Function(NetworkEvent_ProfileUpdated) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_ProfileUpdated(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelMessageEdited extends NetworkEvent {
  const NetworkEvent_ChannelMessageEdited({required this.serverId, required this.channelId, required this.messageId, required this.newText, required this.editedAt}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String messageId;
 final  String newText;
 final  PlatformInt64 editedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelMessageEditedCopyWith<NetworkEvent_ChannelMessageEdited> get copyWith => _$NetworkEvent_ChannelMessageEditedCopyWithImpl<NetworkEvent_ChannelMessageEdited>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelMessageEdited&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.newText, newText) || other.newText == newText)&&(identical(other.editedAt, editedAt) || other.editedAt == editedAt));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,messageId,newText,editedAt);

@override
String toString() {
  return 'NetworkEvent.channelMessageEdited(serverId: $serverId, channelId: $channelId, messageId: $messageId, newText: $newText, editedAt: $editedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelMessageEditedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelMessageEditedCopyWith(NetworkEvent_ChannelMessageEdited value, $Res Function(NetworkEvent_ChannelMessageEdited) _then) = _$NetworkEvent_ChannelMessageEditedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String messageId, String newText, PlatformInt64 editedAt
});




}
/// @nodoc
class _$NetworkEvent_ChannelMessageEditedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelMessageEditedCopyWith<$Res> {
  _$NetworkEvent_ChannelMessageEditedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelMessageEdited _self;
  final $Res Function(NetworkEvent_ChannelMessageEdited) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? messageId = null,Object? newText = null,Object? editedAt = null,}) {
  return _then(NetworkEvent_ChannelMessageEdited(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,newText: null == newText ? _self.newText : newText // ignore: cast_nullable_to_non_nullable
as String,editedAt: null == editedAt ? _self.editedAt : editedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_DmMessageEdited extends NetworkEvent {
  const NetworkEvent_DmMessageEdited({required this.peerId, required this.messageId, required this.newText, required this.editedAt}): super._();
  

 final  String peerId;
 final  String messageId;
 final  String newText;
 final  PlatformInt64 editedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_DmMessageEditedCopyWith<NetworkEvent_DmMessageEdited> get copyWith => _$NetworkEvent_DmMessageEditedCopyWithImpl<NetworkEvent_DmMessageEdited>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_DmMessageEdited&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.newText, newText) || other.newText == newText)&&(identical(other.editedAt, editedAt) || other.editedAt == editedAt));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,messageId,newText,editedAt);

@override
String toString() {
  return 'NetworkEvent.dmMessageEdited(peerId: $peerId, messageId: $messageId, newText: $newText, editedAt: $editedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_DmMessageEditedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_DmMessageEditedCopyWith(NetworkEvent_DmMessageEdited value, $Res Function(NetworkEvent_DmMessageEdited) _then) = _$NetworkEvent_DmMessageEditedCopyWithImpl;
@useResult
$Res call({
 String peerId, String messageId, String newText, PlatformInt64 editedAt
});




}
/// @nodoc
class _$NetworkEvent_DmMessageEditedCopyWithImpl<$Res>
    implements $NetworkEvent_DmMessageEditedCopyWith<$Res> {
  _$NetworkEvent_DmMessageEditedCopyWithImpl(this._self, this._then);

  final NetworkEvent_DmMessageEdited _self;
  final $Res Function(NetworkEvent_DmMessageEdited) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? messageId = null,Object? newText = null,Object? editedAt = null,}) {
  return _then(NetworkEvent_DmMessageEdited(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,newText: null == newText ? _self.newText : newText // ignore: cast_nullable_to_non_nullable
as String,editedAt: null == editedAt ? _self.editedAt : editedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelMessageDeleted extends NetworkEvent {
  const NetworkEvent_ChannelMessageDeleted({required this.serverId, required this.channelId, required this.messageId, required this.deletedAt}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String messageId;
 final  PlatformInt64 deletedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelMessageDeletedCopyWith<NetworkEvent_ChannelMessageDeleted> get copyWith => _$NetworkEvent_ChannelMessageDeletedCopyWithImpl<NetworkEvent_ChannelMessageDeleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelMessageDeleted&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.deletedAt, deletedAt) || other.deletedAt == deletedAt));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,messageId,deletedAt);

@override
String toString() {
  return 'NetworkEvent.channelMessageDeleted(serverId: $serverId, channelId: $channelId, messageId: $messageId, deletedAt: $deletedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelMessageDeletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelMessageDeletedCopyWith(NetworkEvent_ChannelMessageDeleted value, $Res Function(NetworkEvent_ChannelMessageDeleted) _then) = _$NetworkEvent_ChannelMessageDeletedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String messageId, PlatformInt64 deletedAt
});




}
/// @nodoc
class _$NetworkEvent_ChannelMessageDeletedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelMessageDeletedCopyWith<$Res> {
  _$NetworkEvent_ChannelMessageDeletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelMessageDeleted _self;
  final $Res Function(NetworkEvent_ChannelMessageDeleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? messageId = null,Object? deletedAt = null,}) {
  return _then(NetworkEvent_ChannelMessageDeleted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,deletedAt: null == deletedAt ? _self.deletedAt : deletedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_DmMessageDeleted extends NetworkEvent {
  const NetworkEvent_DmMessageDeleted({required this.peerId, required this.messageId, required this.deletedAt}): super._();
  

 final  String peerId;
 final  String messageId;
 final  PlatformInt64 deletedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_DmMessageDeletedCopyWith<NetworkEvent_DmMessageDeleted> get copyWith => _$NetworkEvent_DmMessageDeletedCopyWithImpl<NetworkEvent_DmMessageDeleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_DmMessageDeleted&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.deletedAt, deletedAt) || other.deletedAt == deletedAt));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,messageId,deletedAt);

@override
String toString() {
  return 'NetworkEvent.dmMessageDeleted(peerId: $peerId, messageId: $messageId, deletedAt: $deletedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_DmMessageDeletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_DmMessageDeletedCopyWith(NetworkEvent_DmMessageDeleted value, $Res Function(NetworkEvent_DmMessageDeleted) _then) = _$NetworkEvent_DmMessageDeletedCopyWithImpl;
@useResult
$Res call({
 String peerId, String messageId, PlatformInt64 deletedAt
});




}
/// @nodoc
class _$NetworkEvent_DmMessageDeletedCopyWithImpl<$Res>
    implements $NetworkEvent_DmMessageDeletedCopyWith<$Res> {
  _$NetworkEvent_DmMessageDeletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_DmMessageDeleted _self;
  final $Res Function(NetworkEvent_DmMessageDeleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? messageId = null,Object? deletedAt = null,}) {
  return _then(NetworkEvent_DmMessageDeleted(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,deletedAt: null == deletedAt ? _self.deletedAt : deletedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelReactionAdded extends NetworkEvent {
  const NetworkEvent_ChannelReactionAdded({required this.serverId, required this.channelId, required this.messageId, required this.emoji, required this.reactor, required this.addedAt}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String messageId;
 final  String emoji;
 final  String reactor;
 final  PlatformInt64 addedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelReactionAddedCopyWith<NetworkEvent_ChannelReactionAdded> get copyWith => _$NetworkEvent_ChannelReactionAddedCopyWithImpl<NetworkEvent_ChannelReactionAdded>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelReactionAdded&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.emoji, emoji) || other.emoji == emoji)&&(identical(other.reactor, reactor) || other.reactor == reactor)&&(identical(other.addedAt, addedAt) || other.addedAt == addedAt));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,messageId,emoji,reactor,addedAt);

@override
String toString() {
  return 'NetworkEvent.channelReactionAdded(serverId: $serverId, channelId: $channelId, messageId: $messageId, emoji: $emoji, reactor: $reactor, addedAt: $addedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelReactionAddedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelReactionAddedCopyWith(NetworkEvent_ChannelReactionAdded value, $Res Function(NetworkEvent_ChannelReactionAdded) _then) = _$NetworkEvent_ChannelReactionAddedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String messageId, String emoji, String reactor, PlatformInt64 addedAt
});




}
/// @nodoc
class _$NetworkEvent_ChannelReactionAddedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelReactionAddedCopyWith<$Res> {
  _$NetworkEvent_ChannelReactionAddedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelReactionAdded _self;
  final $Res Function(NetworkEvent_ChannelReactionAdded) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? messageId = null,Object? emoji = null,Object? reactor = null,Object? addedAt = null,}) {
  return _then(NetworkEvent_ChannelReactionAdded(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,emoji: null == emoji ? _self.emoji : emoji // ignore: cast_nullable_to_non_nullable
as String,reactor: null == reactor ? _self.reactor : reactor // ignore: cast_nullable_to_non_nullable
as String,addedAt: null == addedAt ? _self.addedAt : addedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_DmReactionAdded extends NetworkEvent {
  const NetworkEvent_DmReactionAdded({required this.peerId, required this.messageId, required this.emoji, required this.reactor, required this.addedAt}): super._();
  

 final  String peerId;
 final  String messageId;
 final  String emoji;
 final  String reactor;
 final  PlatformInt64 addedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_DmReactionAddedCopyWith<NetworkEvent_DmReactionAdded> get copyWith => _$NetworkEvent_DmReactionAddedCopyWithImpl<NetworkEvent_DmReactionAdded>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_DmReactionAdded&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.emoji, emoji) || other.emoji == emoji)&&(identical(other.reactor, reactor) || other.reactor == reactor)&&(identical(other.addedAt, addedAt) || other.addedAt == addedAt));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,messageId,emoji,reactor,addedAt);

@override
String toString() {
  return 'NetworkEvent.dmReactionAdded(peerId: $peerId, messageId: $messageId, emoji: $emoji, reactor: $reactor, addedAt: $addedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_DmReactionAddedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_DmReactionAddedCopyWith(NetworkEvent_DmReactionAdded value, $Res Function(NetworkEvent_DmReactionAdded) _then) = _$NetworkEvent_DmReactionAddedCopyWithImpl;
@useResult
$Res call({
 String peerId, String messageId, String emoji, String reactor, PlatformInt64 addedAt
});




}
/// @nodoc
class _$NetworkEvent_DmReactionAddedCopyWithImpl<$Res>
    implements $NetworkEvent_DmReactionAddedCopyWith<$Res> {
  _$NetworkEvent_DmReactionAddedCopyWithImpl(this._self, this._then);

  final NetworkEvent_DmReactionAdded _self;
  final $Res Function(NetworkEvent_DmReactionAdded) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? messageId = null,Object? emoji = null,Object? reactor = null,Object? addedAt = null,}) {
  return _then(NetworkEvent_DmReactionAdded(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,emoji: null == emoji ? _self.emoji : emoji // ignore: cast_nullable_to_non_nullable
as String,reactor: null == reactor ? _self.reactor : reactor // ignore: cast_nullable_to_non_nullable
as String,addedAt: null == addedAt ? _self.addedAt : addedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_ChannelReactionRemoved extends NetworkEvent {
  const NetworkEvent_ChannelReactionRemoved({required this.serverId, required this.channelId, required this.messageId, required this.emoji, required this.reactor, required this.removedAt}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String messageId;
 final  String emoji;
 final  String reactor;
 final  PlatformInt64 removedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ChannelReactionRemovedCopyWith<NetworkEvent_ChannelReactionRemoved> get copyWith => _$NetworkEvent_ChannelReactionRemovedCopyWithImpl<NetworkEvent_ChannelReactionRemoved>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ChannelReactionRemoved&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.emoji, emoji) || other.emoji == emoji)&&(identical(other.reactor, reactor) || other.reactor == reactor)&&(identical(other.removedAt, removedAt) || other.removedAt == removedAt));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,messageId,emoji,reactor,removedAt);

@override
String toString() {
  return 'NetworkEvent.channelReactionRemoved(serverId: $serverId, channelId: $channelId, messageId: $messageId, emoji: $emoji, reactor: $reactor, removedAt: $removedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ChannelReactionRemovedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ChannelReactionRemovedCopyWith(NetworkEvent_ChannelReactionRemoved value, $Res Function(NetworkEvent_ChannelReactionRemoved) _then) = _$NetworkEvent_ChannelReactionRemovedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String messageId, String emoji, String reactor, PlatformInt64 removedAt
});




}
/// @nodoc
class _$NetworkEvent_ChannelReactionRemovedCopyWithImpl<$Res>
    implements $NetworkEvent_ChannelReactionRemovedCopyWith<$Res> {
  _$NetworkEvent_ChannelReactionRemovedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ChannelReactionRemoved _self;
  final $Res Function(NetworkEvent_ChannelReactionRemoved) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? messageId = null,Object? emoji = null,Object? reactor = null,Object? removedAt = null,}) {
  return _then(NetworkEvent_ChannelReactionRemoved(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,emoji: null == emoji ? _self.emoji : emoji // ignore: cast_nullable_to_non_nullable
as String,reactor: null == reactor ? _self.reactor : reactor // ignore: cast_nullable_to_non_nullable
as String,removedAt: null == removedAt ? _self.removedAt : removedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_DmReactionRemoved extends NetworkEvent {
  const NetworkEvent_DmReactionRemoved({required this.peerId, required this.messageId, required this.emoji, required this.reactor, required this.removedAt}): super._();
  

 final  String peerId;
 final  String messageId;
 final  String emoji;
 final  String reactor;
 final  PlatformInt64 removedAt;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_DmReactionRemovedCopyWith<NetworkEvent_DmReactionRemoved> get copyWith => _$NetworkEvent_DmReactionRemovedCopyWithImpl<NetworkEvent_DmReactionRemoved>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_DmReactionRemoved&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.emoji, emoji) || other.emoji == emoji)&&(identical(other.reactor, reactor) || other.reactor == reactor)&&(identical(other.removedAt, removedAt) || other.removedAt == removedAt));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,messageId,emoji,reactor,removedAt);

@override
String toString() {
  return 'NetworkEvent.dmReactionRemoved(peerId: $peerId, messageId: $messageId, emoji: $emoji, reactor: $reactor, removedAt: $removedAt)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_DmReactionRemovedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_DmReactionRemovedCopyWith(NetworkEvent_DmReactionRemoved value, $Res Function(NetworkEvent_DmReactionRemoved) _then) = _$NetworkEvent_DmReactionRemovedCopyWithImpl;
@useResult
$Res call({
 String peerId, String messageId, String emoji, String reactor, PlatformInt64 removedAt
});




}
/// @nodoc
class _$NetworkEvent_DmReactionRemovedCopyWithImpl<$Res>
    implements $NetworkEvent_DmReactionRemovedCopyWith<$Res> {
  _$NetworkEvent_DmReactionRemovedCopyWithImpl(this._self, this._then);

  final NetworkEvent_DmReactionRemoved _self;
  final $Res Function(NetworkEvent_DmReactionRemoved) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? messageId = null,Object? emoji = null,Object? reactor = null,Object? removedAt = null,}) {
  return _then(NetworkEvent_DmReactionRemoved(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,emoji: null == emoji ? _self.emoji : emoji // ignore: cast_nullable_to_non_nullable
as String,reactor: null == reactor ? _self.reactor : reactor // ignore: cast_nullable_to_non_nullable
as String,removedAt: null == removedAt ? _self.removedAt : removedAt // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NetworkEvent_FriendRequestReceived extends NetworkEvent {
  const NetworkEvent_FriendRequestReceived({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FriendRequestReceivedCopyWith<NetworkEvent_FriendRequestReceived> get copyWith => _$NetworkEvent_FriendRequestReceivedCopyWithImpl<NetworkEvent_FriendRequestReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FriendRequestReceived&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.friendRequestReceived(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FriendRequestReceivedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FriendRequestReceivedCopyWith(NetworkEvent_FriendRequestReceived value, $Res Function(NetworkEvent_FriendRequestReceived) _then) = _$NetworkEvent_FriendRequestReceivedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_FriendRequestReceivedCopyWithImpl<$Res>
    implements $NetworkEvent_FriendRequestReceivedCopyWith<$Res> {
  _$NetworkEvent_FriendRequestReceivedCopyWithImpl(this._self, this._then);

  final NetworkEvent_FriendRequestReceived _self;
  final $Res Function(NetworkEvent_FriendRequestReceived) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_FriendRequestReceived(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_FriendRequestAccepted extends NetworkEvent {
  const NetworkEvent_FriendRequestAccepted({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FriendRequestAcceptedCopyWith<NetworkEvent_FriendRequestAccepted> get copyWith => _$NetworkEvent_FriendRequestAcceptedCopyWithImpl<NetworkEvent_FriendRequestAccepted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FriendRequestAccepted&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.friendRequestAccepted(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FriendRequestAcceptedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FriendRequestAcceptedCopyWith(NetworkEvent_FriendRequestAccepted value, $Res Function(NetworkEvent_FriendRequestAccepted) _then) = _$NetworkEvent_FriendRequestAcceptedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_FriendRequestAcceptedCopyWithImpl<$Res>
    implements $NetworkEvent_FriendRequestAcceptedCopyWith<$Res> {
  _$NetworkEvent_FriendRequestAcceptedCopyWithImpl(this._self, this._then);

  final NetworkEvent_FriendRequestAccepted _self;
  final $Res Function(NetworkEvent_FriendRequestAccepted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_FriendRequestAccepted(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_FriendRequestRejected extends NetworkEvent {
  const NetworkEvent_FriendRequestRejected({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FriendRequestRejectedCopyWith<NetworkEvent_FriendRequestRejected> get copyWith => _$NetworkEvent_FriendRequestRejectedCopyWithImpl<NetworkEvent_FriendRequestRejected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FriendRequestRejected&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.friendRequestRejected(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FriendRequestRejectedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FriendRequestRejectedCopyWith(NetworkEvent_FriendRequestRejected value, $Res Function(NetworkEvent_FriendRequestRejected) _then) = _$NetworkEvent_FriendRequestRejectedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_FriendRequestRejectedCopyWithImpl<$Res>
    implements $NetworkEvent_FriendRequestRejectedCopyWith<$Res> {
  _$NetworkEvent_FriendRequestRejectedCopyWithImpl(this._self, this._then);

  final NetworkEvent_FriendRequestRejected _self;
  final $Res Function(NetworkEvent_FriendRequestRejected) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_FriendRequestRejected(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_FriendRemoved extends NetworkEvent {
  const NetworkEvent_FriendRemoved({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FriendRemovedCopyWith<NetworkEvent_FriendRemoved> get copyWith => _$NetworkEvent_FriendRemovedCopyWithImpl<NetworkEvent_FriendRemoved>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FriendRemoved&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.friendRemoved(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FriendRemovedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FriendRemovedCopyWith(NetworkEvent_FriendRemoved value, $Res Function(NetworkEvent_FriendRemoved) _then) = _$NetworkEvent_FriendRemovedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_FriendRemovedCopyWithImpl<$Res>
    implements $NetworkEvent_FriendRemovedCopyWith<$Res> {
  _$NetworkEvent_FriendRemovedCopyWithImpl(this._self, this._then);

  final NetworkEvent_FriendRemoved _self;
  final $Res Function(NetworkEvent_FriendRemoved) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_FriendRemoved(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_TypingStarted extends NetworkEvent {
  const NetworkEvent_TypingStarted({required this.peerId, required this.serverId, required this.channelId}): super._();
  

 final  String peerId;
 final  String serverId;
 final  String channelId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_TypingStartedCopyWith<NetworkEvent_TypingStarted> get copyWith => _$NetworkEvent_TypingStartedCopyWithImpl<NetworkEvent_TypingStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_TypingStarted&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,serverId,channelId);

@override
String toString() {
  return 'NetworkEvent.typingStarted(peerId: $peerId, serverId: $serverId, channelId: $channelId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_TypingStartedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_TypingStartedCopyWith(NetworkEvent_TypingStarted value, $Res Function(NetworkEvent_TypingStarted) _then) = _$NetworkEvent_TypingStartedCopyWithImpl;
@useResult
$Res call({
 String peerId, String serverId, String channelId
});




}
/// @nodoc
class _$NetworkEvent_TypingStartedCopyWithImpl<$Res>
    implements $NetworkEvent_TypingStartedCopyWith<$Res> {
  _$NetworkEvent_TypingStartedCopyWithImpl(this._self, this._then);

  final NetworkEvent_TypingStarted _self;
  final $Res Function(NetworkEvent_TypingStarted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? serverId = null,Object? channelId = null,}) {
  return _then(NetworkEvent_TypingStarted(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessagePinned extends NetworkEvent {
  const NetworkEvent_MessagePinned({required this.serverId, required this.channelId, required this.messageId}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String messageId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessagePinnedCopyWith<NetworkEvent_MessagePinned> get copyWith => _$NetworkEvent_MessagePinnedCopyWithImpl<NetworkEvent_MessagePinned>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessagePinned&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.messageId, messageId) || other.messageId == messageId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,messageId);

@override
String toString() {
  return 'NetworkEvent.messagePinned(serverId: $serverId, channelId: $channelId, messageId: $messageId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessagePinnedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessagePinnedCopyWith(NetworkEvent_MessagePinned value, $Res Function(NetworkEvent_MessagePinned) _then) = _$NetworkEvent_MessagePinnedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String messageId
});




}
/// @nodoc
class _$NetworkEvent_MessagePinnedCopyWithImpl<$Res>
    implements $NetworkEvent_MessagePinnedCopyWith<$Res> {
  _$NetworkEvent_MessagePinnedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessagePinned _self;
  final $Res Function(NetworkEvent_MessagePinned) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? messageId = null,}) {
  return _then(NetworkEvent_MessagePinned(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_MessageUnpinned extends NetworkEvent {
  const NetworkEvent_MessageUnpinned({required this.serverId, required this.channelId, required this.messageId}): super._();
  

 final  String serverId;
 final  String channelId;
 final  String messageId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageUnpinnedCopyWith<NetworkEvent_MessageUnpinned> get copyWith => _$NetworkEvent_MessageUnpinnedCopyWithImpl<NetworkEvent_MessageUnpinned>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageUnpinned&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId)&&(identical(other.messageId, messageId) || other.messageId == messageId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,channelId,messageId);

@override
String toString() {
  return 'NetworkEvent.messageUnpinned(serverId: $serverId, channelId: $channelId, messageId: $messageId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageUnpinnedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageUnpinnedCopyWith(NetworkEvent_MessageUnpinned value, $Res Function(NetworkEvent_MessageUnpinned) _then) = _$NetworkEvent_MessageUnpinnedCopyWithImpl;
@useResult
$Res call({
 String serverId, String channelId, String messageId
});




}
/// @nodoc
class _$NetworkEvent_MessageUnpinnedCopyWithImpl<$Res>
    implements $NetworkEvent_MessageUnpinnedCopyWith<$Res> {
  _$NetworkEvent_MessageUnpinnedCopyWithImpl(this._self, this._then);

  final NetworkEvent_MessageUnpinned _self;
  final $Res Function(NetworkEvent_MessageUnpinned) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? channelId = null,Object? messageId = null,}) {
  return _then(NetworkEvent_MessageUnpinned(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_FileHeaderReceived extends NetworkEvent {
  const NetworkEvent_FileHeaderReceived({required this.fileId, required this.fileName, required this.sizeBytes, required this.isImage, this.width, this.height, required this.messageId, required this.senderId, required this.serverId, required this.channelId}): super._();
  

 final  String fileId;
 final  String fileName;
 final  BigInt sizeBytes;
 final  bool isImage;
 final  int? width;
 final  int? height;
 final  String messageId;
 final  String senderId;
 final  String serverId;
 final  String channelId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FileHeaderReceivedCopyWith<NetworkEvent_FileHeaderReceived> get copyWith => _$NetworkEvent_FileHeaderReceivedCopyWithImpl<NetworkEvent_FileHeaderReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FileHeaderReceived&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.fileName, fileName) || other.fileName == fileName)&&(identical(other.sizeBytes, sizeBytes) || other.sizeBytes == sizeBytes)&&(identical(other.isImage, isImage) || other.isImage == isImage)&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.senderId, senderId) || other.senderId == senderId)&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.channelId, channelId) || other.channelId == channelId));
}


@override
int get hashCode => Object.hash(runtimeType,fileId,fileName,sizeBytes,isImage,width,height,messageId,senderId,serverId,channelId);

@override
String toString() {
  return 'NetworkEvent.fileHeaderReceived(fileId: $fileId, fileName: $fileName, sizeBytes: $sizeBytes, isImage: $isImage, width: $width, height: $height, messageId: $messageId, senderId: $senderId, serverId: $serverId, channelId: $channelId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FileHeaderReceivedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FileHeaderReceivedCopyWith(NetworkEvent_FileHeaderReceived value, $Res Function(NetworkEvent_FileHeaderReceived) _then) = _$NetworkEvent_FileHeaderReceivedCopyWithImpl;
@useResult
$Res call({
 String fileId, String fileName, BigInt sizeBytes, bool isImage, int? width, int? height, String messageId, String senderId, String serverId, String channelId
});




}
/// @nodoc
class _$NetworkEvent_FileHeaderReceivedCopyWithImpl<$Res>
    implements $NetworkEvent_FileHeaderReceivedCopyWith<$Res> {
  _$NetworkEvent_FileHeaderReceivedCopyWithImpl(this._self, this._then);

  final NetworkEvent_FileHeaderReceived _self;
  final $Res Function(NetworkEvent_FileHeaderReceived) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fileId = null,Object? fileName = null,Object? sizeBytes = null,Object? isImage = null,Object? width = freezed,Object? height = freezed,Object? messageId = null,Object? senderId = null,Object? serverId = null,Object? channelId = null,}) {
  return _then(NetworkEvent_FileHeaderReceived(
fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,fileName: null == fileName ? _self.fileName : fileName // ignore: cast_nullable_to_non_nullable
as String,sizeBytes: null == sizeBytes ? _self.sizeBytes : sizeBytes // ignore: cast_nullable_to_non_nullable
as BigInt,isImage: null == isImage ? _self.isImage : isImage // ignore: cast_nullable_to_non_nullable
as bool,width: freezed == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int?,height: freezed == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int?,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,senderId: null == senderId ? _self.senderId : senderId // ignore: cast_nullable_to_non_nullable
as String,serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_FileProgress extends NetworkEvent {
  const NetworkEvent_FileProgress({required this.fileId, required this.chunksReceived, required this.totalChunks}): super._();
  

 final  String fileId;
 final  int chunksReceived;
 final  int totalChunks;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FileProgressCopyWith<NetworkEvent_FileProgress> get copyWith => _$NetworkEvent_FileProgressCopyWithImpl<NetworkEvent_FileProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FileProgress&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.chunksReceived, chunksReceived) || other.chunksReceived == chunksReceived)&&(identical(other.totalChunks, totalChunks) || other.totalChunks == totalChunks));
}


@override
int get hashCode => Object.hash(runtimeType,fileId,chunksReceived,totalChunks);

@override
String toString() {
  return 'NetworkEvent.fileProgress(fileId: $fileId, chunksReceived: $chunksReceived, totalChunks: $totalChunks)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FileProgressCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FileProgressCopyWith(NetworkEvent_FileProgress value, $Res Function(NetworkEvent_FileProgress) _then) = _$NetworkEvent_FileProgressCopyWithImpl;
@useResult
$Res call({
 String fileId, int chunksReceived, int totalChunks
});




}
/// @nodoc
class _$NetworkEvent_FileProgressCopyWithImpl<$Res>
    implements $NetworkEvent_FileProgressCopyWith<$Res> {
  _$NetworkEvent_FileProgressCopyWithImpl(this._self, this._then);

  final NetworkEvent_FileProgress _self;
  final $Res Function(NetworkEvent_FileProgress) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fileId = null,Object? chunksReceived = null,Object? totalChunks = null,}) {
  return _then(NetworkEvent_FileProgress(
fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,chunksReceived: null == chunksReceived ? _self.chunksReceived : chunksReceived // ignore: cast_nullable_to_non_nullable
as int,totalChunks: null == totalChunks ? _self.totalChunks : totalChunks // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NetworkEvent_FileCompleted extends NetworkEvent {
  const NetworkEvent_FileCompleted({required this.fileId, required this.diskPath}): super._();
  

 final  String fileId;
 final  String diskPath;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FileCompletedCopyWith<NetworkEvent_FileCompleted> get copyWith => _$NetworkEvent_FileCompletedCopyWithImpl<NetworkEvent_FileCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FileCompleted&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.diskPath, diskPath) || other.diskPath == diskPath));
}


@override
int get hashCode => Object.hash(runtimeType,fileId,diskPath);

@override
String toString() {
  return 'NetworkEvent.fileCompleted(fileId: $fileId, diskPath: $diskPath)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FileCompletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FileCompletedCopyWith(NetworkEvent_FileCompleted value, $Res Function(NetworkEvent_FileCompleted) _then) = _$NetworkEvent_FileCompletedCopyWithImpl;
@useResult
$Res call({
 String fileId, String diskPath
});




}
/// @nodoc
class _$NetworkEvent_FileCompletedCopyWithImpl<$Res>
    implements $NetworkEvent_FileCompletedCopyWith<$Res> {
  _$NetworkEvent_FileCompletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_FileCompleted _self;
  final $Res Function(NetworkEvent_FileCompleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fileId = null,Object? diskPath = null,}) {
  return _then(NetworkEvent_FileCompleted(
fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,diskPath: null == diskPath ? _self.diskPath : diskPath // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_FileFailed extends NetworkEvent {
  const NetworkEvent_FileFailed({required this.fileId, required this.error}): super._();
  

 final  String fileId;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_FileFailedCopyWith<NetworkEvent_FileFailed> get copyWith => _$NetworkEvent_FileFailedCopyWithImpl<NetworkEvent_FileFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_FileFailed&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,fileId,error);

@override
String toString() {
  return 'NetworkEvent.fileFailed(fileId: $fileId, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_FileFailedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_FileFailedCopyWith(NetworkEvent_FileFailed value, $Res Function(NetworkEvent_FileFailed) _then) = _$NetworkEvent_FileFailedCopyWithImpl;
@useResult
$Res call({
 String fileId, String error
});




}
/// @nodoc
class _$NetworkEvent_FileFailedCopyWithImpl<$Res>
    implements $NetworkEvent_FileFailedCopyWith<$Res> {
  _$NetworkEvent_FileFailedCopyWithImpl(this._self, this._then);

  final NetworkEvent_FileFailed _self;
  final $Res Function(NetworkEvent_FileFailed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fileId = null,Object? error = null,}) {
  return _then(NetworkEvent_FileFailed(
fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ShardStored extends NetworkEvent {
  const NetworkEvent_ShardStored({required this.serverId, required this.contentId, required this.shardIndex, required this.fromPeer}): super._();
  

 final  String serverId;
 final  String contentId;
 final  int shardIndex;
 final  String fromPeer;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ShardStoredCopyWith<NetworkEvent_ShardStored> get copyWith => _$NetworkEvent_ShardStoredCopyWithImpl<NetworkEvent_ShardStored>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ShardStored&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.shardIndex, shardIndex) || other.shardIndex == shardIndex)&&(identical(other.fromPeer, fromPeer) || other.fromPeer == fromPeer));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,shardIndex,fromPeer);

@override
String toString() {
  return 'NetworkEvent.shardStored(serverId: $serverId, contentId: $contentId, shardIndex: $shardIndex, fromPeer: $fromPeer)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ShardStoredCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ShardStoredCopyWith(NetworkEvent_ShardStored value, $Res Function(NetworkEvent_ShardStored) _then) = _$NetworkEvent_ShardStoredCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, int shardIndex, String fromPeer
});




}
/// @nodoc
class _$NetworkEvent_ShardStoredCopyWithImpl<$Res>
    implements $NetworkEvent_ShardStoredCopyWith<$Res> {
  _$NetworkEvent_ShardStoredCopyWithImpl(this._self, this._then);

  final NetworkEvent_ShardStored _self;
  final $Res Function(NetworkEvent_ShardStored) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? shardIndex = null,Object? fromPeer = null,}) {
  return _then(NetworkEvent_ShardStored(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,shardIndex: null == shardIndex ? _self.shardIndex : shardIndex // ignore: cast_nullable_to_non_nullable
as int,fromPeer: null == fromPeer ? _self.fromPeer : fromPeer // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ShardStoreAckReceived extends NetworkEvent {
  const NetworkEvent_ShardStoreAckReceived({required this.serverId, required this.contentId, required this.shardIndex, required this.success, required this.error}): super._();
  

 final  String serverId;
 final  String contentId;
 final  int shardIndex;
 final  bool success;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ShardStoreAckReceivedCopyWith<NetworkEvent_ShardStoreAckReceived> get copyWith => _$NetworkEvent_ShardStoreAckReceivedCopyWithImpl<NetworkEvent_ShardStoreAckReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ShardStoreAckReceived&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.shardIndex, shardIndex) || other.shardIndex == shardIndex)&&(identical(other.success, success) || other.success == success)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,shardIndex,success,error);

@override
String toString() {
  return 'NetworkEvent.shardStoreAckReceived(serverId: $serverId, contentId: $contentId, shardIndex: $shardIndex, success: $success, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ShardStoreAckReceivedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ShardStoreAckReceivedCopyWith(NetworkEvent_ShardStoreAckReceived value, $Res Function(NetworkEvent_ShardStoreAckReceived) _then) = _$NetworkEvent_ShardStoreAckReceivedCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, int shardIndex, bool success, String error
});




}
/// @nodoc
class _$NetworkEvent_ShardStoreAckReceivedCopyWithImpl<$Res>
    implements $NetworkEvent_ShardStoreAckReceivedCopyWith<$Res> {
  _$NetworkEvent_ShardStoreAckReceivedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ShardStoreAckReceived _self;
  final $Res Function(NetworkEvent_ShardStoreAckReceived) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? shardIndex = null,Object? success = null,Object? error = null,}) {
  return _then(NetworkEvent_ShardStoreAckReceived(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,shardIndex: null == shardIndex ? _self.shardIndex : shardIndex // ignore: cast_nullable_to_non_nullable
as int,success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ShardStoreFailed extends NetworkEvent {
  const NetworkEvent_ShardStoreFailed({required this.serverId, required this.contentId, required this.shardIndex, required this.targetPeer, required this.error}): super._();
  

 final  String serverId;
 final  String contentId;
 final  int shardIndex;
 final  String targetPeer;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ShardStoreFailedCopyWith<NetworkEvent_ShardStoreFailed> get copyWith => _$NetworkEvent_ShardStoreFailedCopyWithImpl<NetworkEvent_ShardStoreFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ShardStoreFailed&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.shardIndex, shardIndex) || other.shardIndex == shardIndex)&&(identical(other.targetPeer, targetPeer) || other.targetPeer == targetPeer)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,shardIndex,targetPeer,error);

@override
String toString() {
  return 'NetworkEvent.shardStoreFailed(serverId: $serverId, contentId: $contentId, shardIndex: $shardIndex, targetPeer: $targetPeer, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ShardStoreFailedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ShardStoreFailedCopyWith(NetworkEvent_ShardStoreFailed value, $Res Function(NetworkEvent_ShardStoreFailed) _then) = _$NetworkEvent_ShardStoreFailedCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, int shardIndex, String targetPeer, String error
});




}
/// @nodoc
class _$NetworkEvent_ShardStoreFailedCopyWithImpl<$Res>
    implements $NetworkEvent_ShardStoreFailedCopyWith<$Res> {
  _$NetworkEvent_ShardStoreFailedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ShardStoreFailed _self;
  final $Res Function(NetworkEvent_ShardStoreFailed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? shardIndex = null,Object? targetPeer = null,Object? error = null,}) {
  return _then(NetworkEvent_ShardStoreFailed(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,shardIndex: null == shardIndex ? _self.shardIndex : shardIndex // ignore: cast_nullable_to_non_nullable
as int,targetPeer: null == targetPeer ? _self.targetPeer : targetPeer // ignore: cast_nullable_to_non_nullable
as String,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ShardDeleted extends NetworkEvent {
  const NetworkEvent_ShardDeleted({required this.serverId, required this.contentId}): super._();
  

 final  String serverId;
 final  String contentId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ShardDeletedCopyWith<NetworkEvent_ShardDeleted> get copyWith => _$NetworkEvent_ShardDeletedCopyWithImpl<NetworkEvent_ShardDeleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ShardDeleted&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId);

@override
String toString() {
  return 'NetworkEvent.shardDeleted(serverId: $serverId, contentId: $contentId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ShardDeletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ShardDeletedCopyWith(NetworkEvent_ShardDeleted value, $Res Function(NetworkEvent_ShardDeleted) _then) = _$NetworkEvent_ShardDeletedCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId
});




}
/// @nodoc
class _$NetworkEvent_ShardDeletedCopyWithImpl<$Res>
    implements $NetworkEvent_ShardDeletedCopyWith<$Res> {
  _$NetworkEvent_ShardDeletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ShardDeleted _self;
  final $Res Function(NetworkEvent_ShardDeleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,}) {
  return _then(NetworkEvent_ShardDeleted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ShardReceived extends NetworkEvent {
  const NetworkEvent_ShardReceived({required this.serverId, required this.contentId, required this.shardIndex, required this.fromPeer}): super._();
  

 final  String serverId;
 final  String contentId;
 final  int shardIndex;
 final  String fromPeer;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ShardReceivedCopyWith<NetworkEvent_ShardReceived> get copyWith => _$NetworkEvent_ShardReceivedCopyWithImpl<NetworkEvent_ShardReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ShardReceived&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.shardIndex, shardIndex) || other.shardIndex == shardIndex)&&(identical(other.fromPeer, fromPeer) || other.fromPeer == fromPeer));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,shardIndex,fromPeer);

@override
String toString() {
  return 'NetworkEvent.shardReceived(serverId: $serverId, contentId: $contentId, shardIndex: $shardIndex, fromPeer: $fromPeer)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ShardReceivedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ShardReceivedCopyWith(NetworkEvent_ShardReceived value, $Res Function(NetworkEvent_ShardReceived) _then) = _$NetworkEvent_ShardReceivedCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, int shardIndex, String fromPeer
});




}
/// @nodoc
class _$NetworkEvent_ShardReceivedCopyWithImpl<$Res>
    implements $NetworkEvent_ShardReceivedCopyWith<$Res> {
  _$NetworkEvent_ShardReceivedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ShardReceived _self;
  final $Res Function(NetworkEvent_ShardReceived) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? shardIndex = null,Object? fromPeer = null,}) {
  return _then(NetworkEvent_ShardReceived(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,shardIndex: null == shardIndex ? _self.shardIndex : shardIndex // ignore: cast_nullable_to_non_nullable
as int,fromPeer: null == fromPeer ? _self.fromPeer : fromPeer // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_ShardRequestFailed extends NetworkEvent {
  const NetworkEvent_ShardRequestFailed({required this.serverId, required this.contentId, required this.shardIndex, required this.error}): super._();
  

 final  String serverId;
 final  String contentId;
 final  int shardIndex;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_ShardRequestFailedCopyWith<NetworkEvent_ShardRequestFailed> get copyWith => _$NetworkEvent_ShardRequestFailedCopyWithImpl<NetworkEvent_ShardRequestFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_ShardRequestFailed&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.shardIndex, shardIndex) || other.shardIndex == shardIndex)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,shardIndex,error);

@override
String toString() {
  return 'NetworkEvent.shardRequestFailed(serverId: $serverId, contentId: $contentId, shardIndex: $shardIndex, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_ShardRequestFailedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_ShardRequestFailedCopyWith(NetworkEvent_ShardRequestFailed value, $Res Function(NetworkEvent_ShardRequestFailed) _then) = _$NetworkEvent_ShardRequestFailedCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, int shardIndex, String error
});




}
/// @nodoc
class _$NetworkEvent_ShardRequestFailedCopyWithImpl<$Res>
    implements $NetworkEvent_ShardRequestFailedCopyWith<$Res> {
  _$NetworkEvent_ShardRequestFailedCopyWithImpl(this._self, this._then);

  final NetworkEvent_ShardRequestFailed _self;
  final $Res Function(NetworkEvent_ShardRequestFailed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? shardIndex = null,Object? error = null,}) {
  return _then(NetworkEvent_ShardRequestFailed(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,shardIndex: null == shardIndex ? _self.shardIndex : shardIndex // ignore: cast_nullable_to_non_nullable
as int,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_VaultUploadProgress extends NetworkEvent {
  const NetworkEvent_VaultUploadProgress({required this.serverId, required this.contentId, required this.phase, required this.progress}): super._();
  

 final  String serverId;
 final  String contentId;
 final  String phase;
 final  double progress;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_VaultUploadProgressCopyWith<NetworkEvent_VaultUploadProgress> get copyWith => _$NetworkEvent_VaultUploadProgressCopyWithImpl<NetworkEvent_VaultUploadProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_VaultUploadProgress&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.progress, progress) || other.progress == progress));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,phase,progress);

@override
String toString() {
  return 'NetworkEvent.vaultUploadProgress(serverId: $serverId, contentId: $contentId, phase: $phase, progress: $progress)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_VaultUploadProgressCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_VaultUploadProgressCopyWith(NetworkEvent_VaultUploadProgress value, $Res Function(NetworkEvent_VaultUploadProgress) _then) = _$NetworkEvent_VaultUploadProgressCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, String phase, double progress
});




}
/// @nodoc
class _$NetworkEvent_VaultUploadProgressCopyWithImpl<$Res>
    implements $NetworkEvent_VaultUploadProgressCopyWith<$Res> {
  _$NetworkEvent_VaultUploadProgressCopyWithImpl(this._self, this._then);

  final NetworkEvent_VaultUploadProgress _self;
  final $Res Function(NetworkEvent_VaultUploadProgress) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? phase = null,Object? progress = null,}) {
  return _then(NetworkEvent_VaultUploadProgress(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,progress: null == progress ? _self.progress : progress // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class NetworkEvent_VaultUploadComplete extends NetworkEvent {
  const NetworkEvent_VaultUploadComplete({required this.serverId, required this.contentId, required this.channelId}): super._();
  

 final  String serverId;
 final  String contentId;
 final  String channelId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_VaultUploadCompleteCopyWith<NetworkEvent_VaultUploadComplete> get copyWith => _$NetworkEvent_VaultUploadCompleteCopyWithImpl<NetworkEvent_VaultUploadComplete>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_VaultUploadComplete&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.channelId, channelId) || other.channelId == channelId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,channelId);

@override
String toString() {
  return 'NetworkEvent.vaultUploadComplete(serverId: $serverId, contentId: $contentId, channelId: $channelId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_VaultUploadCompleteCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_VaultUploadCompleteCopyWith(NetworkEvent_VaultUploadComplete value, $Res Function(NetworkEvent_VaultUploadComplete) _then) = _$NetworkEvent_VaultUploadCompleteCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, String channelId
});




}
/// @nodoc
class _$NetworkEvent_VaultUploadCompleteCopyWithImpl<$Res>
    implements $NetworkEvent_VaultUploadCompleteCopyWith<$Res> {
  _$NetworkEvent_VaultUploadCompleteCopyWithImpl(this._self, this._then);

  final NetworkEvent_VaultUploadComplete _self;
  final $Res Function(NetworkEvent_VaultUploadComplete) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? channelId = null,}) {
  return _then(NetworkEvent_VaultUploadComplete(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,channelId: null == channelId ? _self.channelId : channelId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_VaultUploadFailed extends NetworkEvent {
  const NetworkEvent_VaultUploadFailed({required this.serverId, required this.contentId, required this.error}): super._();
  

 final  String serverId;
 final  String contentId;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_VaultUploadFailedCopyWith<NetworkEvent_VaultUploadFailed> get copyWith => _$NetworkEvent_VaultUploadFailedCopyWithImpl<NetworkEvent_VaultUploadFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_VaultUploadFailed&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,error);

@override
String toString() {
  return 'NetworkEvent.vaultUploadFailed(serverId: $serverId, contentId: $contentId, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_VaultUploadFailedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_VaultUploadFailedCopyWith(NetworkEvent_VaultUploadFailed value, $Res Function(NetworkEvent_VaultUploadFailed) _then) = _$NetworkEvent_VaultUploadFailedCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, String error
});




}
/// @nodoc
class _$NetworkEvent_VaultUploadFailedCopyWithImpl<$Res>
    implements $NetworkEvent_VaultUploadFailedCopyWith<$Res> {
  _$NetworkEvent_VaultUploadFailedCopyWithImpl(this._self, this._then);

  final NetworkEvent_VaultUploadFailed _self;
  final $Res Function(NetworkEvent_VaultUploadFailed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? error = null,}) {
  return _then(NetworkEvent_VaultUploadFailed(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_VaultDownloadProgress extends NetworkEvent {
  const NetworkEvent_VaultDownloadProgress({required this.serverId, required this.contentId, required this.phase, required this.progress}): super._();
  

 final  String serverId;
 final  String contentId;
 final  String phase;
 final  double progress;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_VaultDownloadProgressCopyWith<NetworkEvent_VaultDownloadProgress> get copyWith => _$NetworkEvent_VaultDownloadProgressCopyWithImpl<NetworkEvent_VaultDownloadProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_VaultDownloadProgress&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.progress, progress) || other.progress == progress));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,phase,progress);

@override
String toString() {
  return 'NetworkEvent.vaultDownloadProgress(serverId: $serverId, contentId: $contentId, phase: $phase, progress: $progress)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_VaultDownloadProgressCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_VaultDownloadProgressCopyWith(NetworkEvent_VaultDownloadProgress value, $Res Function(NetworkEvent_VaultDownloadProgress) _then) = _$NetworkEvent_VaultDownloadProgressCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, String phase, double progress
});




}
/// @nodoc
class _$NetworkEvent_VaultDownloadProgressCopyWithImpl<$Res>
    implements $NetworkEvent_VaultDownloadProgressCopyWith<$Res> {
  _$NetworkEvent_VaultDownloadProgressCopyWithImpl(this._self, this._then);

  final NetworkEvent_VaultDownloadProgress _self;
  final $Res Function(NetworkEvent_VaultDownloadProgress) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? phase = null,Object? progress = null,}) {
  return _then(NetworkEvent_VaultDownloadProgress(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,progress: null == progress ? _self.progress : progress // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class NetworkEvent_VaultDownloadComplete extends NetworkEvent {
  const NetworkEvent_VaultDownloadComplete({required this.serverId, required this.contentId, required this.diskPath}): super._();
  

 final  String serverId;
 final  String contentId;
 final  String diskPath;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_VaultDownloadCompleteCopyWith<NetworkEvent_VaultDownloadComplete> get copyWith => _$NetworkEvent_VaultDownloadCompleteCopyWithImpl<NetworkEvent_VaultDownloadComplete>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_VaultDownloadComplete&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.diskPath, diskPath) || other.diskPath == diskPath));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,diskPath);

@override
String toString() {
  return 'NetworkEvent.vaultDownloadComplete(serverId: $serverId, contentId: $contentId, diskPath: $diskPath)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_VaultDownloadCompleteCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_VaultDownloadCompleteCopyWith(NetworkEvent_VaultDownloadComplete value, $Res Function(NetworkEvent_VaultDownloadComplete) _then) = _$NetworkEvent_VaultDownloadCompleteCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, String diskPath
});




}
/// @nodoc
class _$NetworkEvent_VaultDownloadCompleteCopyWithImpl<$Res>
    implements $NetworkEvent_VaultDownloadCompleteCopyWith<$Res> {
  _$NetworkEvent_VaultDownloadCompleteCopyWithImpl(this._self, this._then);

  final NetworkEvent_VaultDownloadComplete _self;
  final $Res Function(NetworkEvent_VaultDownloadComplete) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? diskPath = null,}) {
  return _then(NetworkEvent_VaultDownloadComplete(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,diskPath: null == diskPath ? _self.diskPath : diskPath // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_VaultDownloadFailed extends NetworkEvent {
  const NetworkEvent_VaultDownloadFailed({required this.serverId, required this.contentId, required this.error}): super._();
  

 final  String serverId;
 final  String contentId;
 final  String error;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_VaultDownloadFailedCopyWith<NetworkEvent_VaultDownloadFailed> get copyWith => _$NetworkEvent_VaultDownloadFailedCopyWithImpl<NetworkEvent_VaultDownloadFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_VaultDownloadFailed&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,error);

@override
String toString() {
  return 'NetworkEvent.vaultDownloadFailed(serverId: $serverId, contentId: $contentId, error: $error)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_VaultDownloadFailedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_VaultDownloadFailedCopyWith(NetworkEvent_VaultDownloadFailed value, $Res Function(NetworkEvent_VaultDownloadFailed) _then) = _$NetworkEvent_VaultDownloadFailedCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, String error
});




}
/// @nodoc
class _$NetworkEvent_VaultDownloadFailedCopyWithImpl<$Res>
    implements $NetworkEvent_VaultDownloadFailedCopyWith<$Res> {
  _$NetworkEvent_VaultDownloadFailedCopyWithImpl(this._self, this._then);

  final NetworkEvent_VaultDownloadFailed _self;
  final $Res Function(NetworkEvent_VaultDownloadFailed) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? error = null,}) {
  return _then(NetworkEvent_VaultDownloadFailed(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_RebalanceStarted extends NetworkEvent {
  const NetworkEvent_RebalanceStarted({required this.serverId, required this.shardsToMove}): super._();
  

 final  String serverId;
 final  int shardsToMove;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_RebalanceStartedCopyWith<NetworkEvent_RebalanceStarted> get copyWith => _$NetworkEvent_RebalanceStartedCopyWithImpl<NetworkEvent_RebalanceStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_RebalanceStarted&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.shardsToMove, shardsToMove) || other.shardsToMove == shardsToMove));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,shardsToMove);

@override
String toString() {
  return 'NetworkEvent.rebalanceStarted(serverId: $serverId, shardsToMove: $shardsToMove)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_RebalanceStartedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_RebalanceStartedCopyWith(NetworkEvent_RebalanceStarted value, $Res Function(NetworkEvent_RebalanceStarted) _then) = _$NetworkEvent_RebalanceStartedCopyWithImpl;
@useResult
$Res call({
 String serverId, int shardsToMove
});




}
/// @nodoc
class _$NetworkEvent_RebalanceStartedCopyWithImpl<$Res>
    implements $NetworkEvent_RebalanceStartedCopyWith<$Res> {
  _$NetworkEvent_RebalanceStartedCopyWithImpl(this._self, this._then);

  final NetworkEvent_RebalanceStarted _self;
  final $Res Function(NetworkEvent_RebalanceStarted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? shardsToMove = null,}) {
  return _then(NetworkEvent_RebalanceStarted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,shardsToMove: null == shardsToMove ? _self.shardsToMove : shardsToMove // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NetworkEvent_RebalanceProgress extends NetworkEvent {
  const NetworkEvent_RebalanceProgress({required this.serverId, required this.moved, required this.total}): super._();
  

 final  String serverId;
 final  int moved;
 final  int total;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_RebalanceProgressCopyWith<NetworkEvent_RebalanceProgress> get copyWith => _$NetworkEvent_RebalanceProgressCopyWithImpl<NetworkEvent_RebalanceProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_RebalanceProgress&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.moved, moved) || other.moved == moved)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,moved,total);

@override
String toString() {
  return 'NetworkEvent.rebalanceProgress(serverId: $serverId, moved: $moved, total: $total)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_RebalanceProgressCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_RebalanceProgressCopyWith(NetworkEvent_RebalanceProgress value, $Res Function(NetworkEvent_RebalanceProgress) _then) = _$NetworkEvent_RebalanceProgressCopyWithImpl;
@useResult
$Res call({
 String serverId, int moved, int total
});




}
/// @nodoc
class _$NetworkEvent_RebalanceProgressCopyWithImpl<$Res>
    implements $NetworkEvent_RebalanceProgressCopyWith<$Res> {
  _$NetworkEvent_RebalanceProgressCopyWithImpl(this._self, this._then);

  final NetworkEvent_RebalanceProgress _self;
  final $Res Function(NetworkEvent_RebalanceProgress) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? moved = null,Object? total = null,}) {
  return _then(NetworkEvent_RebalanceProgress(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,moved: null == moved ? _self.moved : moved // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NetworkEvent_RebalanceCompleted extends NetworkEvent {
  const NetworkEvent_RebalanceCompleted({required this.serverId}): super._();
  

 final  String serverId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_RebalanceCompletedCopyWith<NetworkEvent_RebalanceCompleted> get copyWith => _$NetworkEvent_RebalanceCompletedCopyWithImpl<NetworkEvent_RebalanceCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_RebalanceCompleted&&(identical(other.serverId, serverId) || other.serverId == serverId));
}


@override
int get hashCode => Object.hash(runtimeType,serverId);

@override
String toString() {
  return 'NetworkEvent.rebalanceCompleted(serverId: $serverId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_RebalanceCompletedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_RebalanceCompletedCopyWith(NetworkEvent_RebalanceCompleted value, $Res Function(NetworkEvent_RebalanceCompleted) _then) = _$NetworkEvent_RebalanceCompletedCopyWithImpl;
@useResult
$Res call({
 String serverId
});




}
/// @nodoc
class _$NetworkEvent_RebalanceCompletedCopyWithImpl<$Res>
    implements $NetworkEvent_RebalanceCompletedCopyWith<$Res> {
  _$NetworkEvent_RebalanceCompletedCopyWithImpl(this._self, this._then);

  final NetworkEvent_RebalanceCompleted _self;
  final $Res Function(NetworkEvent_RebalanceCompleted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,}) {
  return _then(NetworkEvent_RebalanceCompleted(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_VaultUploadReplicationFallback extends NetworkEvent {
  const NetworkEvent_VaultUploadReplicationFallback({required this.serverId, required this.contentId, required this.online, required this.needed}): super._();
  

 final  String serverId;
 final  String contentId;
 final  BigInt online;
 final  BigInt needed;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_VaultUploadReplicationFallbackCopyWith<NetworkEvent_VaultUploadReplicationFallback> get copyWith => _$NetworkEvent_VaultUploadReplicationFallbackCopyWithImpl<NetworkEvent_VaultUploadReplicationFallback>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_VaultUploadReplicationFallback&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.contentId, contentId) || other.contentId == contentId)&&(identical(other.online, online) || other.online == online)&&(identical(other.needed, needed) || other.needed == needed));
}


@override
int get hashCode => Object.hash(runtimeType,serverId,contentId,online,needed);

@override
String toString() {
  return 'NetworkEvent.vaultUploadReplicationFallback(serverId: $serverId, contentId: $contentId, online: $online, needed: $needed)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_VaultUploadReplicationFallbackCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_VaultUploadReplicationFallbackCopyWith(NetworkEvent_VaultUploadReplicationFallback value, $Res Function(NetworkEvent_VaultUploadReplicationFallback) _then) = _$NetworkEvent_VaultUploadReplicationFallbackCopyWithImpl;
@useResult
$Res call({
 String serverId, String contentId, BigInt online, BigInt needed
});




}
/// @nodoc
class _$NetworkEvent_VaultUploadReplicationFallbackCopyWithImpl<$Res>
    implements $NetworkEvent_VaultUploadReplicationFallbackCopyWith<$Res> {
  _$NetworkEvent_VaultUploadReplicationFallbackCopyWithImpl(this._self, this._then);

  final NetworkEvent_VaultUploadReplicationFallback _self;
  final $Res Function(NetworkEvent_VaultUploadReplicationFallback) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? contentId = null,Object? online = null,Object? needed = null,}) {
  return _then(NetworkEvent_VaultUploadReplicationFallback(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,contentId: null == contentId ? _self.contentId : contentId // ignore: cast_nullable_to_non_nullable
as String,online: null == online ? _self.online : online // ignore: cast_nullable_to_non_nullable
as BigInt,needed: null == needed ? _self.needed : needed // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class NetworkEvent_KeyExchangeStarted extends NetworkEvent {
  const NetworkEvent_KeyExchangeStarted({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_KeyExchangeStartedCopyWith<NetworkEvent_KeyExchangeStarted> get copyWith => _$NetworkEvent_KeyExchangeStartedCopyWithImpl<NetworkEvent_KeyExchangeStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_KeyExchangeStarted&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'NetworkEvent.keyExchangeStarted(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_KeyExchangeStartedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_KeyExchangeStartedCopyWith(NetworkEvent_KeyExchangeStarted value, $Res Function(NetworkEvent_KeyExchangeStarted) _then) = _$NetworkEvent_KeyExchangeStartedCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$NetworkEvent_KeyExchangeStartedCopyWithImpl<$Res>
    implements $NetworkEvent_KeyExchangeStartedCopyWith<$Res> {
  _$NetworkEvent_KeyExchangeStartedCopyWithImpl(this._self, this._then);

  final NetworkEvent_KeyExchangeStarted _self;
  final $Res Function(NetworkEvent_KeyExchangeStarted) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(NetworkEvent_KeyExchangeStarted(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_KeyExchangeProgress extends NetworkEvent {
  const NetworkEvent_KeyExchangeProgress({required this.peerId, required this.stage}): super._();
  

 final  String peerId;
 final  String stage;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_KeyExchangeProgressCopyWith<NetworkEvent_KeyExchangeProgress> get copyWith => _$NetworkEvent_KeyExchangeProgressCopyWithImpl<NetworkEvent_KeyExchangeProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_KeyExchangeProgress&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.stage, stage) || other.stage == stage));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,stage);

@override
String toString() {
  return 'NetworkEvent.keyExchangeProgress(peerId: $peerId, stage: $stage)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_KeyExchangeProgressCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_KeyExchangeProgressCopyWith(NetworkEvent_KeyExchangeProgress value, $Res Function(NetworkEvent_KeyExchangeProgress) _then) = _$NetworkEvent_KeyExchangeProgressCopyWithImpl;
@useResult
$Res call({
 String peerId, String stage
});




}
/// @nodoc
class _$NetworkEvent_KeyExchangeProgressCopyWithImpl<$Res>
    implements $NetworkEvent_KeyExchangeProgressCopyWith<$Res> {
  _$NetworkEvent_KeyExchangeProgressCopyWithImpl(this._self, this._then);

  final NetworkEvent_KeyExchangeProgress _self;
  final $Res Function(NetworkEvent_KeyExchangeProgress) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? stage = null,}) {
  return _then(NetworkEvent_KeyExchangeProgress(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,stage: null == stage ? _self.stage : stage // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_WebRtcSignal extends NetworkEvent {
  const NetworkEvent_WebRtcSignal({required this.peerId, required this.signalType, required this.payload, required this.connId}): super._();
  

 final  String peerId;
 final  String signalType;
 final  String payload;
 final  String connId;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_WebRtcSignalCopyWith<NetworkEvent_WebRtcSignal> get copyWith => _$NetworkEvent_WebRtcSignalCopyWithImpl<NetworkEvent_WebRtcSignal>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_WebRtcSignal&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.signalType, signalType) || other.signalType == signalType)&&(identical(other.payload, payload) || other.payload == payload)&&(identical(other.connId, connId) || other.connId == connId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,signalType,payload,connId);

@override
String toString() {
  return 'NetworkEvent.webRtcSignal(peerId: $peerId, signalType: $signalType, payload: $payload, connId: $connId)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_WebRtcSignalCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_WebRtcSignalCopyWith(NetworkEvent_WebRtcSignal value, $Res Function(NetworkEvent_WebRtcSignal) _then) = _$NetworkEvent_WebRtcSignalCopyWithImpl;
@useResult
$Res call({
 String peerId, String signalType, String payload, String connId
});




}
/// @nodoc
class _$NetworkEvent_WebRtcSignalCopyWithImpl<$Res>
    implements $NetworkEvent_WebRtcSignalCopyWith<$Res> {
  _$NetworkEvent_WebRtcSignalCopyWithImpl(this._self, this._then);

  final NetworkEvent_WebRtcSignal _self;
  final $Res Function(NetworkEvent_WebRtcSignal) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? signalType = null,Object? payload = null,Object? connId = null,}) {
  return _then(NetworkEvent_WebRtcSignal(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,signalType: null == signalType ? _self.signalType : signalType // ignore: cast_nullable_to_non_nullable
as String,payload: null == payload ? _self.payload : payload // ignore: cast_nullable_to_non_nullable
as String,connId: null == connId ? _self.connId : connId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NetworkEvent_WebRtcSendFile extends NetworkEvent {
  const NetworkEvent_WebRtcSendFile({required this.peerId, required this.transferId, required this.filePath, required this.totalSize, required this.kind, required this.shardIndex}): super._();
  

 final  String peerId;
 final  String transferId;
 final  String filePath;
 final  BigInt totalSize;
 final  String kind;
 final  int shardIndex;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_WebRtcSendFileCopyWith<NetworkEvent_WebRtcSendFile> get copyWith => _$NetworkEvent_WebRtcSendFileCopyWithImpl<NetworkEvent_WebRtcSendFile>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_WebRtcSendFile&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.transferId, transferId) || other.transferId == transferId)&&(identical(other.filePath, filePath) || other.filePath == filePath)&&(identical(other.totalSize, totalSize) || other.totalSize == totalSize)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.shardIndex, shardIndex) || other.shardIndex == shardIndex));
}


@override
int get hashCode => Object.hash(runtimeType,peerId,transferId,filePath,totalSize,kind,shardIndex);

@override
String toString() {
  return 'NetworkEvent.webRtcSendFile(peerId: $peerId, transferId: $transferId, filePath: $filePath, totalSize: $totalSize, kind: $kind, shardIndex: $shardIndex)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_WebRtcSendFileCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_WebRtcSendFileCopyWith(NetworkEvent_WebRtcSendFile value, $Res Function(NetworkEvent_WebRtcSendFile) _then) = _$NetworkEvent_WebRtcSendFileCopyWithImpl;
@useResult
$Res call({
 String peerId, String transferId, String filePath, BigInt totalSize, String kind, int shardIndex
});




}
/// @nodoc
class _$NetworkEvent_WebRtcSendFileCopyWithImpl<$Res>
    implements $NetworkEvent_WebRtcSendFileCopyWith<$Res> {
  _$NetworkEvent_WebRtcSendFileCopyWithImpl(this._self, this._then);

  final NetworkEvent_WebRtcSendFile _self;
  final $Res Function(NetworkEvent_WebRtcSendFile) _then;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? transferId = null,Object? filePath = null,Object? totalSize = null,Object? kind = null,Object? shardIndex = null,}) {
  return _then(NetworkEvent_WebRtcSendFile(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,transferId: null == transferId ? _self.transferId : transferId // ignore: cast_nullable_to_non_nullable
as String,filePath: null == filePath ? _self.filePath : filePath // ignore: cast_nullable_to_non_nullable
as String,totalSize: null == totalSize ? _self.totalSize : totalSize // ignore: cast_nullable_to_non_nullable
as BigInt,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,shardIndex: null == shardIndex ? _self.shardIndex : shardIndex // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
