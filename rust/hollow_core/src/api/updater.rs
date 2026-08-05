use std::fs;
use std::io::Write;
use std::path::PathBuf;

use flutter_rust_bridge::frb;
use futures_util::StreamExt;

use super::network::get_runtime;
use crate::frb_generated::StreamSink;
use crate::identity::data_dir;

const APP_VERSION: &str = "0.9.4";

pub struct DownloadProgress {
    pub bytes_downloaded: u64,
    pub total_bytes: u64,
}

#[frb(sync)]
pub fn get_current_version() -> String {
    APP_VERSION.to_string()
}

#[frb]
pub fn fetch_version_manifest(manifest_url: String) -> Result<String, String> {
    let rt = get_runtime();
    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| format!("Failed to build HTTP client: {e}"))?;
        let resp = client
            .get(&manifest_url)
            .header("Cache-Control", "no-cache")
            .send()
            .await
            .map_err(|e| format!("Failed to fetch manifest: {e}"))?;
        resp.text()
            .await
            .map_err(|e| format!("Failed to read manifest body: {e}"))
    })
}

#[frb]
pub fn download_update(
    url: String,
    dest_path: String,
    sink: StreamSink<DownloadProgress>,
) -> Result<(), String> {
    let rt = get_runtime();
    rt.spawn(async move {
        if let Err(e) = download_inner(&url, &dest_path, &sink).await {
            let _ = sink.add(DownloadProgress {
                bytes_downloaded: 0,
                total_bytes: 0,
            });
            crate::hollow_log!("[updater] Download failed: {e}");
        }
    });
    Ok(())
}

async fn download_inner(
    url: &str,
    dest_path: &str,
    sink: &StreamSink<DownloadProgress>,
) -> Result<(), String> {
    let resp = reqwest::get(url)
        .await
        .map_err(|e| format!("Request failed: {e}"))?;

    let total_bytes = resp.content_length().unwrap_or(0);

    let dest = PathBuf::from(dest_path);
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create download directory: {e}"))?;
    }

    let mut file = fs::File::create(&dest)
        .map_err(|e| format!("Failed to create file: {e}"))?;

    let mut bytes_downloaded: u64 = 0;
    let mut stream = resp.bytes_stream();

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Stream error: {e}"))?;
        file.write_all(&chunk)
            .map_err(|e| format!("Write error: {e}"))?;
        bytes_downloaded += chunk.len() as u64;

        if sink
            .add(DownloadProgress {
                bytes_downloaded,
                total_bytes,
            })
            .is_err()
        {
            break;
        }
    }

    Ok(())
}

#[frb]
pub fn apply_update(
    zip_path: String,
    app_dir: String,
    version: String,
) -> Result<String, String> {
    let data = data_dir()?;
    let staging_dir = data.join("updates").join(format!("staging-{version}"));

    if staging_dir.exists() {
        fs::remove_dir_all(&staging_dir)
            .map_err(|e| format!("Failed to clean staging dir: {e}"))?;
    }
    fs::create_dir_all(&staging_dir)
        .map_err(|e| format!("Failed to create staging dir: {e}"))?;

    // macOS: extract with `ditto`, which natively preserves the `.app` bundle's
    // executable permissions, symlinks (frameworks!), and code signature. The
    // Rust `zip` crate drops all of those, which would corrupt the bundle.
    #[cfg(target_os = "macos")]
    {
        let staging_str = staging_dir
            .to_str()
            .ok_or("Staging dir path is not valid UTF-8")?;
        let status = std::process::Command::new("/usr/bin/ditto")
            .args(["-x", "-k", &zip_path, staging_str])
            .status()
            .map_err(|e| format!("Failed to run ditto: {e}"))?;
        if !status.success() {
            return Err(format!("ditto extraction failed (exit {status})"));
        }
        return write_macos_update_script(&data, staging_str, &zip_path, &app_dir, &version);
    }

    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        let _ = (&zip_path, &app_dir, &version);
        return Err("Auto-update is not supported on this platform yet".into());
    }

    #[cfg(target_os = "windows")]
    {
    extract_zip_to(&zip_path, &staging_dir)?;

    let staging_str = staging_dir
        .to_str()
        .ok_or("Staging dir path is not valid UTF-8")?;

    let bat_path = data.join("updates").join("update.bat");
    let zip_path_str = zip_path.replace('/', "\\");
    let bat_content = format!(
        "@echo off\r\n\
         title Hollow Update\r\n\
         echo.\r\n\
         echo   ========================================\r\n\
         echo     Hollow Update - v{version}\r\n\
         echo   ========================================\r\n\
         echo.\r\n\
         echo   Waiting for Hollow to close...\r\n\
         :wait\r\n\
         tasklist /FI \"IMAGENAME eq hollow.exe\" 2>NUL | find /I \"hollow.exe\" >NUL\r\n\
         if %ERRORLEVEL% == 0 (\r\n\
             timeout /t 1 /nobreak >NUL\r\n\
             goto wait\r\n\
         )\r\n\
         echo   Copying files...\r\n\
         xcopy /E /Y /Q \"{staging_str}\\*\" \"{app_dir}\\\" >NUL\r\n\
         echo.\r\n\
         echo   Cleaning up...\r\n\
         rd /S /Q \"{staging_str}\" >NUL 2>&1\r\n\
         del /Q \"{zip_path_str}\" >NUL 2>&1\r\n\
         echo.\r\n\
         echo   Successfully updated to v{version}!\r\n\
         echo.\r\n\
         echo   Launching Hollow in:\r\n\
         echo.\r\n\
         echo     5...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     4...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     3...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     2...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     1...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo.\r\n\
         start \"\" \"{app_dir}\\hollow.exe\"\r\n\
         exit\r\n"
    );

    fs::write(&bat_path, bat_content)
        .map_err(|e| format!("Failed to write update script: {e}"))?;

    bat_path
        .to_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "Bat path is not valid UTF-8".to_string())
    }
}

/// Builds the `.app`-swap shell script used on macOS.
///
/// The downloaded zip is expected to contain a single `*.app` bundle (e.g.
/// `Hollow.app`). `app_dir` is the directory that currently holds the running
/// bundle (e.g. `/Applications`). The script waits for the running process to
/// exit, replaces the old bundle with the staged one via `ditto` (which
/// preserves bundle structure and any signature), clears the quarantine
/// attribute, then relaunches with `open`.
#[cfg(target_os = "macos")]
fn write_macos_update_script(
    data: &std::path::Path,
    staging_str: &str,
    zip_path: &str,
    app_dir: &str,
    version: &str,
) -> Result<String, String> {
    // Locate the single .app bundle inside the staging dir.
    let staging = PathBuf::from(staging_str);
    let mut bundle_name: Option<String> = None;
    for entry in fs::read_dir(&staging)
        .map_err(|e| format!("Failed to read staging dir: {e}"))?
    {
        let entry = entry.map_err(|e| format!("Failed to read staging entry: {e}"))?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.ends_with(".app") {
            bundle_name = Some(name);
            break;
        }
    }
    let bundle_name = bundle_name
        .ok_or("Update archive did not contain a .app bundle")?;

    let staged_app = staging.join(&bundle_name);
    let staged_app_str = staged_app
        .to_str()
        .ok_or("Staged app path is not valid UTF-8")?;
    // Install path: keep the bundle's own name, placed back in app_dir.
    let installed_app = format!("{app_dir}/{bundle_name}");

    let sh_path = data.join("updates").join("update.sh");
    let log_path = data.join("updates").join("update.log");
    let log_str = log_path.to_str().ok_or("Log path is not valid UTF-8")?;

    // Note: `pgrep -f` on the installed bundle path waits for *this* app to die.
    let sh_content = format!(
        "#!/bin/sh\n\
         set -e\n\
         LOG=\"{log_str}\"\n\
         echo \"Hollow update -> v{version}\" > \"$LOG\"\n\
         echo \"Waiting for Hollow to close...\" >> \"$LOG\"\n\
         # Wait until no process is running from the installed bundle.\n\
         while pgrep -f \"{installed_app}/Contents/MacOS/\" >/dev/null 2>&1; do\n\
         \tsleep 1\n\
         done\n\
         sleep 1\n\
         echo \"Replacing bundle...\" >> \"$LOG\"\n\
         rm -rf \"{installed_app}\" >> \"$LOG\" 2>&1 || true\n\
         /usr/bin/ditto \"{staged_app_str}\" \"{installed_app}\" >> \"$LOG\" 2>&1\n\
         echo \"Clearing quarantine...\" >> \"$LOG\"\n\
         /usr/bin/xattr -dr com.apple.quarantine \"{installed_app}\" >> \"$LOG\" 2>&1 || true\n\
         echo \"Cleaning up...\" >> \"$LOG\"\n\
         rm -rf \"{staging_str}\" >> \"$LOG\" 2>&1 || true\n\
         rm -f \"{zip_path}\" >> \"$LOG\" 2>&1 || true\n\
         echo \"Relaunching...\" >> \"$LOG\"\n\
         /usr/bin/open -n \"{installed_app}\" >> \"$LOG\" 2>&1\n\
         exit 0\n"
    );

    fs::write(&sh_path, &sh_content)
        .map_err(|e| format!("Failed to write update script: {e}"))?;

    // Make the script executable.
    use std::os::unix::fs::PermissionsExt;
    let mut perms = fs::metadata(&sh_path)
        .map_err(|e| format!("Failed to stat update script: {e}"))?
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&sh_path, perms)
        .map_err(|e| format!("Failed to chmod update script: {e}"))?;

    sh_path
        .to_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "Script path is not valid UTF-8".to_string())
}

/// Extracts an update zip into `staging_dir`, flattening a single common
/// top-level directory (e.g. "Release/") when present.
///
/// Entry names are normalized `\` → `/` first: PowerShell's Compress-Archive
/// (which builds the release zips) writes backslash-separated names and marks
/// directory entries with a TRAILING backslash — treating those as files made
/// `File::create` fail with os error 267/123 on every empty dir (issue #52).
#[allow(dead_code)] // only reachable on Windows outside of tests
fn extract_zip_to(zip_path: &str, staging_dir: &std::path::Path) -> Result<(), String> {
    let zip_file = fs::File::open(zip_path)
        .map_err(|e| format!("Failed to open zip: {e}"))?;
    let mut archive = zip::ZipArchive::new(zip_file)
        .map_err(|e| format!("Failed to read zip archive: {e}"))?;

    let prefix = detect_common_prefix(&mut archive);

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read zip entry {i}: {e}"))?;

        let raw_name = entry.name().replace('\\', "/");
        let name = if let Some(ref p) = prefix {
            raw_name.strip_prefix(p.as_str()).unwrap_or(&raw_name).to_string()
        } else {
            raw_name
        };

        if name.is_empty() {
            continue;
        }
        if name.split('/').any(|part| part == "..") {
            return Err(format!("Unsafe zip entry path: {name}"));
        }

        if name.ends_with('/') {
            let dir_path = staging_dir.join(&name);
            fs::create_dir_all(&dir_path)
                .map_err(|e| format!("Failed to create dir {name}: {e}"))?;
        } else {
            let file_path = staging_dir.join(&name);
            if let Some(parent) = file_path.parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| format!("Failed to create parent for {name}: {e}"))?;
            }
            let mut outfile = fs::File::create(&file_path)
                .map_err(|e| format!("Failed to create file {name}: {e}"))?;
            std::io::copy(&mut entry, &mut outfile)
                .map_err(|e| format!("Failed to extract {name}: {e}"))?;
        }
    }
    Ok(())
}

fn detect_common_prefix(archive: &mut zip::ZipArchive<fs::File>) -> Option<String> {
    let mut common: Option<String> = None;
    for i in 0..archive.len() {
        let name = match archive.by_index_raw(i) {
            Ok(entry) => entry.name().replace('\\', "/"),
            Err(_) => return None,
        };
        let first_part = match name.find('/') {
            Some(idx) => &name[..=idx],
            None => return None,
        };
        match &common {
            None => common = Some(first_part.to_string()),
            Some(c) if c != first_part => return None,
            _ => {}
        }
    }
    common
}

#[cfg(test)]
mod extract_zip_tests {
    use std::io::Write;

    /// Builds a zip the way Compress-Archive does — backslash separators,
    /// zero-byte directory entries with a trailing backslash — and asserts
    /// extraction survives it (issue #52 regression).
    #[test]
    fn extracts_compress_archive_style_backslash_entries() {
        let tmp = std::env::temp_dir().join(format!(
            "hollow_updater_zip_test_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("create tmp dir");

        let zip_path = tmp.join("update.zip");
        {
            let file = std::fs::File::create(&zip_path).expect("create zip");
            let mut writer = zip::ZipWriter::new(file);
            let opts = zip::write::SimpleFileOptions::default();
            // Empty-directory entry exactly as Compress-Archive emits it.
            writer
                .start_file("data\\flutter_assets\\packages\\", opts)
                .expect("dir entry");
            writer
                .start_file("hollow.exe", opts)
                .expect("exe entry");
            writer.write_all(b"exe-bytes").expect("write exe");
            writer
                .start_file("data\\flutter_assets\\kernel_blob.bin", opts)
                .expect("nested entry");
            writer.write_all(b"blob").expect("write blob");
            writer.finish().expect("finish zip");
        }

        let staging = tmp.join("staging");
        std::fs::create_dir_all(&staging).expect("create staging");
        super::extract_zip_to(zip_path.to_str().unwrap(), &staging)
            .expect("extraction must tolerate backslash entries");

        assert!(staging.join("hollow.exe").is_file());
        assert!(staging
            .join("data")
            .join("flutter_assets")
            .join("kernel_blob.bin")
            .is_file());
        assert!(staging
            .join("data")
            .join("flutter_assets")
            .join("packages")
            .is_dir());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// Minimal single-entry STORED zip with an arbitrary (unsanitized) entry
    /// name. ZipWriter refuses to write traversal names, so the hostile
    /// fixture must be built by hand. CRC stays 0 — rejection happens on the
    /// NAME before any data is read.
    fn raw_zip_single_entry(name: &[u8], data: &[u8]) -> Vec<u8> {
        let name_len = (name.len() as u16).to_le_bytes();
        let size = (data.len() as u32).to_le_bytes();
        let mut out = Vec::new();
        // Local file header.
        out.extend_from_slice(b"PK\x03\x04");
        out.extend_from_slice(&[20, 0, 0, 0, 0, 0, 0, 0, 0, 0]); // ver/flags/method/time/date
        out.extend_from_slice(&[0, 0, 0, 0]); // crc32
        out.extend_from_slice(&size); // compressed
        out.extend_from_slice(&size); // uncompressed
        out.extend_from_slice(&name_len);
        out.extend_from_slice(&[0, 0]); // extra len
        out.extend_from_slice(name);
        out.extend_from_slice(data);
        // Central directory.
        let cd_offset = (out.len() as u32).to_le_bytes();
        let cd_start = out.len();
        out.extend_from_slice(b"PK\x01\x02");
        out.extend_from_slice(&[20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0]); // made-by/needed/flags/method/time/date
        out.extend_from_slice(&[0, 0, 0, 0]); // crc32
        out.extend_from_slice(&size);
        out.extend_from_slice(&size);
        out.extend_from_slice(&name_len);
        out.extend_from_slice(&[0, 0]); // extra len
        out.extend_from_slice(&[0, 0]); // comment len
        out.extend_from_slice(&[0, 0]); // disk start
        out.extend_from_slice(&[0, 0]); // internal attrs
        out.extend_from_slice(&[0, 0, 0, 0]); // external attrs
        out.extend_from_slice(&[0, 0, 0, 0]); // local header offset
        out.extend_from_slice(name);
        let cd_size = ((out.len() - cd_start) as u32).to_le_bytes();
        // End of central directory.
        out.extend_from_slice(b"PK\x05\x06");
        out.extend_from_slice(&[0, 0, 0, 0, 1, 0, 1, 0]); // disks, entry counts
        out.extend_from_slice(&cd_size);
        out.extend_from_slice(&cd_offset);
        out.extend_from_slice(&[0, 0]); // comment len
        out
    }

    /// A hostile entry trying to escape the staging dir must abort extraction.
    #[test]
    fn rejects_path_traversal_entries() {
        let tmp = std::env::temp_dir().join(format!(
            "hollow_updater_slip_test_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("create tmp dir");

        let zip_path = tmp.join("evil.zip");
        // Empty data so the stored CRC of 0 is valid if extraction proceeds.
        std::fs::write(&zip_path, raw_zip_single_entry(b"..\\outside.txt", b""))
            .expect("write raw zip");

        let staging = tmp.join("staging");
        std::fs::create_dir_all(&staging).expect("create staging");
        // The zip crate sanitizes traversal names on read ("..\x" → "x"), and
        // our own guard rejects any ".." that slips through — either way the
        // entry must NOT materialize outside the staging dir.
        let _ = super::extract_zip_to(zip_path.to_str().unwrap(), &staging);
        assert!(
            !tmp.join("outside.txt").exists(),
            "traversal entry escaped the staging dir"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }
}

// ── Self-restart waiter (issue #47 profile switch, relay apply, device link,
// revocation self-nuke) ─────────────────────────────────────────────────────
//
// Dart cannot restart the app by spawning a fresh copy before exiting: on
// Windows the runner's SendAppLinkToInstance() runs pre-Flutter in the child,
// finds the still-alive old window (same exe path), forwards, and the child
// exits. So a detached waiter must idle until THIS process is gone, then
// start the exe. The waiter can't be spawned from Dart either — its detached
// mode kills powershell instantly (no console, no CREATE_NO_WINDOW), and a
// detached cmd batch wedges its tasklist|find pipeline in a half-alive
// console. Rust CAN pass CREATE_NO_WINDOW, so the spawn lives here.

/// Spawn a detached, windowless waiter that idles until this process exits,
/// then relaunches the app. Call right before a self-restart `exit(0)`.
#[frb]
pub fn spawn_relaunch_waiter() -> Result<(), String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("current_exe failed: {e}"))?;
    let exe = exe
        .to_str()
        .ok_or("Executable path is not valid UTF-8")?
        .to_string();
    spawn_waiter(std::process::id(), &relaunch_snippet(&exe))
}

/// The platform snippet the waiter runs once the watched pid is gone.
///
/// The original argv is forwarded: a relaunch that drops `--portable` (or any
/// other data-root flag) comes back up on a DIFFERENT profile than the one
/// the user was running — alternating identities between the relaunch and
/// the next manual launch (issue #47 fallout).
fn relaunch_snippet(exe: &str) -> String {
    let args: Vec<String> = std::env::args().skip(1).collect();
    #[cfg(windows)]
    {
        // PowerShell single-quoted literals; ' escapes by doubling.
        let exe_q = exe.replace('\'', "''");
        if args.is_empty() {
            format!("Start-Process -FilePath '{exe_q}'")
        } else {
            let list = args
                .iter()
                .map(|a| format!("'{}'", a.replace('\'', "''")))
                .collect::<Vec<_>>()
                .join(",");
            format!("Start-Process -FilePath '{exe_q}' -ArgumentList {list}")
        }
    }
    #[cfg(not(windows))]
    {
        let sh_quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
        let arg_str = args
            .iter()
            .map(|a| sh_quote(a))
            .collect::<Vec<_>>()
            .join(" ");
        #[cfg(target_os = "macos")]
        {
            // Relaunch the bundle via LaunchServices when running from a .app.
            match exe.find(".app/") {
                Some(idx) => {
                    let bundle = &exe[..idx + 4];
                    if args.is_empty() {
                        format!("/usr/bin/open \"{bundle}\"")
                    } else {
                        format!("/usr/bin/open \"{bundle}\" --args {arg_str}")
                    }
                }
                None if args.is_empty() => format!("exec \"{exe}\""),
                None => format!("exec \"{exe}\" {arg_str}"),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            if args.is_empty() {
                format!("exec \"{exe}\"")
            } else {
                format!("exec \"{exe}\" {arg_str}")
            }
        }
    }
}

#[cfg(windows)]
fn spawn_waiter(pid: u32, launch: &str) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    use std::process::Stdio;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    std::process::Command::new("powershell")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &format!(
                "while (Get-Process -Id {pid} -ErrorAction SilentlyContinue) \
                 {{ Start-Sleep -Milliseconds 250 }}; {launch}"
            ),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ()) // child handle drop does NOT kill the process
        .map_err(|e| format!("Failed to spawn relaunch waiter: {e}"))
}

#[cfg(not(windows))]
fn spawn_waiter(pid: u32, launch: &str) -> Result<(), String> {
    use std::process::Stdio;
    std::process::Command::new("/bin/sh")
        .args([
            "-c",
            &format!("while kill -0 {pid} 2>/dev/null; do sleep 0.3; done; {launch}"),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Failed to spawn relaunch waiter: {e}"))
}

#[cfg(all(test, windows))]
mod relaunch_waiter_tests {
    /// End-to-end mechanics: waiter watches a short-lived pid, outlives it,
    /// and runs the launch snippet. Guards the CREATE_NO_WINDOW PowerShell
    /// spawn — the Dart-side detached spawn silently killed powershell, so
    /// this MUST stay an empirical test, not a code-review assumption.
    #[test]
    fn waiter_fires_after_watched_pid_exits() {
        use std::os::windows::process::CommandExt;
        let marker = std::env::temp_dir()
            .join(format!("hollow_waiter_test_{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&marker);

        // A child that exits immediately = the "old Hollow" to outwait.
        let mut child = std::process::Command::new("cmd")
            .args(["/c", "exit"])
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .spawn()
            .expect("spawn short-lived child");
        let watched = child.id();

        super::spawn_waiter(
            watched,
            &format!(
                "Set-Content -Path '{}' -Value ok",
                marker.display()
            ),
        )
        .expect("spawn waiter");

        let _ = child.wait();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::time::Instant::now() < deadline {
            if marker.exists() {
                let _ = std::fs::remove_file(&marker);
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
        panic!("relaunch waiter never ran its launch snippet");
    }
}
