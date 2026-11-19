//! The server channels on screen on this device, pushed by Dart via FFI
//! `set_channels_on_screen` (empty while the window is hidden, the app is
//! backgrounded or locked). Every member device hears every channel's posts live,
//! so a pushed file's BYTES land only for a channel the person is looking at
//! (`file_handler::channel_push_allows`); the card always lands and the viewport
//! sweep pulls on view. Process-global like the auto-download conf: it holds before
//! the node starts and across restarts.

enum OnScreen {
    Channels(std::collections::HashSet<(String, String)>),
    // Tests that predate the gate push channel files at receivers that never
    // "opened" anything; the gate's own tests name their channels explicitly.
    #[cfg(test)]
    Any,
}

fn on_screen() -> &'static std::sync::Mutex<OnScreen> {
    static ON_SCREEN: std::sync::OnceLock<std::sync::Mutex<OnScreen>> = std::sync::OnceLock::new();
    ON_SCREEN.get_or_init(|| {
        #[cfg(test)]
        let initial = OnScreen::Any;
        #[cfg(not(test))]
        let initial = OnScreen::Channels(Default::default());
        std::sync::Mutex::new(initial)
    })
}

/// Replace the set of server channels on screen (FFI `set_channels_on_screen`).
pub(crate) fn set_channels_on_screen(channels: impl IntoIterator<Item = (String, String)>) {
    if let Ok(mut s) = on_screen().lock() {
        *s = OnScreen::Channels(channels.into_iter().collect());
    }
}

/// Puts every channel back on screen when dropped, so a test that set the
/// channels leaves the process as the tests before the gate expect it.
#[cfg(test)]
pub(crate) struct OnScreenReset;

#[cfg(test)]
impl Drop for OnScreenReset {
    fn drop(&mut self) {
        if let Ok(mut s) = on_screen().lock() {
            *s = OnScreen::Any;
        }
    }
}

/// `true` = this server channel is on screen on this device now. A header that
/// names no channel never is.
pub(crate) fn channel_on_screen(server_id: &str, channel_id: Option<&str>) -> bool {
    let Some(channel_id) = channel_id else { return false };
    let Ok(s) = on_screen().lock() else { return false };
    match &*s {
        OnScreen::Channels(set) => set.contains(&(server_id.to_string(), channel_id.to_string())),
        #[cfg(test)]
        OnScreen::Any => true,
    }
}
