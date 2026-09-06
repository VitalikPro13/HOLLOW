//! Anti-censorship proxy tunnel: launches the bundled `shoes` REALITY client as
//! a subprocess exposing a local SOCKS5 listener, so the relay WSS connection
//! rides a VLESS+REALITY tunnel and looks like ordinary HTTPS to a censor.
//!
//! A subprocess rather than a linked library: `shoes` pulls its own
//! aws-lc-rs/rustls/tokio runtime, which would collide with hollow_core's
//! `tokio-tungstenite`. A local SOCKS5 port is a protocol-agnostic boundary.
//!
//! `start()` on node startup, `stop()` on shutdown; the child is force-killed.

use std::io::Write;
use std::net::{Ipv4Addr, SocketAddr, TcpListener as StdTcpListener, TcpStream as StdTcpStream};
use std::process::{Child, Command};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::api::network::ProxyConfig;
use crate::hollow_log;

/// The running `shoes` child, if any. Killed on node stop.
static SHOES_CHILD: OnceLock<Mutex<Option<Child>>> = OnceLock::new();

fn child_slot() -> &'static Mutex<Option<Child>> {
    SHOES_CHILD.get_or_init(|| Mutex::new(None))
}

/// Locate the bundled `shoes` executable. Ships next to the app binary (like
/// `screen_audio_capturer.exe`); dev/debug fallback checks the scratchpad build.
fn shoes_binary_path() -> Option<std::path::PathBuf> {
    let exe_name = if cfg!(windows) { "shoes.exe" } else { "shoes" };

    // 1) Next to the running executable (production bundling).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let p = dir.join(exe_name);
            if p.exists() {
                return Some(p);
            }
        }
    }

    // 2) HOLLOW_SHOES_BIN override (used for the manual Spike test / dev).
    if let Ok(p) = std::env::var("HOLLOW_SHOES_BIN") {
        let pb = std::path::PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }

    None
}

/// Ask the OS for a free localhost TCP port by binding :0 and reading it back.
fn pick_free_port() -> Result<u16, String> {
    let l = StdTcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .map_err(|e| format!("Failed to reserve a local proxy port: {e}"))?;
    let port = l
        .local_addr()
        .map_err(|e| format!("Failed to read local proxy port: {e}"))?
        .port();
    // Listener drops here, freeing the port for shoes to bind. A brief TOCTOU
    // window exists but is negligible on loopback for a just-freed ephemeral port.
    Ok(port)
}

/// Render the `shoes` client YAML: a SOCKS5 listener on 127.0.0.1:`socks_port`
/// whose traffic is chained through REALITY (XTLS-Vision) → VLESS to the server.
fn render_yaml(cfg: &ProxyConfig, socks_port: u16) -> String {
    // short_id may legitimately be empty; emit it quoted either way.
    format!(
        "- address: 127.0.0.1:{socks_port}\n\
         \x20 protocol:\n\
         \x20   type: socks\n\
         \x20 rules:\n\
         \x20   - masks: \"0.0.0.0/0\"\n\
         \x20     action: allow\n\
         \x20     client_chain:\n\
         \x20       address: \"{server}\"\n\
         \x20       protocol:\n\
         \x20         type: reality\n\
         \x20         public_key: \"{public_key}\"\n\
         \x20         short_id: \"{short_id}\"\n\
         \x20         sni_hostname: \"{sni}\"\n\
         \x20         vision: true\n\
         \x20         protocol:\n\
         \x20           type: vless\n\
         \x20           user_id: \"{uuid}\"\n",
        socks_port = socks_port,
        server = cfg.server,
        public_key = cfg.public_key,
        short_id = cfg.short_id,
        sni = cfg.sni,
        uuid = cfg.uuid,
    )
}

#[cfg(windows)]
fn spawn_hidden(cmd: &mut Command) -> std::io::Result<Child> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW).spawn()
}

#[cfg(not(windows))]
fn spawn_hidden(cmd: &mut Command) -> std::io::Result<Child> {
    cmd.spawn()
}

/// Start the tunnel for `cfg`: write the YAML, spawn `shoes`, wait for the SOCKS
/// port to accept, and return `127.0.0.1:port` for ws_client to dial. Err (the
/// proxy stays off) when the binary is missing or the tunnel does not come up.
pub(crate) fn start(cfg: &ProxyConfig) -> Result<String, String> {
    // Kill any stale child first (defensive — start should follow stop).
    stop();

    let bin = shoes_binary_path().ok_or_else(|| {
        "shoes tunnel binary not found (expected next to the app or via \
         HOLLOW_SHOES_BIN)"
            .to_string()
    })?;

    let socks_port = pick_free_port()?;
    let yaml = render_yaml(cfg, socks_port);

    // Write the config next to the app data (not the scratchpad) so it persists
    // with the node and is inspectable if a user reports a tunnel problem.
    let data_dir = crate::identity::data_dir()
        .map_err(|e| format!("No data dir for tunnel config: {e}"))?;
    let yaml_path = std::path::Path::new(&data_dir).join("shoes-client.yaml");
    {
        let mut f = std::fs::File::create(&yaml_path)
            .map_err(|e| format!("Failed to write tunnel config: {e}"))?;
        f.write_all(yaml.as_bytes())
            .map_err(|e| format!("Failed to write tunnel config: {e}"))?;
    }

    hollow_log!(
        "[HOLLOW-PROXY] Starting REALITY tunnel: {} → SOCKS5 127.0.0.1:{socks_port} (server {})",
        bin.display(),
        cfg.server
    );

    let mut cmd = Command::new(&bin);
    cmd.arg("--threads")
        .arg("1")
        .arg("--no-reload")
        .arg(&yaml_path)
        // shoes logs to stderr; swallow it (a broken tunnel surfaces as a
        // connect failure, and we don't want to leak config lines to a console).
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .stdin(std::process::Stdio::null());

    let child = spawn_hidden(&mut cmd)
        .map_err(|e| format!("Failed to launch shoes tunnel: {e}"))?;

    // Record the PID so a NEXT app launch can kill this shoes if we're orphaned
    // (hard exit(0) on restart, crash, or Task-Manager-kill all skip stop()).
    write_pid_file(child.id());

    if let Ok(mut slot) = child_slot().lock() {
        *slot = Some(child);
    }

    // Health-gate: wait until the SOCKS listener ACCEPTS a TCP connection. Probe
    // by CONNECTING, never by binding: a bind-probe races shoes for the port and
    // can hold it away from it.
    let socks_addr = SocketAddr::from((Ipv4Addr::LOCALHOST, socks_port));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match StdTcpStream::connect_timeout(&socks_addr, Duration::from_millis(300)) {
            Ok(_) => break, // shoes is accepting connections
            Err(_) => {
                // Not up yet — but first check the child didn't crash outright
                // (bad config → shoes exits immediately).
                if let Ok(mut slot) = child_slot().lock() {
                    if let Some(ch) = slot.as_mut() {
                        if let Ok(Some(status)) = ch.try_wait() {
                            *slot = None;
                            return Err(format!(
                                "REALITY tunnel exited immediately ({status}) — likely bad proxy config"
                            ));
                        }
                    }
                }
                if Instant::now() >= deadline {
                    stop();
                    return Err(
                        "REALITY tunnel did not come up within 10s (check server config/keys)"
                            .to_string(),
                    );
                }
                std::thread::sleep(Duration::from_millis(150));
            }
        }
    }

    let addr = format!("127.0.0.1:{socks_port}");
    hollow_log!("[HOLLOW-PROXY] REALITY tunnel up on {addr}");
    Ok(addr)
}

/// Kill the running tunnel, if any. Idempotent.
pub(crate) fn stop() {
    if let Ok(mut slot) = child_slot().lock() {
        if let Some(mut child) = slot.take() {
            let _ = child.kill();
            let _ = child.wait();
            hollow_log!("[HOLLOW-PROXY] REALITY tunnel stopped");
        }
    }
    clear_pid_file();
}

/// Path of the file holding the running shoes PID (data dir).
fn pid_file_path() -> Option<std::path::PathBuf> {
    let data_dir = crate::identity::data_dir().ok()?;
    Some(std::path::Path::new(&data_dir).join("shoes.pid"))
}

fn write_pid_file(pid: u32) {
    if let Some(p) = pid_file_path() {
        let _ = std::fs::write(p, pid.to_string());
    }
}

fn clear_pid_file() {
    if let Some(p) = pid_file_path() {
        let _ = std::fs::remove_file(p);
    }
}

/// Kill a shoes process orphaned by a previous app run (hard exit, crash, kill).
/// Called at node startup BEFORE deciding whether to launch a fresh tunnel, so a
/// stale shoes never lingers, whether the proxy is now on or off.
pub(crate) fn sweep_orphan() {
    let Some(p) = pid_file_path() else { return };
    let Ok(raw) = std::fs::read_to_string(&p) else { return };
    let Ok(pid) = raw.trim().parse::<u32>() else {
        let _ = std::fs::remove_file(&p);
        return;
    };
    kill_pid(pid);
    let _ = std::fs::remove_file(&p);
    hollow_log!("[HOLLOW-PROXY] Swept orphaned shoes tunnel (pid {pid}) from a prior run");
}

#[cfg(windows)]
fn kill_pid(pid: u32) {
    // taskkill is the simplest reliable cross-version way; /F force, /T tree.
    // Hidden window via CREATE_NO_WINDOW. Best-effort — a dead pid just no-ops.
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let _ = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/F", "/T"])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

#[cfg(not(windows))]
fn kill_pid(pid: u32) {
    // SIGKILL via the kill(1) command — best-effort, dead pid no-ops.
    let _ = Command::new("kill")
        .args(["-9", &pid.to_string()])
        .status();
}
