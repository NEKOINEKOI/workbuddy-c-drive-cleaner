# WorkBuddy C drive read-only scanner for Windows PowerShell 5.1+
# This script does not delete, move or modify any files.
param(
    [int]$Top = 15,
    [int]$MinAgeDays = 7,
    [string]$ReportPath = ""
)
$ErrorActionPreference = 'Continue'
if (-not $env:USERPROFILE) { throw 'USERPROFILE is not available. Windows is required.' }

function Get-SizeBytes([string]$Folder) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return [int64]0 }
    $root = Get-Item -LiteralPath $Folder -Force -ErrorAction SilentlyContinue
    if ($null -eq $root -or (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return [int64]0 }
    [int64]$sum = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Folder)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) }
            else { $sum += [int64]$child.Length }
        }
    }
    return $sum
}
function Format-Size([int64]$Value) {
    if ($Value -ge 1GB) { return ('{0:N2} GiB' -f ($Value / 1GB)) }
    if ($Value -ge 1MB) { return ('{0:N1} MiB' -f ($Value / 1MB)) }
    if ($Value -ge 1KB) { return ('{0:N1} KiB' -f ($Value / 1KB)) }
    return ("$Value B")
}
function Get-FileSet([string]$Folder, [string]$Pattern, [bool]$Recurse) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    $root = Get-Item -LiteralPath $Folder -Force -ErrorAction SilentlyContinue
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return @() }
    $params = @{ LiteralPath = $Folder; Force = $true; File = $true; ErrorAction = 'SilentlyContinue' }
    if ($Recurse) { $params['Recurse'] = $true }
    $files = @(Get-ChildItem @params | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $_.Name -match $Pattern
    })
    return $files
}

$lines = New-Object 'System.Collections.Generic.List[string]'
function Line([string]$Message) { [void]$script:lines.Add($Message) }

Line '# WorkBuddy C drive storage report (read-only)'
Line ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    if ($null -ne $disk) { Line ('C: Free = ' + (Format-Size ([int64]$disk.FreeSpace)) + ', Total = ' + (Format-Size ([int64]$disk.Size))) }
} catch { Line 'C: drive space info unavailable.' }
Line ''

$main = Join-Path $env:USERPROFILE '.workbuddy'
$locations = @(
    @{ Name='WorkBuddy hidden data (do not delete)'; Path=$main },
    @{ Name='User WorkBuddy projects (do not delete)'; Path=(Join-Path $env:USERPROFILE 'WorkBuddy') },
    @{ Name='Local app data (do not delete whole directory)'; Path=(Join-Path $env:LOCALAPPDATA 'WorkBuddy') },
    @{ Name='Roaming app data (do not delete whole directory)'; Path=(Join-Path $env:APPDATA 'WorkBuddy') },
    @{ Name='Program installation (never delete)'; Path=(Join-Path $env:LOCALAPPDATA 'Programs\WorkBuddy') }
)
Line '## Existing folders and occupied size'
foreach ($entry in $locations) {
    if (Test-Path -LiteralPath $entry.Path -PathType Container) {
        Line ('- ' + $entry.Name + ': ' + (Format-Size (Get-SizeBytes $entry.Path)) + ' | ' + $entry.Path)
    }
}
Line ''
if (Test-Path -LiteralPath $main -PathType Container) {
    Line '## Largest top-level folders in .workbuddy'
    $children = @(Get-ChildItem -LiteralPath $main -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } |
        ForEach-Object { [pscustomobject]@{ Name=$_.Name; Bytes=(Get-SizeBytes $_.FullName) } } |
        Sort-Object Bytes -Descending)
    foreach ($entry in ($children | Select-Object -First $Top)) {
        Line ('- ' + $entry.Name + ': ' + (Format-Size $entry.Bytes))
    }
    Line ''
    $sessions = Join-Path $main 'workspace\sessions'
    if (Test-Path -LiteralPath $sessions -PathType Container) {
        Line '## Session modify_backup snapshots (REVIEW ONLY - DO NOT DELETE)'
        $backups = @()
        foreach ($session in @(Get-ChildItem -LiteralPath $sessions -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 })) {
            $backup = Join-Path $session.FullName 'modify_backup'
            if (Test-Path -LiteralPath $backup -PathType Container) {
                $backups += [pscustomobject]@{ Path=$backup; Bytes=(Get-SizeBytes $backup); Modified=(Get-Item -LiteralPath $backup -Force).LastWriteTime }
            }
        }
        [int64]$total = 0
        foreach ($b in $backups) { $total += $b.Bytes }
        Line ('Total snapshots: ' + $backups.Count + ', estimated size: ' + (Format-Size $total))
        foreach ($b in ($backups | Sort-Object Bytes -Descending | Select-Object -First $Top)) {
            Line ('- ' + (Format-Size $b.Bytes) + ' | ' + $b.Modified.ToString('yyyy-MM-dd') + ' | ' + $b.Path)
        }
        Line ''
    }
}

# Candidate inventory: read-only, split by age threshold
$cutoff = (Get-Date).AddDays(-$MinAgeDays)
Line ('## Candidate inventory (age threshold = ' + $MinAgeDays + ' days, cutoff ' + $cutoff.ToString('yyyy-MM-dd') + ')')
$candidateSets = @(
    @{ Group='A-old-logs-user';    Path=(Join-Path $main 'logs');                    Pattern='(?i)\.log(\.\d+)?$'; Recurse=$true },
    @{ Group='A-old-logs-local';   Path=(Join-Path $env:LOCALAPPDATA 'WorkBuddy\logs'); Pattern='(?i)\.log(\.\d+)?$'; Recurse=$false },
    @{ Group='T1-clipboard-images'; Path=(Join-Path $main 'clipboard-images');        Pattern='.'; Recurse=$false },
    @{ Group='T2-product-spill';   Path=(Join-Path $main 'cache\conversation-product-spill'); Pattern='.'; Recurse=$false },
    @{ Group='T3-traces';          Path=(Join-Path $main 'traces');                  Pattern='.'; Recurse=$true },
    @{ Group='T4-shell-snapshots'; Path=(Join-Path $main 'shell-snapshots');         Pattern='.'; Recurse=$false },
    @{ Group='T5-zsxq-profile';    Path=(Join-Path $main 'zsxq-profile');            Pattern='.'; Recurse=$true }
)
[int64]$grandTotal = 0
foreach ($set in $candidateSets) {
    $files = @(Get-FileSet -Folder $set.Path -Pattern $set.Pattern -Recurse $set.Recurse)
    if ($files.Count -eq 0) { continue }
    $old = @($files | Where-Object { $_.LastWriteTime -lt $cutoff })
    [int64]$oldBytes = 0
    foreach ($f in $old) { $oldBytes += [int64]$f.Length }
    $grandTotal += $oldBytes
    Line ('- ' + $set.Group + ': total ' + $files.Count + ' files / ' + (Format-Size (($files | Measure-Object Length -Sum).Sum)) +
          ' | older-than-' + $MinAgeDays + 'd ' + $old.Count + ' files / ' + (Format-Size $oldBytes) + ' | ' + $set.Path)
}
Line ('- CANDIDATE TOTAL (older than threshold): ' + (Format-Size $grandTotal))
Line ''
Line 'IMPORTANT: Sizes include personal data and rollback snapshots, not reclaimable estimates.'
Line 'No files were modified or deleted by this scan.'
$lines | ForEach-Object { Write-Output $_ }
if ($ReportPath) {
    $parent = Split-Path -Parent $ReportPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { throw 'Report parent does not exist. Create it manually first.' }
    [System.IO.File]::WriteAllLines($ReportPath, $lines, ([System.Text.UTF8Encoding]::new($true)))
}
