<#
.SYNOPSIS
    Finds every school district that runs on the same website software as
    Edison, so the app can answer for any of them.

.DESCRIPTION
    Edison's website is built on Apptegy's Thrillshare platform, which several
    thousand US districts use. Every one of them serves the same public,
    key-free calendar and announcement feeds that this app already reads for
    Edison - the only thing that changes is an organisation number in the
    address.

    There is no public list of those numbers, and a district's own homepage
    cannot be read from a web browser (the browser blocks reading another
    site's pages). So the list has to be built once, here, and shipped with
    the app.

    This walks the organisation numbers and writes down what answers. Each
    probe asks for a page of events far past the end, which costs about 4 KB
    and still names every section - and a district's sections are its schools.

    Deliberately modest: a handful of connections with a pause between
    batches, and an honest user agent. This is someone else's service.

    Resumable. Results append to a JSONL file as they arrive, and a rerun
    skips every id already written, so stopping it costs nothing.

.PARAMETER From
    First organisation number to try.

.PARAMETER To
    Last organisation number to try.

.PARAMETER Concurrency
    How many to ask at once. Default 6.

.PARAMETER OutFile
    Where the findings go. Default ingest\.cache\orgs.jsonl
#>
[CmdletBinding()]
param(
    [int] $From = 1,
    [int] $To = 35000,
    [int] $Concurrency = 6,
    [int] $PauseMs = 250,
    [string] $OutFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$CacheDir = Join-Path $Here '.cache'
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
if (-not $OutFile) { $OutFile = Join-Path $CacheDir 'orgs.jsonl' }

$UserAgent = 'EdisonParentAgent/1.0 (building a parent information app; +https://github.com/AgastyaKora123/edison-schools)'
$ApiRoot   = 'https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o'

# ---------------------------------------------------------------- resume

$done = New-Object 'System.Collections.Generic.HashSet[int]'
if (Test-Path $OutFile) {
    foreach ($line in [IO.File]::ReadAllLines($OutFile)) {
        if ($line -match '"id"\s*:\s*(\d+)') { [void]$done.Add([int]$Matches[1]) }
    }
}

$todo = New-Object System.Collections.ArrayList
for ($i = $From; $i -le $To; $i++) {
    if (-not $done.Contains($i)) { [void]$todo.Add($i) }
}

Write-Host ''
Write-Host '=== Looking for districts on the same platform ===' -ForegroundColor Cyan
Write-Host ("  range {0}-{1}, {2} already known, {3} to try" -f $From, $To, $done.Count, $todo.Count)
Write-Host ("  {0} at a time, {1}ms between batches" -f $Concurrency, $PauseMs)
Write-Host ''

if (-not $todo.Count) { Write-Host '  Nothing left to do.' -ForegroundColor Green; return }

# ---------------------------------------------------------------- probe

# Runs in its own runspace, so everything it needs is passed in; nothing from
# this script's scope is visible inside.
$work = {
    param([int] $Id, [string] $Root, [string] $Ua)

    $url = "$Root/$Id/cms/events?page_no=9999"
    $out = [ordered]@{ id = $Id; ok = $false }
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25 `
                               -Headers @{ 'User-Agent' = $Ua } -ErrorAction Stop
        if ($r.StatusCode -ne 200) { return $out }

        $body = ''
        try {
            $stream = $r.RawContentStream
            if ($stream) { $stream.Position = 0; $body = [Text.Encoding]::UTF8.GetString($stream.ToArray()) }
        } catch { }
        if (-not $body) { $body = [string]$r.Content }
        if (-not $body) { return $out }

        # Sections are the district's schools. Name and id both matter: the id
        # is what the calendar feed for that school is asked for later.
        $names = @(); $ids = @()
        foreach ($m in [regex]::Matches($body, '\{"id":(\d+),"name":"((?:[^"\\]|\\.)*)","slug":"((?:[^"\\]|\\.)*)"')) {
            $ids   += [int]$m.Groups[1].Value
            $names += $m.Groups[2].Value
        }

        $out.ok = $true
        $out.sectionCount = $names.Count
        $out.sectionIds   = $ids
        $out.sectionNames = $names
        return $out
    } catch {
        # 404 is the ordinary answer for a number nobody uses. Anything else
        # is recorded so a rerun can tell "does not exist" from "went wrong".
        $status = 0
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        $out.status = $status
        return $out
    }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()

$writer = New-Object System.IO.StreamWriter($OutFile, $true, (New-Object System.Text.UTF8Encoding $false))
$writer.AutoFlush = $true

$found = 0; $tried = 0; $errors = 0
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    for ($i = 0; $i -lt $todo.Count; $i += $Concurrency) {
        $batch = $todo[$i..([Math]::Min($i + $Concurrency - 1, $todo.Count - 1))]

        $running = @()
        foreach ($id in $batch) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($work).AddArgument($id).AddArgument($ApiRoot).AddArgument($UserAgent)
            $running += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }

        foreach ($r in $running) {
            $res = $null
            try { $res = $r.PS.EndInvoke($r.Handle) } catch { $errors++ }
            finally { $r.PS.Dispose() }
            $tried++
            if (-not $res) { continue }
            $rec = @($res)[0]
            if (-not $rec) { continue }

            if ($rec.ok) {
                $found++
                # One object per line. Written as it arrives, so a stopped run
                # loses nothing but the batch in flight.
                $json = '{"id":' + $rec.id + ',"sectionCount":' + $rec.sectionCount +
                        ',"sectionIds":[' + (($rec.sectionIds | ForEach-Object { [string]$_ }) -join ',') + ']' +
                        ',"sectionNames":[' + (($rec.sectionNames | ForEach-Object {
                            '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"'
                        }) -join ',') + ']}'
                $writer.WriteLine($json)
            } else {
                $st = 404
                try { if ($null -ne $rec.status) { $st = [int]$rec.status } } catch { }
                $writer.WriteLine(('{"id":' + $rec.id + ',"miss":' + $st + '}'))
            }
        }

        if ($PauseMs -gt 0) { Start-Sleep -Milliseconds $PauseMs }

        if ((($i / $Concurrency) % 25) -eq 0 -or ($i + $Concurrency) -ge $todo.Count) {
            $rate = if ($sw.Elapsed.TotalSeconds -gt 0) { $tried / $sw.Elapsed.TotalSeconds } else { 0 }
            $left = if ($rate -gt 0) { [TimeSpan]::FromSeconds(($todo.Count - $tried) / $rate) } else { [TimeSpan]::Zero }
            Write-Host ("  {0,6}/{1}  found {2,5}  {3:N1}/s  about {4:hh\:mm} left" -f
                        $tried, $todo.Count, $found, $rate, $left)
        }
    }
} finally {
    $writer.Dispose()
    $pool.Close(); $pool.Dispose()
}

Write-Host ''
Write-Host ("  Done. {0} organisations answered out of {1} tried, {2} errors, in {3:hh\:mm\:ss}." -f
            $found, $tried, $errors, $sw.Elapsed) -ForegroundColor Green
Write-Host ("  {0}" -f $OutFile) -ForegroundColor Green
Write-Host ''
