use std::fs;
use std::io::Write;
use std::path::PathBuf;

use flutter_rust_bridge::frb;
use futures_util::StreamExt;

use super::network::get_runtime;
use crate::frb_generated::StreamSink;
use crate::identity::data_dir;

const APP_VERSION: &str = "0.8.0";

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
    let zip_file = fs::File::open(&zip_path)
        .map_err(|e| format!("Failed to open zip: {e}"))?;
    let mut archive = zip::ZipArchive::new(zip_file)
        .map_err(|e| format!("Failed to read zip archive: {e}"))?;

    // Detect if all entries share a common top-level directory (e.g., "Release/")
    // so we can flatten it.
    let prefix = detect_common_prefix(&mut archive);

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read zip entry {i}: {e}"))?;

        let raw_name = entry.name().to_string();
        let name = if let Some(ref p) = prefix {
            raw_name.strip_prefix(p.as_str()).unwrap_or(&raw_name).to_string()
        } else {
            raw_name
        };

        if name.is_empty() {
            continue;
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

fn detect_common_prefix(archive: &mut zip::ZipArchive<fs::File>) -> Option<String> {
    let mut common: Option<String> = None;
    for i in 0..archive.len() {
        let name = match archive.by_index_raw(i) {
            Ok(entry) => entry.name().to_string(),
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
