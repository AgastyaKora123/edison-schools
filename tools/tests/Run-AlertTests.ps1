<#
.SYNOPSIS
    Runs tests/alerts.jsonl against the reference closing-alert parser.

.DESCRIPTION
    Every fixture is a verbatim post from the district's public live feed.
    Exit code 0 = all passed, 1 = at least one failure.
#>
[CmdletBinding()]
param(
    [string] $Rules,
    [string] $Fixtures,
    [switch] $ShowAll
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Here
. "$Root\ingest\lib\Web.ps1"
. "$Root\engine\Answer-Query.ps1"
. "$Root\engine\Alerts.ps1"

if (-not $Rules)    { $Rules    = Join-Path $Root 'ingest\rules\intents.json' }
if (-not $Fixtures) { $Fixtures = Join-Path $Here 'alerts.jsonl' }

$rulesObj = Import-Rules -Path $Rules

Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue

$pass = 0; $fail = 0
$lineNo = 0

foreach ($raw in [IO.File]::ReadAllLines($Fixtures)) {
    $lineNo++
    $line = $raw.Trim()
    if (-not $line -or -not $line.StartsWith('{')) { continue }
    $c = $ser.DeserializeObject($line)
    if (-not $c.ContainsKey('status')) { continue }

    $name = [string]$c['name']
    [datetime] $posted = [datetime]::Parse([string]$c['postedAt'])

    $got = @(Get-AlertsFromPost -Status ([string]$c['status']) -PostedAt $posted -Rules $rulesObj)
    $gotKeys = @($got | ForEach-Object { '{0}@{1}' -f $_.Kind, $_.Date.ToString('yyyy-MM-dd') })

    $wantKeys = @()
    foreach ($w in @($c['expect'])) {
        if ($null -eq $w) { continue }
        $wantKeys += '{0}@{1}' -f [string]$w['kind'], [string]$w['date']
    }

    $missing = @($wantKeys | Where-Object { $gotKeys -notcontains $_ })
    $extra   = @($gotKeys  | Where-Object { $wantKeys -notcontains $_ })

    if ($missing.Count -or $extra.Count) {
        $fail++
        Write-Host ("FAIL  " + $name) -ForegroundColor Red
        if ($missing.Count) { Write-Host ("      missing: " + ($missing -join ', ')) -ForegroundColor DarkYellow }
        if ($extra.Count)   { Write-Host ("      extra:   " + ($extra   -join ', ')) -ForegroundColor DarkYellow }
        foreach ($g in $got) {
            Write-Host ("      got '{0}' from: {1}" -f $g.Kind, $g.Line) -ForegroundColor DarkGray
        }
    } else {
        $pass++
        if ($ShowAll) {
            Write-Host ("ok    " + $name) -ForegroundColor DarkGreen
            foreach ($g in $got) {
                Write-Host ("      {0} {1}" -f $g.Date.ToString('yyyy-MM-dd'), $g.Kind) -ForegroundColor DarkGray
            }
        }
    }
}

# ---------------------------------------------------------------- pack shape

# The app uses an alert's id for SwiftUI identity and for "did I already
# notify about this", so duplicates would both break list rendering and let a
# second notification through. One post can legitimately carry several alerts.

Write-Host ''
Write-Host '--- pack alert shape ---' -ForegroundColor Cyan

$packPathShape = Join-Path $Root 'dist\knowledge-pack.json'
if (Test-Path $packPathShape) {
    $p0 = Import-KnowledgePack -Path $packPathShape
    $ids = @(DA $p0 'alerts' | ForEach-Object { [string](D $_ 'id') })
    $dupes = @($ids | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count) {
        Write-Host ("FAIL  duplicate alert ids: " + (($dupes | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("ok    {0} alert ids, all unique" -f $ids.Count) -ForegroundColor DarkGreen
        $pass++
    }

    if ([string](D $p0 'alertFeedUrl')) {
        Write-Host 'ok    alertFeedUrl present' -ForegroundColor DarkGreen; $pass++
    } else {
        Write-Host 'FAIL  alertFeedUrl missing - the app cannot poll' -ForegroundColor Red; $fail++
    }
}

# ---------------------------------------------------------------- override

# The whole point of the alert layer: on a snow day the published calendar says
# "normal full day" and is wrong. Inject an alert into a copy of the real pack
# and prove the answer flips.

Write-Host ''
Write-Host '--- calendar override ---' -ForegroundColor Cyan

$packPath = Join-Path $Root 'dist\knowledge-pack.json'
if (-not (Test-Path $packPath)) {
    Write-Host 'SKIP  no pack in dist/ - run the ingest first' -ForegroundColor DarkYellow
} else {
    $pack = Import-KnowledgePack -Path $packPath

    # 2026-12-10 is a Thursday with nothing on the district calendar.
    $target = [datetime]'2026-12-10'
    $today  = [datetime]'2026-12-09'

    $before = Invoke-Query -Pack $pack -Rules $rulesObj -Query 'is there school tomorrow' -Today $today
    $okBefore = $before.answer -like '*open*'
    if ($okBefore) {
        Write-Host 'ok    baseline: calendar says open' -ForegroundColor DarkGreen; $pass++
    } else {
        Write-Host 'FAIL  baseline should have been open' -ForegroundColor Red
        Write-Host ("      $($before.answer)") -ForegroundColor Gray; $fail++
    }

    # JavaScriptSerializer gives plain dictionaries, so the pack is mutable.
    $pack['alerts'] = @(
        @{
            id       = '999'
            kind     = 'closed'
            date     = $target.ToString('yyyy-MM-dd')
            postedAt = '2026-12-09T15:02:00-05:00'
            text     = 'Due to inclement weather, Edison Township Public Schools will be closed tomorrow, Thursday, December 10.'
            author   = 'District'
            scope    = 'district'
        }
    )

    $after = Invoke-Query -Pack $pack -Rules $rulesObj -Query 'is there school tomorrow' -Today $today
    $checks = @(
        @{ Name = 'answers closed';        Ok = ($after.answer -like '*closed*') }
        @{ Name = 'says No';               Ok = ($after.answer -like 'No*') }
        @{ Name = 'cites the announcement'; Ok = ($after.answer -like '*announcement posted*') }
        @{ Name = 'links the live feed';   Ok = (($after.sources -join ' ') -like '*live-feed*') }
    )
    foreach ($c in $checks) {
        if ($c.Ok) { Write-Host ("ok    override: {0}" -f $c.Name) -ForegroundColor DarkGreen; $pass++ }
        else       { Write-Host ("FAIL  override: {0}" -f $c.Name) -ForegroundColor Red; $fail++ }
    }
    $anyFailed = @($checks | Where-Object { -not $_.Ok }).Count -gt 0
    if ($ShowAll -or $anyFailed) {
        foreach ($l in ($after.answer -split "`n")) { Write-Host ("      $l") -ForegroundColor DarkGray }
    }

    # A single-building closure must not close the whole district. This is the
    # failure mode that would matter most: a Woodbrook parent told to keep
    # their kid home because Lincoln lost heat.
    $pack['alerts'] = @(
        @{ id = '997'; kind = 'closed'; date = $target.ToString('yyyy-MM-dd')
           postedAt = '2026-12-09T15:02:00-05:00'
           text = 'Lincoln Elementary School will be closed tomorrow due to a water main break.'
           author = 'Lincoln'; scope = 'school'; schoolId = 'les' }
    )
    $atLincoln = Invoke-Query -Pack $pack -Rules $rulesObj -Query 'is there school tomorrow at Lincoln' -Today $today
    $atWoodbrook = Invoke-Query -Pack $pack -Rules $rulesObj -Query 'is there school tomorrow at Woodbrook' -Today $today
    $noSchoolNamed = Invoke-Query -Pack $pack -Rules $rulesObj -Query 'is there school tomorrow' -Today $today

    $scopeChecks = @(
        @{ Name = 'Lincoln is closed';            Ok = ($atLincoln.answer -like '*closed*') }
        @{ Name = 'Woodbrook is NOT closed';      Ok = ($atWoodbrook.answer -like '*open*') }
        @{ Name = 'no school named stays open';   Ok = ($noSchoolNamed.answer -like '*open*') }
    )
    foreach ($c in $scopeChecks) {
        if ($c.Ok) { Write-Host ("ok    scope: {0}" -f $c.Name) -ForegroundColor DarkGreen; $pass++ }
        else {
            Write-Host ("FAIL  scope: {0}" -f $c.Name) -ForegroundColor Red; $fail++
            Write-Host ("      lincoln:   $($atLincoln.answer -replace "`n",' | ')") -ForegroundColor Gray
            Write-Host ("      woodbrook: $($atWoodbrook.answer -replace "`n",' | ')") -ForegroundColor Gray
            Write-Host ("      unnamed:   $($noSchoolNamed.answer -replace "`n",' | ')") -ForegroundColor Gray
        }
    }

    # A delayed opening must also change the reported start times.
    $pack['alerts'] = @(
        @{ id = '998'; kind = 'delayed_opening'; date = $target.ToString('yyyy-MM-dd')
           postedAt = '2026-12-09T15:02:00-05:00'
           text = 'two-hour delayed opening tomorrow'; author = 'District'; scope = 'district' }
    )
    $delayed = Invoke-Query -Pack $pack -Rules $rulesObj -Query 'what time does middle school start tomorrow' -Today $today
    if ($delayed.answer -like '*10:25 AM*') {
        Write-Host 'ok    override: delayed opening shifts bell times' -ForegroundColor DarkGreen; $pass++
    } else {
        Write-Host 'FAIL  override: delayed opening should report 10:25 AM' -ForegroundColor Red
        foreach ($l in ($delayed.answer -split "`n")) { Write-Host ("      $l") -ForegroundColor Gray }
        $fail++
    }
}

Write-Host ''
$color = if ($fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("=== alerts: {0} passed, {1} failed ===" -f $pass, $fail) -ForegroundColor $color
Write-Host ''
if ($fail -gt 0) { exit 1 }
exit 0
