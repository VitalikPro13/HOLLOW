// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'identity.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$RestoreOutcome {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RestoreOutcome);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'RestoreOutcome()';
}


}

/// @nodoc
class $RestoreOutcomeCopyWith<$Res>  {
$RestoreOutcomeCopyWith(RestoreOutcome _, $Res Function(RestoreOutcome) __);
}


/// Adds pattern-matching-related methods to [RestoreOutcome].
extension RestoreOutcomePatterns on RestoreOutcome {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( RestoreOutcome_Restored value)?  restored,TResult Function( RestoreOutcome_KeptMatch value)?  keptMatch,TResult Function( RestoreOutcome_KeptNoneOpens value)?  keptNoneOpens,required TResult orElse(),}){
final _that = this;
switch (_that) {
case RestoreOutcome_Restored() when restored != null:
return restored(_that);case RestoreOutcome_KeptMatch() when keptMatch != null:
return keptMatch(_that);case RestoreOutcome_KeptNoneOpens() when keptNoneOpens != null:
return keptNoneOpens(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( RestoreOutcome_Restored value)  restored,required TResult Function( RestoreOutcome_KeptMatch value)  keptMatch,required TResult Function( RestoreOutcome_KeptNoneOpens value)  keptNoneOpens,}){
final _that = this;
switch (_that) {
case RestoreOutcome_Restored():
return restored(_that);case RestoreOutcome_KeptMatch():
return keptMatch(_that);case RestoreOutcome_KeptNoneOpens():
return keptNoneOpens(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( RestoreOutcome_Restored value)?  restored,TResult? Function( RestoreOutcome_KeptMatch value)?  keptMatch,TResult? Function( RestoreOutcome_KeptNoneOpens value)?  keptNoneOpens,}){
final _that = this;
switch (_that) {
case RestoreOutcome_Restored() when restored != null:
return restored(_that);case RestoreOutcome_KeptMatch() when keptMatch != null:
return keptMatch(_that);case RestoreOutcome_KeptNoneOpens() when keptNoneOpens != null:
return keptNoneOpens(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( bool lockedToKeychain)?  restored,TResult Function( String path,  String? profileName)?  keptMatch,TResult Function()?  keptNoneOpens,required TResult orElse(),}) {final _that = this;
switch (_that) {
case RestoreOutcome_Restored() when restored != null:
return restored(_that.lockedToKeychain);case RestoreOutcome_KeptMatch() when keptMatch != null:
return keptMatch(_that.path,_that.profileName);case RestoreOutcome_KeptNoneOpens() when keptNoneOpens != null:
return keptNoneOpens();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( bool lockedToKeychain)  restored,required TResult Function( String path,  String? profileName)  keptMatch,required TResult Function()  keptNoneOpens,}) {final _that = this;
switch (_that) {
case RestoreOutcome_Restored():
return restored(_that.lockedToKeychain);case RestoreOutcome_KeptMatch():
return keptMatch(_that.path,_that.profileName);case RestoreOutcome_KeptNoneOpens():
return keptNoneOpens();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( bool lockedToKeychain)?  restored,TResult? Function( String path,  String? profileName)?  keptMatch,TResult? Function()?  keptNoneOpens,}) {final _that = this;
switch (_that) {
case RestoreOutcome_Restored() when restored != null:
return restored(_that.lockedToKeychain);case RestoreOutcome_KeptMatch() when keptMatch != null:
return keptMatch(_that.path,_that.profileName);case RestoreOutcome_KeptNoneOpens() when keptNoneOpens != null:
return keptNoneOpens();case _:
  return null;

}
}

}

/// @nodoc


class RestoreOutcome_Restored extends RestoreOutcome {
  const RestoreOutcome_Restored({required this.lockedToKeychain}): super._();
  

/// The keychain default ran (Windows and macOS OS data root, no `.locked` pair):
/// show its toast. False: set the protection offer due.
 final  bool lockedToKeychain;

/// Create a copy of RestoreOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RestoreOutcome_RestoredCopyWith<RestoreOutcome_Restored> get copyWith => _$RestoreOutcome_RestoredCopyWithImpl<RestoreOutcome_Restored>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RestoreOutcome_Restored&&(identical(other.lockedToKeychain, lockedToKeychain) || other.lockedToKeychain == lockedToKeychain));
}


@override
int get hashCode {
    return Object.hash(runtimeType,lockedToKeychain);
}

@override
String toString() {
    return 'RestoreOutcome.restored(lockedToKeychain: $lockedToKeychain)';
}


}

/// @nodoc
abstract mixin class $RestoreOutcome_RestoredCopyWith<$Res> implements $RestoreOutcomeCopyWith<$Res> {
  factory $RestoreOutcome_RestoredCopyWith(RestoreOutcome_Restored value, $Res Function(RestoreOutcome_Restored) _then) = _$RestoreOutcome_RestoredCopyWithImpl;
@useResult
$Res call({
 bool lockedToKeychain
});




}
/// @nodoc
class _$RestoreOutcome_RestoredCopyWithImpl<$Res>
    implements $RestoreOutcome_RestoredCopyWith<$Res> {
  _$RestoreOutcome_RestoredCopyWithImpl(this._self, this._then);

  final RestoreOutcome_Restored _self;
  final $Res Function(RestoreOutcome_Restored) _then;

/// Create a copy of RestoreOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? lockedToKeychain = null,}) {
  return _then(RestoreOutcome_Restored(
lockedToKeychain: null == lockedToKeychain ? _self.lockedToKeychain : lockedToKeychain // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class RestoreOutcome_KeptMatch extends RestoreOutcome {
  const RestoreOutcome_KeptMatch({required this.path, this.profileName}): super._();
  

 final  String path;
 final  String? profileName;

/// Create a copy of RestoreOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RestoreOutcome_KeptMatchCopyWith<RestoreOutcome_KeptMatch> get copyWith => _$RestoreOutcome_KeptMatchCopyWithImpl<RestoreOutcome_KeptMatch>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RestoreOutcome_KeptMatch&&(identical(other.path, path) || other.path == path)&&(identical(other.profileName, profileName) || other.profileName == profileName));
}


@override
int get hashCode {
    return Object.hash(runtimeType,path,profileName);
}

@override
String toString() {
    return 'RestoreOutcome.keptMatch(path: $path, profileName: $profileName)';
}


}

/// @nodoc
abstract mixin class $RestoreOutcome_KeptMatchCopyWith<$Res> implements $RestoreOutcomeCopyWith<$Res> {
  factory $RestoreOutcome_KeptMatchCopyWith(RestoreOutcome_KeptMatch value, $Res Function(RestoreOutcome_KeptMatch) _then) = _$RestoreOutcome_KeptMatchCopyWithImpl;
@useResult
$Res call({
 String path, String? profileName
});




}
/// @nodoc
class _$RestoreOutcome_KeptMatchCopyWithImpl<$Res>
    implements $RestoreOutcome_KeptMatchCopyWith<$Res> {
  _$RestoreOutcome_KeptMatchCopyWithImpl(this._self, this._then);

  final RestoreOutcome_KeptMatch _self;
  final $Res Function(RestoreOutcome_KeptMatch) _then;

/// Create a copy of RestoreOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,Object? profileName = freezed,}) {
  return _then(RestoreOutcome_KeptMatch(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,profileName: freezed == profileName ? _self.profileName : profileName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class RestoreOutcome_KeptNoneOpens extends RestoreOutcome {
  const RestoreOutcome_KeptNoneOpens(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RestoreOutcome_KeptNoneOpens);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'RestoreOutcome.keptNoneOpens()';
}


}




/// @nodoc
mixin _$WelcomeRestoreMode {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is WelcomeRestoreMode);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'WelcomeRestoreMode()';
}


}

/// @nodoc
class $WelcomeRestoreModeCopyWith<$Res>  {
$WelcomeRestoreModeCopyWith(WelcomeRestoreMode _, $Res Function(WelcomeRestoreMode) __);
}


/// Adds pattern-matching-related methods to [WelcomeRestoreMode].
extension WelcomeRestoreModePatterns on WelcomeRestoreMode {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( WelcomeRestoreMode_Admit value)?  admit,TResult Function( WelcomeRestoreMode_Recover value)?  recover,required TResult orElse(),}){
final _that = this;
switch (_that) {
case WelcomeRestoreMode_Admit() when admit != null:
return admit(_that);case WelcomeRestoreMode_Recover() when recover != null:
return recover(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( WelcomeRestoreMode_Admit value)  admit,required TResult Function( WelcomeRestoreMode_Recover value)  recover,}){
final _that = this;
switch (_that) {
case WelcomeRestoreMode_Admit():
return admit(_that);case WelcomeRestoreMode_Recover():
return recover(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( WelcomeRestoreMode_Admit value)?  admit,TResult? Function( WelcomeRestoreMode_Recover value)?  recover,}){
final _that = this;
switch (_that) {
case WelcomeRestoreMode_Admit() when admit != null:
return admit(_that);case WelcomeRestoreMode_Recover() when recover != null:
return recover(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  admit,TResult Function( PlatformInt64 lostSinceMs)?  recover,required TResult orElse(),}) {final _that = this;
switch (_that) {
case WelcomeRestoreMode_Admit() when admit != null:
return admit();case WelcomeRestoreMode_Recover() when recover != null:
return recover(_that.lostSinceMs);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  admit,required TResult Function( PlatformInt64 lostSinceMs)  recover,}) {final _that = this;
switch (_that) {
case WelcomeRestoreMode_Admit():
return admit();case WelcomeRestoreMode_Recover():
return recover(_that.lostSinceMs);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  admit,TResult? Function( PlatformInt64 lostSinceMs)?  recover,}) {final _that = this;
switch (_that) {
case WelcomeRestoreMode_Admit() when admit != null:
return admit();case WelcomeRestoreMode_Recover() when recover != null:
return recover(_that.lostSinceMs);case _:
  return null;

}
}

}

/// @nodoc


class WelcomeRestoreMode_Admit extends WelcomeRestoreMode {
  const WelcomeRestoreMode_Admit(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is WelcomeRestoreMode_Admit);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'WelcomeRestoreMode.admit()';
}


}




/// @nodoc


class WelcomeRestoreMode_Recover extends WelcomeRestoreMode {
  const WelcomeRestoreMode_Recover({required this.lostSinceMs}): super._();
  

 final  PlatformInt64 lostSinceMs;

/// Create a copy of WelcomeRestoreMode
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WelcomeRestoreMode_RecoverCopyWith<WelcomeRestoreMode_Recover> get copyWith => _$WelcomeRestoreMode_RecoverCopyWithImpl<WelcomeRestoreMode_Recover>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is WelcomeRestoreMode_Recover&&(identical(other.lostSinceMs, lostSinceMs) || other.lostSinceMs == lostSinceMs));
}


@override
int get hashCode {
    return Object.hash(runtimeType,lostSinceMs);
}

@override
String toString() {
    return 'WelcomeRestoreMode.recover(lostSinceMs: $lostSinceMs)';
}


}

/// @nodoc
abstract mixin class $WelcomeRestoreMode_RecoverCopyWith<$Res> implements $WelcomeRestoreModeCopyWith<$Res> {
  factory $WelcomeRestoreMode_RecoverCopyWith(WelcomeRestoreMode_Recover value, $Res Function(WelcomeRestoreMode_Recover) _then) = _$WelcomeRestoreMode_RecoverCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 lostSinceMs
});




}
/// @nodoc
class _$WelcomeRestoreMode_RecoverCopyWithImpl<$Res>
    implements $WelcomeRestoreMode_RecoverCopyWith<$Res> {
  _$WelcomeRestoreMode_RecoverCopyWithImpl(this._self, this._then);

  final WelcomeRestoreMode_Recover _self;
  final $Res Function(WelcomeRestoreMode_Recover) _then;

/// Create a copy of WelcomeRestoreMode
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? lostSinceMs = null,}) {
  return _then(WelcomeRestoreMode_Recover(
lostSinceMs: null == lostSinceMs ? _self.lostSinceMs : lostSinceMs // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

// dart format on
