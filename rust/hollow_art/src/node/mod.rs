//! hollow_core's `node::image_convert` and `node::webp_anim`, included by
//! path. Both are pure functions of bytes (the `image` crate plus libwebp),
//! which is what makes them buildable without the rest of the node.

#[path = "../../../hollow_core/src/node/image_convert.rs"]
pub mod image_convert;

#[path = "../../../hollow_core/src/node/webp_anim.rs"]
pub mod webp_anim;
