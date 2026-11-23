# WorkBuddy C drive OVERVIEW - read-only first step of the whole workflow.
# Produces ONE report that answers: what exists, what can be deleted, what can be migrated,
# what must be kept, and the totals of each. No file is copied, moved or deleted.
# Output uses English labels for encoding safety; the agent presents a Chinese table to the user.
[CmdletBinding()]
param(
    [int]$MinAgeDays = 7,
    [int]$IdleDays = 30,
    [int]$Top = 8
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
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) }
            else { $sum += [int64]$child.Length }
        }
    }
    return $sum
}
function Fmt([int64]$v) {
    if ($v -ge 1GB) { return ('{0:N2} GiB' -f ($v/1GB)) }
    if ($v -ge 1MB) { return ('{0:N1} MiB' -f ($v/1MB)) }
    if ($v -ge 1KB) { return ('{0:N1} KiB' -f ($v/1KB)) }
    return ("$v B")
}
$lines = New-Object 'System.Collections.Generic.List[string]'
function L([string]$m) { [void]$script:lines.Add($m) }

L '# WORKBUDDY C DRIVE OVERVIEW (read-only)'
L ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    if ($null -ne $disk) { L ('C_FREE: ' + (Fmt ([int64]$disk.FreeSpace)) + ' / TOTAL ' + (Fmt ([int64]$disk.Size))) }
} catch { L 'C_FREE: unavailable' }
L ''

$main = Join-Path $env:USERPROFILE '.workbuddy'
$projects = Join-Path $main 'projects'

# ---- Section 1: what exists ----
L '## SECTION 1 EXISTING (sizes, keep whole directories)'
$roots = @(
    @{N='workbuddy_home';P=$main},
    @{N='local_appdata';P=(Join-Path $env:LOCALAPPDATA 'WorkBuddy')},
    @{N='roaming_appdata';P=(Join-Path $env:APPDATA 'WorkBuddy')},
    @{N='install_dir';P=(Join-Path $env:LOCALAPPDATA 'Programs\WorkBuddy')}
)
foreach ($r in $roots) {
    if (Test-Path -LiteralPath $r.P -PathType Container) { L ('ROOT | ' + $r.N + ' | ' + (Fmt (Get-SizeBytes $r.P)) + ' | ' + $r.P) }
}
L ''
if (Test-Path -LiteralPath $main -PathType Container) {
    L '## SECTION 1b TOP FOLDERS INSIDE .workbuddy'
    $children = @(Get-ChildItem -LiteralPath $main -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } |
        ForEach-Object { [pscustomobject]@{N=$_.Name;B=(Get-SizeBytes $_.FullName)} } | Sort-Object B -Descending)
    foreach ($c in ($children | Select-Object -First $Top)) { L ('TOP | ' + $c.N + ' | ' + (Fmt $c.B)) }
    L ''
}

# ---- Section 2: DELETABLE (reuse the same allowlist logic as Stage-LowRisk Standard) ----
L ('## SECTION 2 DELETABLE (age >= ' + $MinAgeDays + 'd, auto-rebuild, Standard tier)')
$cutoff = (Get-Date).AddDays(-$MinAgeDays)
$delSets = @(
    [pscustomobject]@{G='old-logs-user';P=(Join-Path $main 'logs');R=$true;Pat='(?i)\.log(\.\d+)?$'},
    [pscustomobject]@{G='old-logs-local';P=(Join-Path $env:LOCALAPPDATA 'WorkBuddy\logs');R=$false;Pat='(?i)\.log(\.\d+)?$'},
    [pscustomobject]@{G='clipboard-images';P=(Join-Path $main 'clipboard-images');R=$false;Pat='.'},
    [pscustomobject]@{G='product-spill';P=(Join-Path $main 'cache\conversation-product-spill');R=$false;Pat='.'},
    [pscustomobject]@{G='traces';P=(Join-Path $main 'traces');R=$true;Pat='.'},
    [pscustomobject]@{G='shell-snapshots';P=(Join-Path $main 'shell-snapshots');R=$false;Pat='.'}
)
[int64]$delTotal = 0
[int]$delFiles = 0
foreach ($s in $delSets) {
    if (-not (Test-Path -LiteralPath $s.P -PathType Container)) { continue }
    $p = @{LiteralPath=$s.P;Force=$true;File=$true;ErrorAction='SilentlyContinue'}
    if ($s.R) { $p['Recurse']=$true }
    $old = @(Get-ChildItem @p | Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Name -match $s.Pat -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) })
    if ($old.Count -eq 0) { continue }
    [int64]$b = ($old | Measure-Object Length -Sum).Sum
    $delTotal += $b; $delFiles += $old.Count
    L ('DEL | ' + $s.G + ' | ' + $old.Count + ' files | ' + (Fmt $b))
}
L ('DEL_TOTAL | ' + $delFiles + ' files | ' + (Fmt $delTotal))
L ''

# ---- Section 3: MIGRATABLE projects (idle, excludes active) ----
L ('## SECTION 3 MIGRATABLE PROJECTS (idle >= ' + $IdleDays + 'd, active workspace excluded)')
$hardExclude = @('d-WorkBuddy 工作区','workbuddy')
$idleCut = (Get-Date).AddDays(-$IdleDays)
[int64]$migTotal = 0
[int]$migDirs = 0
$rows = @()
if (Test-Path -LiteralPath $projects -PathType Container) {
    foreach ($d in @(Get-ChildItem -LiteralPath $projects -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($hardExclude -contains $d.Name) { continue }
        $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { continue }
        $last = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        if ($last -ge $idleCut) { continue }
        [int64]$b = ($files | Measure-Object Length -Sum).Sum
        if ($b -eq 0) { continue }
        $migTotal += $b; $migDirs++
        $rows += [pscustomobject]@{N=$d.Name;B=$b;F=$files.Count;L=$last}
    }
}
foreach ($r in (@($rows | Sort-Object B -Descending) | Select-Object -First $Top)) {
    L ('MIG | ' + $r.N + ' | ' + $r.F + ' files | ' + (Fmt $r.B) + ' | last ' + $r.L.ToString('yyyy-MM-dd'))
}
L ('MIG_TOTAL | ' + $migDirs + ' dirs | ' + (Fmt $migTotal))
L ''

# ---- Section 4: KEEP (with reason) ----
L '## SECTION 4 MUST KEEP (do not delete)'
L 'KEEP | binaries | app runtime, program breaks without it'
L 'KEEP | workspace\sessions | conversations and files; modify_backup = rollback versions'
L 'KEEP | skills / plugins | installed capabilities'
L 'KEEP | *.db / settings.json / mcp.json / keyblob | database and credentials'
L 'KEEP | program install dir | application itself'
L 'KEEP | active workspace project (d-WorkBuddy 工作区) | currently in use'
L ''
L '## SUMMARY'
L ('DELETABLE: ' + $delFiles + ' files / ' + (Fmt $delTotal))
L ('MIGRATABLE: ' + $migDirs + ' projects / ' + (Fmt $migTotal))
L ('C_FREE_AFTER_BOTH (theoretical, only if user deletes bundles): current free + ' + (Fmt ($delTotal + $migTotal)))
L 'NOTE: sizes are measured; totals are theoretical upper bounds. Nothing was copied, moved or deleted by this report.'
$lines | ForEach-Object { Write-Output $_ }
