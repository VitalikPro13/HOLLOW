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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( NetworkEvent_PeerDiscovered value)?  peerDiscovered,TResult Function( NetworkEvent_PeerExpired value)?  peerExpired,TResult Function( NetworkEvent_PeerDisconnected value)?  peerDisconnected,TResult Function( NetworkEvent_RoomCleared value)?  roomCleared,TResult Function( NetworkEvent_Listening value)?  listening,TResult Function( NetworkEvent_MessageReceived value)?  messageReceived,TResult Function( NetworkEvent_MessageSent value)?  messageSent,TResult Function( NetworkEvent_MessageSendFailed value)?  messageSendFailed,TResult Function( NetworkEvent_SessionEstablished value)?  sessionEstablished,TResult Function( NetworkEvent_Error value)?  error,TResult Function( NetworkEvent_ServerCreated value)?  serverCreated,TResult Function( NetworkEvent_ServerUpdated value)?  serverUpdated,TResult Function( NetworkEvent_ChannelAdded value)?  channelAdded,TResult Function( NetworkEvent_ChannelRemoved value)?  channelRemoved,TResult Function( NetworkEvent_MemberJoined value)?  memberJoined,TResult Function( NetworkEvent_MemberLeft value)?  memberLeft,TResult Function( NetworkEvent_SyncCompleted value)?  syncCompleted,required TResult orElse(),}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared(_that);case NetworkEvent_Listening() when listening != null:
return listening(_that);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that);case NetworkEvent_Error() when error != null:
return error(_that);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( NetworkEvent_PeerDiscovered value)  peerDiscovered,required TResult Function( NetworkEvent_PeerExpired value)  peerExpired,required TResult Function( NetworkEvent_PeerDisconnected value)  peerDisconnected,required TResult Function( NetworkEvent_RoomCleared value)  roomCleared,required TResult Function( NetworkEvent_Listening value)  listening,required TResult Function( NetworkEvent_MessageReceived value)  messageReceived,required TResult Function( NetworkEvent_MessageSent value)  messageSent,required TResult Function( NetworkEvent_MessageSendFailed value)  messageSendFailed,required TResult Function( NetworkEvent_SessionEstablished value)  sessionEstablished,required TResult Function( NetworkEvent_Error value)  error,required TResult Function( NetworkEvent_ServerCreated value)  serverCreated,required TResult Function( NetworkEvent_ServerUpdated value)  serverUpdated,required TResult Function( NetworkEvent_ChannelAdded value)  channelAdded,required TResult Function( NetworkEvent_ChannelRemoved value)  channelRemoved,required TResult Function( NetworkEvent_MemberJoined value)  memberJoined,required TResult Function( NetworkEvent_MemberLeft value)  memberLeft,required TResult Function( NetworkEvent_SyncCompleted value)  syncCompleted,}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered():
return peerDiscovered(_that);case NetworkEvent_PeerExpired():
return peerExpired(_that);case NetworkEvent_PeerDisconnected():
return peerDisconnected(_that);case NetworkEvent_RoomCleared():
return roomCleared(_that);case NetworkEvent_Listening():
return listening(_that);case NetworkEvent_MessageReceived():
return messageReceived(_that);case NetworkEvent_MessageSent():
return messageSent(_that);case NetworkEvent_MessageSendFailed():
return messageSendFailed(_that);case NetworkEvent_SessionEstablished():
return sessionEstablished(_that);case NetworkEvent_Error():
return error(_that);case NetworkEvent_ServerCreated():
return serverCreated(_that);case NetworkEvent_ServerUpdated():
return serverUpdated(_that);case NetworkEvent_ChannelAdded():
return channelAdded(_that);case NetworkEvent_ChannelRemoved():
return channelRemoved(_that);case NetworkEvent_MemberJoined():
return memberJoined(_that);case NetworkEvent_MemberLeft():
return memberLeft(_that);case NetworkEvent_SyncCompleted():
return syncCompleted(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( NetworkEvent_PeerDiscovered value)?  peerDiscovered,TResult? Function( NetworkEvent_PeerExpired value)?  peerExpired,TResult? Function( NetworkEvent_PeerDisconnected value)?  peerDisconnected,TResult? Function( NetworkEvent_RoomCleared value)?  roomCleared,TResult? Function( NetworkEvent_Listening value)?  listening,TResult? Function( NetworkEvent_MessageReceived value)?  messageReceived,TResult? Function( NetworkEvent_MessageSent value)?  messageSent,TResult? Function( NetworkEvent_MessageSendFailed value)?  messageSendFailed,TResult? Function( NetworkEvent_SessionEstablished value)?  sessionEstablished,TResult? Function( NetworkEvent_Error value)?  error,TResult? Function( NetworkEvent_ServerCreated value)?  serverCreated,TResult? Function( NetworkEvent_ServerUpdated value)?  serverUpdated,TResult? Function( NetworkEvent_ChannelAdded value)?  channelAdded,TResult? Function( NetworkEvent_ChannelRemoved value)?  channelRemoved,TResult? Function( NetworkEvent_MemberJoined value)?  memberJoined,TResult? Function( NetworkEvent_MemberLeft value)?  memberLeft,TResult? Function( NetworkEvent_SyncCompleted value)?  syncCompleted,}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared(_that);case NetworkEvent_Listening() when listening != null:
return listening(_that);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that);case NetworkEvent_Error() when error != null:
return error(_that);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( DiscoveredPeer peer)?  peerDiscovered,TResult Function( String peerId)?  peerExpired,TResult Function( String peerId)?  peerDisconnected,TResult Function()?  roomCleared,TResult Function( String address)?  listening,TResult Function( String fromPeer,  String text)?  messageReceived,TResult Function( String toPeer)?  messageSent,TResult Function( String toPeer,  String error)?  messageSendFailed,TResult Function( String peerId)?  sessionEstablished,TResult Function( String message)?  error,TResult Function( String serverId,  String name)?  serverCreated,TResult Function( String serverId)?  serverUpdated,TResult Function( String serverId,  String channelId,  String name)?  channelAdded,TResult Function( String serverId,  String channelId)?  channelRemoved,TResult Function( String serverId,  String peerId)?  memberJoined,TResult Function( String serverId,  String peerId)?  memberLeft,TResult Function( String serverId,  int opsApplied)?  syncCompleted,required TResult orElse(),}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that.peerId);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared();case NetworkEvent_Listening() when listening != null:
return listening(_that.address);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that.fromPeer,_that.text);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that.peerId);case NetworkEvent_Error() when error != null:
return error(_that.message);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that.serverId,_that.name);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that.serverId);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that.serverId,_that.channelId,_that.name);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that.serverId,_that.channelId);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that.serverId,_that.peerId);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that.serverId,_that.peerId);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that.serverId,_that.opsApplied);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( DiscoveredPeer peer)  peerDiscovered,required TResult Function( String peerId)  peerExpired,required TResult Function( String peerId)  peerDisconnected,required TResult Function()  roomCleared,required TResult Function( String address)  listening,required TResult Function( String fromPeer,  String text)  messageReceived,required TResult Function( String toPeer)  messageSent,required TResult Function( String toPeer,  String error)  messageSendFailed,required TResult Function( String peerId)  sessionEstablished,required TResult Function( String message)  error,required TResult Function( String serverId,  String name)  serverCreated,required TResult Function( String serverId)  serverUpdated,required TResult Function( String serverId,  String channelId,  String name)  channelAdded,required TResult Function( String serverId,  String channelId)  channelRemoved,required TResult Function( String serverId,  String peerId)  memberJoined,required TResult Function( String serverId,  String peerId)  memberLeft,required TResult Function( String serverId,  int opsApplied)  syncCompleted,}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered():
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired():
return peerExpired(_that.peerId);case NetworkEvent_PeerDisconnected():
return peerDisconnected(_that.peerId);case NetworkEvent_RoomCleared():
return roomCleared();case NetworkEvent_Listening():
return listening(_that.address);case NetworkEvent_MessageReceived():
return messageReceived(_that.fromPeer,_that.text);case NetworkEvent_MessageSent():
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed():
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_SessionEstablished():
return sessionEstablished(_that.peerId);case NetworkEvent_Error():
return error(_that.message);case NetworkEvent_ServerCreated():
return serverCreated(_that.serverId,_that.name);case NetworkEvent_ServerUpdated():
return serverUpdated(_that.serverId);case NetworkEvent_ChannelAdded():
return channelAdded(_that.serverId,_that.channelId,_that.name);case NetworkEvent_ChannelRemoved():
return channelRemoved(_that.serverId,_that.channelId);case NetworkEvent_MemberJoined():
return memberJoined(_that.serverId,_that.peerId);case NetworkEvent_MemberLeft():
return memberLeft(_that.serverId,_that.peerId);case NetworkEvent_SyncCompleted():
return syncCompleted(_that.serverId,_that.opsApplied);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( DiscoveredPeer peer)?  peerDiscovered,TResult? Function( String peerId)?  peerExpired,TResult? Function( String peerId)?  peerDisconnected,TResult? Function()?  roomCleared,TResult? Function( String address)?  listening,TResult? Function( String fromPeer,  String text)?  messageReceived,TResult? Function( String toPeer)?  messageSent,TResult? Function( String toPeer,  String error)?  messageSendFailed,TResult? Function( String peerId)?  sessionEstablished,TResult? Function( String message)?  error,TResult? Function( String serverId,  String name)?  serverCreated,TResult? Function( String serverId)?  serverUpdated,TResult? Function( String serverId,  String channelId,  String name)?  channelAdded,TResult? Function( String serverId,  String channelId)?  channelRemoved,TResult? Function( String serverId,  String peerId)?  memberJoined,TResult? Function( String serverId,  String peerId)?  memberLeft,TResult? Function( String serverId,  int opsApplied)?  syncCompleted,}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case NetworkEvent_PeerDisconnected() when peerDisconnected != null:
return peerDisconnected(_that.peerId);case NetworkEvent_RoomCleared() when roomCleared != null:
return roomCleared();case NetworkEvent_Listening() when listening != null:
return listening(_that.address);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that.fromPeer,_that.text);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_SessionEstablished() when sessionEstablished != null:
return sessionEstablished(_that.peerId);case NetworkEvent_Error() when error != null:
return error(_that.message);case NetworkEvent_ServerCreated() when serverCreated != null:
return serverCreated(_that.serverId,_that.name);case NetworkEvent_ServerUpdated() when serverUpdated != null:
return serverUpdated(_that.serverId);case NetworkEvent_ChannelAdded() when channelAdded != null:
return channelAdded(_that.serverId,_that.channelId,_that.name);case NetworkEvent_ChannelRemoved() when channelRemoved != null:
return channelRemoved(_that.serverId,_that.channelId);case NetworkEvent_MemberJoined() when memberJoined != null:
return memberJoined(_that.serverId,_that.peerId);case NetworkEvent_MemberLeft() when memberLeft != null:
return memberLeft(_that.serverId,_that.peerId);case NetworkEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that.serverId,_that.opsApplied);case _:
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
  const NetworkEvent_MessageReceived({required this.fromPeer, required this.text}): super._();
  

 final  String fromPeer;
 final  String text;

/// Create a copy of NetworkEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NetworkEvent_MessageReceivedCopyWith<NetworkEvent_MessageReceived> get copyWith => _$NetworkEvent_MessageReceivedCopyWithImpl<NetworkEvent_MessageReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NetworkEvent_MessageReceived&&(identical(other.fromPeer, fromPeer) || other.fromPeer == fromPeer)&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,fromPeer,text);

@override
String toString() {
  return 'NetworkEvent.messageReceived(fromPeer: $fromPeer, text: $text)';
}


}

/// @nodoc
abstract mixin class $NetworkEvent_MessageReceivedCopyWith<$Res> implements $NetworkEventCopyWith<$Res> {
  factory $NetworkEvent_MessageReceivedCopyWith(NetworkEvent_MessageReceived value, $Res Function(NetworkEvent_MessageReceived) _then) = _$NetworkEvent_MessageReceivedCopyWithImpl;
@useResult
$Res call({
 String fromPeer, String text
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
@pragma('vm:prefer-inline') $Res call({Object? fromPeer = null,Object? text = null,}) {
  return _then(NetworkEvent_MessageReceived(
fromPeer: null == fromPeer ? _self.fromPeer : fromPeer // ignore: cast_nullable_to_non_nullable
as String,text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
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

// dart format on
