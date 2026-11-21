<#
.SYNOPSIS
    Downloads every district and school page into the cache, several at a time.

.DESCRIPTION
    Each page on this CMS is about 2 MB, and there are roughly 900 of them.
    Fetched one after another that is about an hour, almost all of it spent
    waiting on the network rather than doing anything.

    This fetches a few at once into the same cache the main collection uses,
    so the collection afterwards finds everything already there and only has
    to read it. Pages already cached are skipped, so stopping and restarting
    this costs nothing.

    Kept deliberately modest - a handful of connections, with a pause between
    batches. This is someone else's school district, not a load test.

.PARAMETER Concurrency
    How many pages to fetch at once. Default 5.
#>
[CmdletBinding()]
param(
    [int] $Concurrency = 5,
    [int] $MaxAgeHours = 24,
    [switch] $SchoolsOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$Here\lib\Web.ps1"

$CacheDir = Join-Path $Here '.cache'
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

$DistrictHost = 'www.edison.k12.nj.us'
$UserAgent = 'EdisonParentAgent/1.0 (district information cache; contact webmaster@edison.k12.nj.us)'

function Get-CacheFile {
    # Must match Get-CacheKey in Build-KnowledgePack.ps1 exactly, or the
    # collection will not find what this downloaded. Long addresses are hashed
    # rather than truncated: the feed addresses differ only at the end, and
    # cutting them made twenty schools share one file.
    param([string] $Url)
    $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Url)) -replace '[/+=]', '_'
    if ($key.Length -gt 120) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url))).Replace('-', '')
        } finally { $sha.Dispose() }
        $key = $key.Substring(0, 60) + '_' + $hash.Substring(0, 32)
    }
    return Join-Path $CacheDir "$key.txt"
}

Write-Host ''
Write-Host '  Gathering the list of pages' -ForegroundColor Cyan
Write-Host '  --------------------------' -ForegroundColor DarkGray

$urls = New-Object System.Collections.ArrayList

# The district homepage is not a "/page/" address, so the sweep below misses
# it - but the collection needs it first of all, for the school list. Save it
# here so a later run has it even with no network.
if (-not $SchoolsOnly) { [void]$urls.Add("https://$DistrictHost/") }

# --- district pages
if (-not $SchoolsOnly) {
    $sx = Get-Web -Url "https://$DistrictHost/sitemap.xml"
    if ($sx) {
        $n = 0
        foreach ($m in [regex]::Matches($sx, '<loc>([^<]+)</loc>')) {
            $u = $m.Groups[1].Value
            if ($u -match '/page/[^/]+/?$') { [void]$urls.Add($u); $n++ }
        }
        Write-Host ("      district: {0} pages" -f $n)
    }
}

# --- school pages, read from each school's own sitemap
$homeHtml = Get-Web -Url "https://$DistrictHost/"
$state = Get-ClientWorkState -Html $homeHtml
$orgs = @(Get-Prop $state 'organizations')
foreach ($o in $orgs) {
    if (Get-Prop $o 'primary') { continue }
    $orgUrl = [string](Get-Prop $o 'org_url')
    if (-not $orgUrl) { continue }
    $h = if ($orgUrl -match '^([^/]+)') { $Matches[1] } else { $orgUrl }

    $sx = Get-Web -Url "https://$h/sitemap.xml"
    if (-not $sx) { Write-Warning "no sitemap for $h"; continue }
    $n = 0
    foreach ($m in [regex]::Matches($sx, '<loc>([^<]+)</loc>')) {
        $u = $m.Groups[1].Value
        if ($u -match '/page/[^/]+/?$') { [void]$urls.Add($u); $n++ }
    }
    # The homepage carries the footer we read the office phone from.
    [void]$urls.Add("https://$orgUrl")
    Write-Host ("      {0,-34} {1} pages" -f [string](Get-Prop $o 'name'), $n)
}

$all = @($urls | Select-Object -Unique)
Write-Host ''
Write-Host ("  {0} pages in total" -f $all.Count) -ForegroundColor Cyan

# --- what is missing from the cache
$cutoff = (Get-Date).AddHours(-$MaxAgeHours)
$todo = @($all | Where-Object {
    $f = Get-CacheFile $_
    -not (Test-Path $f) -or ((Get-Item $f).LastWriteTime -lt $cutoff)
})
Write-Host ("  {0} already cached, {1} to fetch" -f ($all.Count - $todo.Count), $todo.Count) -ForegroundColor DarkGray

if (-not $todo.Count) {
    Write-Host ''
    Write-Host '  Nothing to do - every page is already cached.' -ForegroundColor Green
    Write-Host ''
    return
}

Write-Host ''
Write-Host ("  Fetching {0} at a time" -f $Concurrency) -ForegroundColor Cyan
Write-Host '  ---------------------' -ForegroundColor DarkGray

$pool = [RunspaceFactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()

$work = {
    param($Url, $Path, $Ua)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -Uri $Url -UserAgent $Ua -UseBasicParsing -TimeoutSec 60
        [IO.File]::WriteAllText($Path, [string]$r.Content, (New-Object System.Text.UTF8Encoding $false))
        return @{ Url = $Url; Ok = $true; Bytes = $r.Content.Length }
    } catch {
        return @{ Url = $Url; Ok = $false; Error = $_.Exception.Message }
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$done = 0; $failed = 0; $bytes = 0
$batchNo = 0

for ($i = 0; $i -lt $todo.Count; $i += $Concurrency) {
    $batchNo++
    $batch = $todo[$i..([Math]::Min($i + $Concurrency - 1, $todo.Count - 1))]
    $running = @()

    foreach ($u in $batch) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($work).AddArgument($u).AddArgument((Get-CacheFile $u)).AddArgument($UserAgent)
        $running += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    foreach ($r in $running) {
        try {
            $res = $r.PS.EndInvoke($r.Handle)
            foreach ($x in $res) {
                if ($x.Ok) { $done++; $bytes += $x.Bytes }
                else { $failed++; Write-Verbose ("failed: {0} - {1}" -f $x.Url, $x.Error) }
            }
        } catch {
            $failed++
        } finally {
            $r.PS.Dispose()
        }
    }

    if ($batchNo % 5 -eq 0 -or ($i + $Concurrency) -ge $todo.Count) {
        $pct = [math]::Round(100 * ($done + $failed) / $todo.Count)
        $rate = if ($sw.Elapsed.TotalSeconds -gt 0) { ($done + $failed) / $sw.Elapsed.TotalSeconds } else { 0 }
        $left = if ($rate -gt 0) { [TimeSpan]::FromSeconds(($todo.Count - $done - $failed) / $rate) } else { [TimeSpan]::Zero }
        Write-Host ("      {0,3}%  {1}/{2} pages  {3:N0} MB  about {4:N0} min left" -f `
            $pct, ($done + $failed), $todo.Count, ($bytes / 1MB), $left.TotalMinutes)
    }

    # A pause between batches, so this stays gentle on the district's servers.
    Start-Sleep -Milliseconds 250
}

$pool.Close()
$pool.Dispose()
$sw.Stop()

Write-Host ''
Write-Host ('  Done: {0} pages fetched, {1} failed, {2:N0} MB in {3:N1} minutes' -f `
    $done, $failed, ($bytes / 1MB), $sw.Elapsed.TotalMinutes) -ForegroundColor Green
Write-Host ''
