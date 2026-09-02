//! The app's art encoders and the `.hollowpack` format, as a crate of their
//! own.
//!
//! Nothing here is new code. Every module is a `#[path]` include of the file
//! hollow_core compiles, so the `hollowpack` CLI (and, through it, the shop
//! server) runs the exact encoders the app runs: `image_convert` for the
//! ceilings and the quality ladders, `webp_anim` for the libwebp animated
//! encoder, `hollowpack` for the container, the hashes and the verifier.
//! Identity is the SHA-256 of the processed bytes, so a second copy of the
//! encoder would be a second identity; this crate exists so there is not one.
//!
//! The module layout mirrors hollow_core's (`crate::node::image_convert`,
//! `crate::node::webp_anim`, `crate::hollowpack`) because the included files
//! name each other by those paths.
//!
//! Tests: the `#[cfg(test)]` modules inside the included files reach into
//! hollow_core-only modules (`crate::node::assets`, `crate::api::storage`),
//! so they compile and run in hollow_core (`cargo nextest run --lib hollowpack`
//! there) and NOT here. `cargo build` never compiles test code, which is all
//! this crate needs; do not run `cargo test` in this crate and expect it to
//! link.

pub mod node;

#[path = "../../hollow_core/src/hollowpack.rs"]
pub mod hollowpack;
