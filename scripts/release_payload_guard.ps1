# What a Windows release must never carry: a profile's data or a portable marker.
# 0.12.1 to 0.14.1 shipped hollow_data\messages.db from the build machine's Release
# folder, and every copy that installed it went portable on that folder (#155).
# Dot-sourced by build_release.ps1; scripts/release_payload_guard_selftest.ps1 tests it.
# Windows PowerShell 5.1: no pwsh-only syntax.

# Relative paths in $Dir that belong to a profile, never to the app.
function Get-ReleasePayloadIntruders([string]$Dir) {
    $root = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\', '/')
    $found = @()
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        $rel = $item.FullName.Substring($root.Length + 1)
        $name = $item.Name.ToLowerInvariant()
        $first = ($rel -split '[\\/]')[0].ToLowerInvariant()
        $bad = ($first -eq 'hollow_data') -or
            ($name -eq 'portable' -or $name -eq 'portable.txt' -or $name -eq 'portable.txt.txt') -or
            ($name -like '*.db' -or $name -like '*.db-wal' -or $name -like '*.db-shm') -or
            ($name -eq 'hollow.lock') -or
            ($name -like 'identity.*')
        # Inside hollow_data only the folder itself is named.
        if ($bad -and -not ($first -eq 'hollow_data' -and $rel.ToLowerInvariant() -ne 'hollow_data')) { $found += $rel }
    }
    return , $found
}

# Throws, naming every intruder, when the Release folder holds any.
function Assert-ReleasePayloadClean([string]$Dir) {
    $found = Get-ReleasePayloadIntruders $Dir
    if ($found.Count -gt 0) {
        throw "The Release folder holds profile data or a portable marker, which must never ship: $($found -join ', '). Delete them (or rebuild into a clean folder) and run again."
    }
}
