# Holds a file the way a scanner or backup tool does (open for read, sharing
# reads only) from the moment a process exits, for -Seconds, then lets go.
# fleet_link_matrix.ps1 -Condition held_db aims it at a receiver's messages.db
# across the link import (the 0.12.0 field case).
param([int]$OldPid, [string]$Path, [int]$Seconds = 15, [string]$Out)
while (Get-Process -Id $OldPid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 50 }
try {
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
    "held $(Get-Date -Format o)" | Out-File -FilePath $Out -Append -Encoding utf8
    Start-Sleep -Seconds $Seconds
    $fs.Close()
    "released $(Get-Date -Format o)" | Out-File -FilePath $Out -Append -Encoding utf8
} catch {
    "hold failed: $_" | Out-File -FilePath $Out -Append -Encoding utf8
}
