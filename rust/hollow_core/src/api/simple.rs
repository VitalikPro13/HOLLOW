#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello from Rust, {name}! Hollow backend is alive.")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    // FRB's setup installs platform console loggers at TRACE even in release, so
    // tungstenite would log every relay frame (room ids on a phone, against
    // feedback_relay_no_metadata_logging) and jni 6 lines per call on the audio path.
    log::set_max_level(log::LevelFilter::Warn);
}
