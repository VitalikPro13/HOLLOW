//! hollow_core's `node::image_convert` and `node::webp_anim`, included by
//! path. Both are pure functions of bytes (the `image` crate plus libwebp),
//! which is what makes them buildable without the rest of the node.

#[path = "../../../hollow_core/src/node/image_convert.rs"]
pub mod image_convert;

#[path = "../../../hollow_core/src/node/webp_anim.rs"]
pub mod webp_anim;

/// The pure-Rust image check `image_convert` and `hollowpack` run before decoding.
#[path = "../../../hollow_core/src/node/image_check.rs"]
pub mod image_check;

/// The RFC 9474 variant of a support credential and its key helpers, so
/// `hollowpack keygen` and `hollowpack blind-sign` run the SAME code the app
/// verifies with (design 5.2). Needs only the blind-rsa crate.
#[path = "../../../hollow_core/src/node/support_rsa.rs"]
pub mod support_rsa;
