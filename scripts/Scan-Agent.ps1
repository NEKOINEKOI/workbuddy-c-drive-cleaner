# Agent-agnostic read-only scanner. ONE agent per run (default: workbuddy).
# Reads agents/registry.json. Produces the same four-section report as Report-Overview
# but for whichever agent the user named. Copies/moves/deletes NOTHING.
# The agent switch is deliberate: never scan several agents at once.
[CmdletBinding()]
param(
    [string]$Agent = 'workbuddy',
    [int]$MinAgeDays = 7,
    [int]$IdleDays = 30,
    [int]$Top = 10,
    [switch]$ListAgents,
    [string]$RegistryPath = ''
)
$ErrorActionPreference = 'Continue'
if (-not $env:USERPROFILE) { throw 'USERPROFILE is not available. Windows is required.' }

if (-not $RegistryPath) { $RegistryPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'agents\registry.json' }
if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { throw "Registry not found: $RegistryPath" }
$reg = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Expand-Tokens([string]$s) {
    if (-not $s) { return '' }
    return $s.Replace('$USERPROFILE$', $env:USERPROFILE).Replace('$LOCALAPPDATA$', $env:LOCALAPPDATA).Replace('$APPDATA$', $env:APPDATA)
}

if ($ListAgents) {
    Write-Output 'AVAILABLE AGENTS (registry):'
    $reg.agents.PSObject.Properties | ForEach-Object { Write-Output ('  ' + $_.Name + '  ->  ' + $_.Value.label) }
    Write-Output ('DEFAULT: workbuddy')
    exit 0
}

if (-not $reg.agents.PSObject.Properties[$Agent]) {
    Write-Output ("UNKNOWN AGENT: $Agent")
    Write-Output 'Run with -ListAgents to see valid names.'
    exit 1
}
$cfg = $reg.agents.$Agent

function Get-SizeBytes([string]$Folder) {
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return [int64]0 }
    $root = Get-Item -LiteralPath $Folder -Force -ErrorAction SilentlyContinue
    if ($null -eq $root -or (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return [int64]0 }
    [int64]$sum = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Folder)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) } else { $sum += [int64]$child.Length }
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

L ('# AGENT C DRIVE SCAN (read-only)  agent=' + $Agent + '  label=' + $cfg.label)
L ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    if ($null -ne $disk) { L ('C_FREE: ' + (Fmt ([int64]$disk.FreeSpace)) + ' / TOTAL ' + (Fmt ([int64]$disk.Size))) }
} catch { L 'C_FREE: unavailable' }
L 'ONE-AGENT RULE: only this agent is scanned. To clean another agent, finish this one first, then rerun with a different -Agent.'
L ''

# Section 1: existing roots
L '## SECTION 1 EXISTING'
$allRoots = @()
foreach ($h in @($cfg.home)) { if ($h) { $allRoots += (Expand-Tokens $h) } }
foreach ($a in @($cfg.appdata)) { if ($a) { $allRoots += (Expand-Tokens $a) } }
if ($cfg.install) { $allRoots += (Expand-Tokens $cfg.install) }
foreach ($r in $allRoots) {
    if (Test-Path -LiteralPath $r -PathType Container) { L ('ROOT | ' + (Fmt (Get-SizeBytes $r)) + ' | ' + $r) }
}
L ''
foreach ($h in @($cfg.home)) {
    $homePath = Expand-Tokens $h
    if (-not (Test-Path -LiteralPath $homePath -PathType Container)) { continue }
    L ('## SECTION 1b TOP FOLDERS IN ' + $homePath)
    $kids = @(Get-ChildItem -LiteralPath $homePath -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } |
        ForEach-Object { [pscustomobject]@{N=$_.Name;B=(Get-SizeBytes $_.FullName)} } | Sort-Object B -Descending)
    foreach ($c in ($kids | Select-Object -First $Top)) { L ('TOP | ' + $c.N + ' | ' + (Fmt $c.B)) }
    L ''
}

# Section 2: deletable per agent rules
L ('## SECTION 2 DELETABLE (age >= ' + $MinAgeDays + 'd; per-agent allowlist, user must confirm)')
$cutoff = (Get-Date).AddDays(-$MinAgeDays)
[int64]$delTotal = 0
[int]$delFiles = 0
foreach ($d in @($cfg.deletable)) {
    $p = Expand-Tokens $d.path
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { continue }
    $old = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) })
    if ($old.Count -eq 0) { continue }
    [int64]$b = ($old | Measure-Object Length -Sum).Sum
    $delTotal += $b; $delFiles += $old.Count
    L ('DEL | ' + $d.path + ' | kind=' + $d.kind + ' | tier=' + $d.tier + ' | ' + $old.Count + ' files | ' + (Fmt $b))
}
L ('DEL_TOTAL | ' + $delFiles + ' files | ' + (Fmt $delTotal))
L ''

# Section 3: migratable (only for agents that define idle-project dirs)
L ('## SECTION 3 MIGRATABLE (idle >= ' + $IdleDays + 'd)')
[int64]$migTotal = 0
[int]$migDirs = 0
$idleCut = (Get-Date).AddDays(-$IdleDays)
foreach ($m in @($cfg.migratable)) {
    $mp = Expand-Tokens $m.path
    if (-not $mp -or -not (Test-Path -LiteralPath $mp -PathType Container)) { continue }
    $excl = @($m.exclude)
    foreach ($dir in @(Get-ChildItem -LiteralPath $mp -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($excl -contains $dir.Name) { continue }
        $fs = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($fs.Count -eq 0) { continue }
        $last = ($fs | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        if ($last -ge $idleCut) { continue }
        [int64]$b = ($fs | Measure-Object Length -Sum).Sum
        if ($b -eq 0) { continue }
        $migTotal += $b; $migDirs++
        L ('MIG | ' + $dir.Name + ' | ' + $fs.Count + ' files | ' + (Fmt $b) + ' | last ' + $last.ToString('yyyy-MM-dd'))
    }
}
L ('MIG_TOTAL | ' + $migDirs + ' dirs | ' + (Fmt $migTotal))
L ''

# Section 4: protected
L '## SECTION 4 MUST KEEP (per-agent, do not delete)'
foreach ($k in @($cfg.protected)) { L ('KEEP | ' + $k) }
L ''
L '## NOTES'
L ('DEFAULT_STORAGE: ' + $cfg.default_storage_note)
L ('MANUAL_DELETE: ' + $cfg.manual_delete_note)
L ''
L '## SUMMARY'
L ('DELETABLE: ' + $delFiles + ' files / ' + (Fmt $delTotal))
L ('MIGRATABLE: ' + $migDirs + ' dirs / ' + (Fmt $migTotal))
L ('C_FREE_AFTER_BOTH (theoretical, only if user deletes bundles): current free + ' + (Fmt ($delTotal + $migTotal)))
L 'NOTE: sizes measured; totals theoretical. Nothing was copied, moved or deleted.'
$lines | ForEach-Object { Write-Output $_ }
