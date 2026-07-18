#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello from Rust, {name}! Hollow backend is alive.")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
    // FRB's setup above installs platform console loggers (android_logger /
    // oslog) at TRACE — in RELEASE builds too. At Trace, dependency crates
    // flood the device log: tungstenite logs EVERY relay frame payload
    // (room ids on a production phone = metadata leak, against
    // feedback_relay_no_metadata_logging) and the jni crate logs 6 lines
    // per JNI call on the realtime audio path (RNNoise bridge). Cap the
    // global level: warnings/errors still reach logcat, the spam does not.
    // Hollow's own diagnostics are unaffected — hollow_log! writes to
    // stderr + hollow_debug.log, not through the `log` crate.
    log::set_max_level(log::LevelFilter::Warn);
}
