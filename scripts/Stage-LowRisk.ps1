# WorkBuddy C drive staging helper for Windows PowerShell 5.1+
# Plan = read-only preview. Stage = move allowlisted old files into a review folder.
# Depth: Standard (default) / Thorough / Maximum.
# Maximum requires -AcknowledgeLossOfFeatures, set only after the user explicitly
# says rollback history and saved logins are not needed.
# It NEVER deletes files or touches active sessions, skills, plugins, runtime, db or program files.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Stage')][string]$Mode = 'Plan',
    [ValidateSet('Standard','Thorough','Maximum')][string]$Depth = 'Standard',
    [int]$MinAgeDays = 7,
    [string]$StageRoot = "",
    [switch]$AcknowledgeLossOfFeatures,
    [switch]$IncludeProfileCache,
    [switch]$Flat,
    [switch]$ConfirmStage
)
$ErrorActionPreference = 'Stop'
if (-not $env:USERPROFILE -or -not $env:LOCALAPPDATA -or -not $env:APPDATA) { throw 'Requires Windows USERPROFILE / LOCALAPPDATA / APPDATA.' }
if ($MinAgeDays -lt 1) { throw 'MinAgeDays must be at least 1.' }
if ($Mode -eq 'Stage' -and -not $ConfirmStage) { throw 'Stage requires -ConfirmStage, after specific user approval.' }
if (-not $StageRoot) { throw 'StageRoot is required. Ask the user which drive/folder to use, then pass it explicitly with -StageRoot. No default drive is assumed.' }
$StageRoot = [System.IO.Path]::GetFullPath($StageRoot)
$drive = Split-Path -Path $StageRoot -Qualifier
if ($drive -and -not (Test-Path -LiteralPath $drive)) { throw "Stage drive $drive does not exist or is not accessible. Ask the user for a different destination. Aborted." }
if ($StageRoot.TrimEnd('\') -ieq ($env:USERPROFILE.TrimEnd('\'))) { throw 'Refusing to stage into the user profile root. Ask for a dedicated folder.' }

$depthRank = @{ Standard=1; Thorough=2; Maximum=3 }
$rank = $depthRank[$Depth]
if ($Depth -eq 'Maximum' -and -not $AcknowledgeLossOfFeatures) {
    throw 'Depth=Maximum requires -AcknowledgeLossOfFeatures. Explain that rollback history and saved logins will be lost, then set this flag ONLY after the user explicitly says those features are not needed.'
}

$main = Join-Path $env:USERPROFILE '.workbuddy'
$cutoff = (Get-Date).AddDays(-$MinAgeDays)

# Allowlist by tier. AllowFragments lifts a denylist fragment for that group only.
# PathGuard further restricts a group to an exact subdirectory pattern.
$sets = @(
    [pscustomobject]@{ Group='user-logs';        Path=(Join-Path $main 'logs');                                 Recurse=$true;  Pattern='(?i)\.log(\.\d+)?$'; MinDepth='Standard'; AllowFragments=@() },
    [pscustomobject]@{ Group='local-logs';       Path=(Join-Path $env:LOCALAPPDATA 'WorkBuddy\logs');            Recurse=$false; Pattern='(?i)\.log(\.\d+)?$'; MinDepth='Standard'; AllowFragments=@() },
    [pscustomobject]@{ Group='clipboard-images'; Path=(Join-Path $main 'clipboard-images');                     Recurse=$false; Pattern='.';               MinDepth='Standard'; AllowFragments=@() },
    [pscustomobject]@{ Group='product-spill';    Path=(Join-Path $main 'cache\conversation-product-spill');      Recurse=$false; Pattern='.';               MinDepth='Standard'; AllowFragments=@() },
    [pscustomobject]@{ Group='traces';           Path=(Join-Path $main 'traces');                               Recurse=$true;  Pattern='.';               MinDepth='Standard'; AllowFragments=@() },
    [pscustomobject]@{ Group='shell-snapshots';  Path=(Join-Path $main 'shell-snapshots');                      Recurse=$false; Pattern='.';               MinDepth='Standard'; AllowFragments=@() },

    [pscustomobject]@{ Group='roaming-webstorage'; Path=(Join-Path $env:APPDATA 'WorkBuddy\WebStorage');         Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='roaming-cacheddata'; Path=(Join-Path $env:APPDATA 'WorkBuddy\CachedData');         Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='roaming-cache';      Path=(Join-Path $env:APPDATA 'WorkBuddy\Cache');              Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='roaming-logs';       Path=(Join-Path $env:APPDATA 'WorkBuddy\logs');               Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='market-sources';     Path=(Join-Path $main 'connectors-marketplace-sources');      Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='market-connectors';  Path=(Join-Path $main 'connectors-marketplace');             Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='market-skills';      Path=(Join-Path $main 'skills-marketplace');                 Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='index-tree';         Path=(Join-Path $main 'file-tree-manifests');                Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@('file-tree-manifests') },
    [pscustomobject]@{ Group='index-changes-det';  Path=(Join-Path $main 'changes-detail');                     Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@('changes-detail') },
    [pscustomobject]@{ Group='index-changes-idx';  Path=(Join-Path $main 'changes-index');                      Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@('changes-index') },
    [pscustomobject]@{ Group='index-artifact';     Path=(Join-Path $main 'artifact-index');                     Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },
    [pscustomobject]@{ Group='index-audit';        Path=(Join-Path $main 'audit-log');                          Recurse=$true; Pattern='.'; MinDepth='Thorough'; AllowFragments=@() },

    [pscustomobject]@{ Group='rollback-filehistory'; Path=(Join-Path $main 'file-history');                     Recurse=$true; Pattern='.'; MinDepth='Maximum'; AllowFragments=@('file-history') },
    [pscustomobject]@{ Group='rollback-snapshots';   Path=(Join-Path $main 'workspace\sessions');               Recurse=$true; Pattern='.'; MinDepth='Maximum'; AllowFragments=@('sessions','modify_backup'); PathGuard='(?i)\\workspace\\sessions\\[^\\]+\\modify_backup\\' },
    [pscustomobject]@{ Group='login-profile';        Path=(Join-Path $main 'zsxq-profile');                     Recurse=$true; Pattern='.'; MinDepth='Maximum'; AllowFragments=@() }
)
$denied = @('sessions','projects','file-history','file-tree-manifests','changes-detail','changes-index',
            'buddy-snapshots','space-history','blobs','plugins','skills','binaries','modify_backup',
            'workbuddy.db','.vscdb','.db-wal','.db-shm','keyblob','settings.json','mcp.json')

$items = @()
foreach ($set in $sets) {
    if ($depthRank[$set.MinDepth] -gt $rank) { continue }
    if (-not (Test-Path -LiteralPath $set.Path -PathType Container)) { continue }
    $root = Get-Item -LiteralPath $set.Path -Force
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    $params = @{ LiteralPath = $set.Path; Force = $true; File = $true; ErrorAction = 'SilentlyContinue' }
    if ($set.Recurse) { $params['Recurse'] = $true }
    foreach ($file in @(Get-ChildItem @params)) {
        if ($file.LastWriteTime -ge $cutoff) { continue }
        if ($file.Name -notmatch $set.Pattern) { continue }
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $lower = $file.FullName.ToLowerInvariant()
        if ($set.PSObject.Properties['PathGuard'] -and $set.PathGuard -and $file.FullName -notmatch $set.PathGuard) { continue }
        $blocked = $false
        foreach ($frag in $denied) {
            $fl = $frag.ToLowerInvariant()
            if (-not $lower.Contains($fl)) { continue }
            $allowed = $false
            foreach ($a in @($set.AllowFragments)) { if ($a.ToLowerInvariant() -eq $fl) { $allowed = $true; break } }
            if (-not $allowed) { $blocked = $true; break }
        }
        if ($blocked) { continue }
        $items += [pscustomobject]@{ Group=$set.Group; Original=$file.FullName; Name=$file.Name; Bytes=[int64]$file.Length; Modified=$file.LastWriteTime }
    }
}
$items = @($items | Sort-Object Original)
[long]$total = 0
foreach ($f in $items) { $total += $f.Bytes }
Write-Output ('Mode=' + $Mode + ' ; Depth=' + $Depth + ' ; eligible file count=' + $items.Count + ' ; logical bytes=' + $total + ' ; age >=' + $MinAgeDays + 'd')
foreach ($f in $items) { Write-Output ($f.Group + ' | ' + $f.Bytes + ' | ' + $f.Modified.ToString('yyyy-MM-dd') + ' | ' + $f.Original) }
if ($Mode -eq 'Plan') { Write-Output 'READ-ONLY PLAN. No files moved or deleted.'; return }
if ($items.Count -eq 0) { Write-Output 'Nothing to stage.'; return }

$runName = 'stage-' + $Depth + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$run = Join-Path $StageRoot $runName
if (Test-Path -LiteralPath $run) { throw 'Stage folder collision. Aborted.' }
New-Item -Path $run -ItemType Directory -Force | Out-Null

$usedNames = New-Object 'System.Collections.Generic.HashSet[string]'
function Get-DestPath($file, $groupHash) {
    if ($Flat) {
        $name = $file.Name
        if (-not $groupHash.Add($name.ToLowerInvariant())) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $ext  = [System.IO.Path]::GetExtension($name)
            $i = 1
            while (-not $groupHash.Add(("$stem`_$i$ext").ToLowerInvariant())) { $i++ }
            $name = "$stem`_$i$ext"
        }
        return (Join-Path $run $name)
    }
    return (Join-Path (Join-Path $run $groupHash) $file.Name)
}
$destByOriginal = @{}
$destHash = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($f in $items) {
    $d = if ($Flat) { Get-DestPath $f $usedNames } else { Join-Path (Join-Path $run $f.Group) $f.Name }
    if (-not $Flat) {
        if (-not $destHash.Add($d.ToLowerInvariant())) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $ext  = [System.IO.Path]::GetExtension($f.Name)
            $i = 1
            while (-not $destHash.Add((Join-Path (Join-Path $run $f.Group) "$stem`_$i$ext").ToLowerInvariant())) { $i++ }
            $d = Join-Path (Join-Path $run $f.Group) "$stem`_$i$ext"
        }
    }
    $destByOriginal[$f.Original] = $d
}

$preflight = foreach ($f in $items) {
    [pscustomobject]@{
        Status='PLANNED'; OriginalPath=$f.Original;
        StagedPath=$destByOriginal[$f.Original];
        Bytes=$f.Bytes; Reason=''
    }
}
$csv = Join-Path $run 'manifest.csv'
$preflight | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$manifest = @()
foreach ($f in $items) {
    $src = $f.Original
    $dest = $destByOriginal[$f.Original]
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -Path $destDir -ItemType Directory | Out-Null }
    $status = 'SKIPPED'
    $reason = ''
    try {
        $current = Get-Item -LiteralPath $src -Force -ErrorAction Stop
        if ($current.PSIsContainer) { throw 'Source became a directory.' }
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse point detected.' }
        if ($current.LastWriteTime -ge $cutoff) { throw 'Source is too recent.' }
        if ($current.Length -ne $f.Bytes) { throw 'Source size changed.' }
        if (Test-Path -LiteralPath $dest) { throw 'Destination already exists.' }
        Move-Item -LiteralPath $src -Destination $dest -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw 'Destination not found after move.' }
        $status = 'STAGED'
    } catch {
        $reason = $_.Exception.Message
        Write-Output ('SKIP or CHECK MANUALLY: ' + $src + ' | ' + $reason)
    }
    $manifest += [pscustomobject]@{ Status=$status; OriginalPath=$src; StagedPath=$dest; Bytes=$f.Bytes; Reason=$reason }
    $manifest | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
}
$manifest | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$note = Join-Path $run 'READ-ME-FIRST.txt'
$notes = @(
    'WORKBUDDY C DRIVE REVIEW FOLDER',
    ('Cleanup depth: ' + $Depth),
    'Only allowlisted old files from the exact configured folders were eligible.',
    'Read manifest.csv before deleting anything. Do not infer that SKIPPED files moved.',
    'Verify the staged files, then delete THIS FOLDER manually to free space on the destination drive.',
    'NOTE: staging already freed the ORIGINAL C: drive; deleting this folder frees the DESTINATION drive.',
    'If you need the files back, copy them from StagedPath to OriginalPath in manifest.csv before deleting.',
    'No active sessions, skills, plugins, databases, runtime or program files were moved.',
    'If a move failed, it was skipped once. Do not elevate or retry automatically.',
    'FILES THAT CANNOT BE DELETED: if Windows refuses to delete a file here (locked, path too long, permission, in use), and even Administrator mode does not help, open CODEX in this folder and ask it to delete the rest, or point terra at this exact folder and let it clean up. Do not force, take ownership, elevate, or retry with different commands yourself.',
    'AFTER CLEANING: remind the user to point the app default storage / cache / output folder to another drive if configurable, otherwise C: will fill up again. This script never edits configuration.'
)
if ($Depth -eq 'Maximum') {
    $notes += 'DEPTH=MAXIMUM: rollback history and saved logins were included because the user explicitly said those features are not needed. Restoring them is not guaranteed.'
}
[IO.File]::WriteAllLines($note, $notes, [System.Text.UTF8Encoding]::new($true))
Write-Output ('REVIEW FOLDER: ' + $run)
Write-Output ('MANIFEST: ' + $csv)
Write-Output 'No files deleted. User must review and manually remove staged files.'
