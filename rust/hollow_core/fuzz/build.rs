// image_check.rs is compiled here on its own: its unit tests (which use the app crate)
// stay out of this crate's test binaries.
fn main() {
    println!("cargo::rustc-check-cfg=cfg(image_check_standalone)");
    println!("cargo::rustc-cfg=image_check_standalone");
}
