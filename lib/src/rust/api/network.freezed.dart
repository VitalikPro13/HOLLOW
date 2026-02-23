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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( NetworkEvent_PeerDiscovered value)?  peerDiscovered,TResult Function( NetworkEvent_PeerExpired value)?  peerExpired,TResult Function( NetworkEvent_Listening value)?  listening,TResult Function( NetworkEvent_MessageReceived value)?  messageReceived,TResult Function( NetworkEvent_MessageSent value)?  messageSent,TResult Function( NetworkEvent_MessageSendFailed value)?  messageSendFailed,TResult Function( NetworkEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case NetworkEvent_Listening() when listening != null:
return listening(_that);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that);case NetworkEvent_Error() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( NetworkEvent_PeerDiscovered value)  peerDiscovered,required TResult Function( NetworkEvent_PeerExpired value)  peerExpired,required TResult Function( NetworkEvent_Listening value)  listening,required TResult Function( NetworkEvent_MessageReceived value)  messageReceived,required TResult Function( NetworkEvent_MessageSent value)  messageSent,required TResult Function( NetworkEvent_MessageSendFailed value)  messageSendFailed,required TResult Function( NetworkEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered():
return peerDiscovered(_that);case NetworkEvent_PeerExpired():
return peerExpired(_that);case NetworkEvent_Listening():
return listening(_that);case NetworkEvent_MessageReceived():
return messageReceived(_that);case NetworkEvent_MessageSent():
return messageSent(_that);case NetworkEvent_MessageSendFailed():
return messageSendFailed(_that);case NetworkEvent_Error():
return error(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( NetworkEvent_PeerDiscovered value)?  peerDiscovered,TResult? Function( NetworkEvent_PeerExpired value)?  peerExpired,TResult? Function( NetworkEvent_Listening value)?  listening,TResult? Function( NetworkEvent_MessageReceived value)?  messageReceived,TResult? Function( NetworkEvent_MessageSent value)?  messageSent,TResult? Function( NetworkEvent_MessageSendFailed value)?  messageSendFailed,TResult? Function( NetworkEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case NetworkEvent_Listening() when listening != null:
return listening(_that);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that);case NetworkEvent_Error() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( DiscoveredPeer peer)?  peerDiscovered,TResult Function( String peerId)?  peerExpired,TResult Function( String address)?  listening,TResult Function( String fromPeer,  String text)?  messageReceived,TResult Function( String toPeer)?  messageSent,TResult Function( String toPeer,  String error)?  messageSendFailed,TResult Function( String message)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case NetworkEvent_Listening() when listening != null:
return listening(_that.address);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that.fromPeer,_that.text);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_Error() when error != null:
return error(_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( DiscoveredPeer peer)  peerDiscovered,required TResult Function( String peerId)  peerExpired,required TResult Function( String address)  listening,required TResult Function( String fromPeer,  String text)  messageReceived,required TResult Function( String toPeer)  messageSent,required TResult Function( String toPeer,  String error)  messageSendFailed,required TResult Function( String message)  error,}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered():
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired():
return peerExpired(_that.peerId);case NetworkEvent_Listening():
return listening(_that.address);case NetworkEvent_MessageReceived():
return messageReceived(_that.fromPeer,_that.text);case NetworkEvent_MessageSent():
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed():
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_Error():
return error(_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( DiscoveredPeer peer)?  peerDiscovered,TResult? Function( String peerId)?  peerExpired,TResult? Function( String address)?  listening,TResult? Function( String fromPeer,  String text)?  messageReceived,TResult? Function( String toPeer)?  messageSent,TResult? Function( String toPeer,  String error)?  messageSendFailed,TResult? Function( String message)?  error,}) {final _that = this;
switch (_that) {
case NetworkEvent_PeerDiscovered() when peerDiscovered != null:
return peerDiscovered(_that.peer);case NetworkEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case NetworkEvent_Listening() when listening != null:
return listening(_that.address);case NetworkEvent_MessageReceived() when messageReceived != null:
return messageReceived(_that.fromPeer,_that.text);case NetworkEvent_MessageSent() when messageSent != null:
return messageSent(_that.toPeer);case NetworkEvent_MessageSendFailed() when messageSendFailed != null:
return messageSendFailed(_that.toPeer,_that.error);case NetworkEvent_Error() when error != null:
return error(_that.message);case _:
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

// dart format on
