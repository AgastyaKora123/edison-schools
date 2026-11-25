<#
.SYNOPSIS
    Runs tests/questions.jsonl against the reference answer engine.

.DESCRIPTION
    Each case asserts the resolver that fired (when given) and that the answer
    text contains / does not contain the expected substrings. Comment lines in
    the JSONL (objects with only a "_" key) are skipped.

    Exit code 0 = all passed, 1 = at least one failure. Build.bat refuses to
    ship a pack when this fails.

.PARAMETER Verbose0
    Print every case, not just failures.
#>
[CmdletBinding()]
param(
    [string] $Pack,
    [string] $Rules,
    [string] $Questions,
    [switch] $ShowAll,
    [string] $Filter,
    [string] $StaffFixture
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Here
. "$Root\engine\Answer-Query.ps1"

if (-not $Pack)      { $Pack      = Join-Path $Root 'dist\knowledge-pack.json' }
if (-not $Rules)     { $Rules     = Join-Path $Root 'ingest\rules\intents.json' }
if (-not $Questions) { $Questions = Join-Path $Here 'questions.jsonl' }

if (-not (Test-Path $Pack))  { throw "Knowledge pack not found: $Pack  (run ingest\Build-KnowledgePack.ps1 first)" }
if (-not (Test-Path $Rules)) { throw "Rules not found: $Rules" }

$packObj  = Import-KnowledgePack -Path $Pack
$rulesObj = Import-Rules -Path $Rules

Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue

# Staff lists are not part of the pack: they are read from each school's own
# directory while the app is running, and 2,105 Edison staff would be four
# hundred kilobytes of names going stale in a two-megabyte app. So the staff
# cases get a stand-in roster injected into a copy of the real pack, the same
# way the alert tests inject a closing. Rows with only a "_" key are notes.
if ($StaffFixture) {
    if (-not (Test-Path $StaffFixture)) { throw "Staff fixture not found: $StaffFixture" }
    # Test-Path follows Set-Location; [IO.File] does not - it uses the
    # process's own directory, which never moved. A relative path passed on
    # the command line therefore passes the check and then fails the read,
    # looking for the file under whichever folder PowerShell started in.
    $StaffFixture = (Resolve-Path -LiteralPath $StaffFixture).Path
    $roster = @($ser.DeserializeObject([IO.File]::ReadAllText($StaffFixture)) |
                Where-Object { $_.ContainsKey('name') })
    if (-not $roster.Count) { throw "Staff fixture has no people: $StaffFixture" }
    $packObj['staff'] = $roster
    Write-Host ("      staff fixture: {0} people" -f $roster.Count) -ForegroundColor DarkGray
}

$pass = 0; $fail = 0; $skip = 0
$failures = New-Object System.Collections.ArrayList
$sw = [Diagnostics.Stopwatch]::StartNew()

$lineNo = 0
foreach ($line in [IO.File]::ReadAllLines($Questions)) {
    $lineNo++
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }

    try { $case = $ser.DeserializeObject($line) }
    catch { Write-Warning "line ${lineNo}: unparseable JSON - skipped"; $skip++; continue }

    if (-not $case.ContainsKey('q')) { continue }        # comment row
    $q = [string]$case['q']
    if ($Filter -and $q -notmatch $Filter) { continue }

    $today = if ($case.ContainsKey('today')) { [datetime]::ParseExact([string]$case['today'], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) } else { Get-Date }
    $defSchool = if ($case.ContainsKey('school')) { [string]$case['school'] } else { '' }

    $errs = @()
    $ans = $null
    try {
        $ans = Invoke-Query -Pack $packObj -Rules $rulesObj -Query $q -Today $today -DefaultSchoolId $defSchool
    } catch {
        $errs += "THREW: $($_.Exception.Message)"
    }

    if ($ans) {
        $text = [string]$ans.answer
        if ([string]::IsNullOrWhiteSpace($text)) { $errs += 'empty answer' }

        if ($case.ContainsKey('resolver')) {
            $want = [string]$case['resolver']
            $got  = [string]$ans.debug.resolver
            if ($got -ne $want) { $errs += "resolver: want '$want', got '$got'" }
        }
        if ($case.ContainsKey('contains')) {
            foreach ($nAny in @($case['contains'])) {
                $n = [string]$nAny
                if (-not $n) { continue }
                if ($text -notlike "*$n*") { $errs += "missing: '$n'" }
            }
        }
        if ($case.ContainsKey('notContains')) {
            foreach ($nAny in @($case['notContains'])) {
                $n = [string]$nAny
                if (-not $n) { continue }
                if ($text -like "*$n*") { $errs += "should not contain: '$n'" }
            }
        }
    }

    if ($errs.Count) {
        $fail++
        [void]$failures.Add([pscustomobject]@{ Line = $lineNo; Q = $q; Errors = $errs; Answer = $(if ($ans) { [string]$ans.answer } else { '' }); Debug = $(if ($ans) { $ans.debug } else { $null }) })
        Write-Host ("FAIL  " + $q) -ForegroundColor Red
        foreach ($e in $errs) { Write-Host ("      - " + $e) -ForegroundColor DarkYellow }
    } else {
        $pass++
        if ($ShowAll) {
            Write-Host ("ok    " + $q) -ForegroundColor DarkGreen
            foreach ($l in ([string]$ans.answer -split "`n")) { Write-Host ("      " + $l) -ForegroundColor DarkGray }
        }
    }
}
$sw.Stop()

if ($failures.Count) {
    Write-Host ''
    Write-Host '--- failure detail ---' -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host ''
        Write-Host ("line {0}: {1}" -f $f.Line, $f.Q) -ForegroundColor Red
        if ($f.Debug) {
            Write-Host ("  slots: resolver={0} date={1} school={2} level={3} sched={4} break={5}" -f `
                $f.Debug.resolver, $f.Debug.dateSlot, $f.Debug.schoolSlot, $f.Debug.levelSlot, `
                $f.Debug.scheduleSlot, $f.Debug.breakSlot) -ForegroundColor DarkGray
        }
        foreach ($l in ($f.Answer -split "`n")) { Write-Host ("  | " + $l) -ForegroundColor Gray }
    }
}

Write-Host ''
$color = if ($fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("=== {0} passed, {1} failed, {2} skipped in {3:N1}s ===" -f $pass, $fail, $skip, $sw.Elapsed.TotalSeconds) -ForegroundColor $color
Write-Host ''

if ($fail -gt 0) { exit 1 }
exit 0
