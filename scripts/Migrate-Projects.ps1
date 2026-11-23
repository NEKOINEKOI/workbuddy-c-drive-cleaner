# WorkBuddy project/workspace MIGRATION helper for Windows PowerShell 5.1+
# Different from Stage-LowRisk: this MOVES disposable PROJECT FOLDERS to another drive.
# Safe order: COPY source -> VERIFY copy -> STAGE original into a review bundle -> user deletes manually.
# Modes: Plan (read-only) / Migrate (copy + stage). It NEVER deletes anything.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Migrate')][string]$Mode = 'Plan',
    [string]$TargetRoot = "",
    [string]$ReviewRoot = "",
    [int]$MinIdleDays = 30,
    [string[]]$IncludeName = @(),
    [switch]$ConfirmMigrate
)
$ErrorActionPreference = 'Stop'
if (-not $env:USERPROFILE) { throw 'USERPROFILE is not available. Windows is required.' }
if ($MinIdleDays -lt 0) { throw 'MinIdleDays must be 0 or greater.' }
if ($Mode -eq 'Migrate' -and -not $ConfirmMigrate) { throw 'Migrate requires -ConfirmMigrate, after the user reviews the exact folder list.' }
# Still ask the user first. If they give no path (or say "default"), use these:
#   migration copies -> D:\WorkBuddy
#   C: source bundle -> %USERPROFILE%\WorkBuddy-待删包
if (-not $TargetRoot) {
    $TargetRoot = Join-Path 'D:\' 'WorkBuddy'
    Write-Output ('NOTE: no TargetRoot given; using DEFAULT target: ' + $TargetRoot)
}
if (-not $ReviewRoot) {
    $ReviewRoot = Join-Path $env:USERPROFILE 'WorkBuddy-待删包'
    Write-Output ('NOTE: no ReviewRoot given; using DEFAULT C: bundle: ' + $ReviewRoot)
}
$TargetRoot = [System.IO.Path]::GetFullPath($TargetRoot)
$ReviewRoot = [System.IO.Path]::GetFullPath($ReviewRoot)
foreach ($r in @($TargetRoot, $ReviewRoot)) {
    $drv = Split-Path -Path $r -Qualifier
    if ($drv -and -not (Test-Path -LiteralPath $drv)) { throw "Drive $drv for $r does not exist or is not accessible. Ask the user for a different path. Aborted." }
}
if ($TargetRoot.TrimEnd('\') -ieq $ReviewRoot.TrimEnd('\')) { throw 'TargetRoot and ReviewRoot must be different folders. Aborted.' }

$main = Join-Path $env:USERPROFILE '.workbuddy'
$projects = Join-Path $main 'projects'
if (-not (Test-Path -LiteralPath $projects -PathType Container)) { throw "Projects folder not found: $projects" }

# HARD EXCLUSIONS: never migrate the active workspace, skills, runtime, or anything outside projects.
$hardExclude = @(
    'd-WorkBuddy 工作区',
    'workbuddy'
)
function Get-DirStats([string]$Path) {
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $bytes = [int64](($files | Measure-Object Length -Sum).Sum)
    $last = [datetime]'1970-01-01'
    if ($files.Count -gt 0) { $last = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime }
    return [pscustomobject]@{ Bytes=$bytes; Files=$files.Count; Last=$last }
}

$cutoff = (Get-Date).AddDays(-$MinIdleDays)
$hasInclude = @($IncludeName).Count -gt 0
$candidates = @()
foreach ($dir in @(Get-ChildItem -LiteralPath $projects -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $name = $dir.Name
    if ($hardExclude -contains $name) { continue }
    # When -IncludeName is given, ONLY those exact names are eligible. It is a strict whitelist,
    # never an "extra". Hard exclusions above still win.
    $explicit = @($IncludeName) -contains $name
    if ($hasInclude -and -not $explicit) { continue }
    $st = Get-DirStats $dir.FullName
    # Idle rule applies only when no explicit list was given.
    if (-not $hasInclude -and $st.Last -ge $cutoff) { continue }
    if ($st.Bytes -eq 0) { continue }
    $candidates += [pscustomobject]@{ Name=$name; Source=$dir.FullName; Bytes=$st.Bytes; Files=$st.Files; Last=$st.Last; Explicit=$explicit }
}
if ($hasInclude) {
    $missing = @($IncludeName | Where-Object { @($candidates.Name) -notcontains $_ })
    if ($missing.Count -gt 0) { Write-Output ('NOTE: not eligible (missing/hard-excluded/empty): ' + ($missing -join ', ')) }
}
$candidates = @($candidates | Sort-Object Bytes -Descending)
[long]$totalBytes = 0
foreach ($c in $candidates) { $totalBytes += $c.Bytes }
Write-Output ('Mode=' + $Mode + ' ; candidates=' + $candidates.Count + ' ; logical bytes=' + $totalBytes + ' ; idle >=' + $MinIdleDays + 'd ; explicit=' + @($IncludeName).Count)
foreach ($c in $candidates) {
    Write-Output ('CAND | ' + $c.Name + ' | ' + $c.Bytes + ' B | ' + $c.Files + ' files | ' + $c.Last.ToString('yyyy-MM-dd') + ' | ' + $c.Source)
}
if ($Mode -eq 'Plan') { Write-Output 'READ-ONLY PLAN. Nothing copied, moved or deleted.'; return }
if ($candidates.Count -eq 0) { Write-Output 'Nothing to migrate.'; return }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$migRoot = Join-Path $TargetRoot ('migrated-' + $stamp)
$reviewBundle = Join-Path $ReviewRoot ('c-drive-projects-' + $stamp)
New-Item -Path $migRoot -ItemType Directory -Force | Out-Null
New-Item -Path $reviewBundle -ItemType Directory -Force | Out-Null

$rows = @()
foreach ($c in $candidates) {
    $src = $c.Source
    $dst = Join-Path $migRoot $c.Name
    $bundle = Join-Path $reviewBundle $c.Name
    $status = 'SKIPPED'
    $reason = ''
    try {
        # Step 1: copy to target drive. One attempt only; failure -> skip, keep original intact.
        if (Test-Path -LiteralPath $dst) { throw 'Destination already exists on target drive.' }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop
        # Step 2: verify copy against source before touching the original.
        $srcFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction Stop)
        $dstFiles = @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction Stop)
        if ($srcFiles.Count -ne $dstFiles.Count) { throw "Copy verify failed: source $($srcFiles.Count) files vs copy $($dstFiles.Count) files." }
        [long]$srcSum = ($srcFiles | Measure-Object Length -Sum).Sum
        [long]$dstSum = ($dstFiles | Measure-Object Length -Sum).Sum
        if ($srcSum -ne $dstSum) { throw "Copy verify failed: source $srcSum bytes vs copy $dstSum bytes." }
        # Step 3: only after verified copy, stage the C: original into the review bundle.
        Move-Item -LiteralPath $src -Destination $bundle -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $bundle -PathType Container)) { throw 'Bundle not found after move.' }
        $status = 'MIGRATED'
    } catch {
        $reason = $_.Exception.Message
        Write-Output ('SKIP: ' + $c.Name + ' | ' + $reason)
    }
    $rows += [pscustomobject]@{
        Status=$status; Name=$c.Name; Bytes=$c.Bytes; Files=$c.Files;
        OriginalPath=$src; MigratedTo=$dst; BundlePath=$bundle; Reason=$reason
    }
}

$csv = Join-Path $migRoot 'migration-manifest.csv'
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$bundleCsv = Join-Path $reviewBundle 'manifest.csv'
$rows | Export-Csv -LiteralPath $bundleCsv -NoTypeInformation -Encoding UTF8

$migrated = @($rows | Where-Object { $_.Status -eq 'MIGRATED' })
[long]$movedBytes = ($migrated | Measure-Object Bytes -Sum).Sum
[long]$movedFiles = ($migrated | Measure-Object Files -Sum).Sum

$note = Join-Path $reviewBundle 'READ-ME-FIRST.txt'
$notes = @(
    'WORKBUDDY C DRIVE PROJECT REVIEW BUNDLE',
    ('Migrated folder count: ' + $migrated.Count),
    ('Migrated file count: ' + $movedFiles),
    ('Migrated logical size: ' + [math]::Round($movedBytes/1MB,1) + ' MB'),
    '',
    'These C: originals were COPIED to the target drive and verified BEFORE being moved here.',
    'The verified copies are listed in migration-manifest.csv under MigratedTo.',
    'Check that the copies are complete and WorkBuddy still works, then delete THIS BUNDLE manually to free C: drive space.',
    'Deleting this bundle frees C: space. The copies on the target drive are kept.',
    'To restore: move a folder from BundlePath back to OriginalPath (see manifest.csv).',
    'The active workspace and all config/runtime/skills/plugins were never migrated.',
    'If a file will not delete (locked, path too long, permission), and even Administrator mode does not help, open CODEX in this folder and ask it to delete the rest, or point terra at this exact folder and let it clean up. Do not force or take ownership yourself.',
    'AFTER MIGRATING: remind the user to change the app default storage / cache / output folder to the new drive, otherwise C: will fill up again. Changing app settings is the user decision - this script never edits configuration.'
)
[IO.File]::WriteAllLines($note, $notes, [System.Text.UTF8Encoding]::new($true))

Write-Output ('MIGRATED COUNT: ' + $migrated.Count + ' folders / ' + $movedFiles + ' files / ' + [math]::Round($movedBytes/1MB,1) + ' MB')
Write-Output ('TARGET FOLDER: ' + $migRoot)
Write-Output ('REVIEW BUNDLE (delete this manually): ' + $reviewBundle)
Write-Output ('MANIFEST: ' + $bundleCsv)
Write-Output 'No files deleted. User must verify and manually remove the review bundle.'
