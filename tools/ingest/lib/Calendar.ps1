# Calendar.ps1 - iCalendar parsing and district event classification.

Set-StrictMode -Version Latest

function Expand-IcsLines {
    # RFC 5545 line unfolding: a CRLF followed by space/tab continues the line.
    param([Parameter(Mandatory)][string] $Text)
    return ($Text -replace "\r?\n[ \t]", '')
}

function Get-IcsEvents {
    <#
      Parses VEVENT blocks. Returns objects with:
        Uid, Summary, Description, Location, Start (date), End (date, INCLUSIVE),
        AllDay, StartTime/EndTime (for timed events)

      NOTE on all-day events: RFC 5545 DTEND is EXCLUSIVE. An event covering
      only Nov 26 is stored DTSTART=20261126 DTEND=20261127. We normalise End
      to the last day actually covered, so a one-day event has Start -eq End.
      Getting this wrong shifts every break by a day, so it is tested.
    #>
    param([Parameter(Mandatory)][string] $Ics)

    $text = Expand-IcsLines $Ics
    $out = New-Object System.Collections.ArrayList

    foreach ($m in [regex]::Matches($text, '(?s)BEGIN:VEVENT(.*?)END:VEVENT')) {
        $body = $m.Groups[1].Value

        $uid   = Get-IcsProp $body 'UID'
        $sum   = Unescape-IcsText (Get-IcsProp $body 'SUMMARY')
        $desc  = Unescape-IcsText (Get-IcsProp $body 'DESCRIPTION')
        $loc   = Unescape-IcsText (Get-IcsProp $body 'LOCATION')

        $dtStartRaw = Get-IcsPropRaw $body 'DTSTART'
        $dtEndRaw   = Get-IcsPropRaw $body 'DTEND'
        if (-not $dtStartRaw) { continue }

        $allDay = ($dtStartRaw.Params -match 'VALUE=DATE') -or ($dtStartRaw.Value -match '^\d{8}$')

        $start = Parse-IcsDate $dtStartRaw.Value
        if (-not $start) { continue }

        $end = $start
        if ($dtEndRaw -and $dtEndRaw.Value) {
            $e = Parse-IcsDate $dtEndRaw.Value
            if ($e) {
                if ($allDay) {
                    # exclusive -> inclusive
                    $e = $e.AddDays(-1)
                    if ($e -lt $start) { $e = $start }
                }
                $end = $e
            }
        }

        $startTime = $null; $endTime = $null
        if (-not $allDay) {
            $startTime = $start.ToString('HH:mm')
            if ($dtEndRaw -and $dtEndRaw.Value) {
                $e2 = Parse-IcsDate $dtEndRaw.Value
                if ($e2) { $endTime = $e2.ToString('HH:mm') }
            }
        }

        [void]$out.Add([pscustomobject]@{
            Uid         = $uid
            Summary     = $sum
            Description = $desc
            Location    = $loc
            Start       = $start.Date
            End         = $end.Date
            AllDay      = [bool]$allDay
            StartTime   = $startTime
            EndTime     = $endTime
        })
    }
    return $out.ToArray()
}

function Get-IcsPropRaw {
    param([string] $Body, [string] $Name)
    $m = [regex]::Match($Body, ('(?m)^' + [regex]::Escape($Name) + '([^:\r\n]*):(.*)$'))
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{
        Params = $m.Groups[1].Value
        Value  = $m.Groups[2].Value.Trim()
    }
}

function Get-IcsProp {
    param([string] $Body, [string] $Name)
    $r = Get-IcsPropRaw $Body $Name
    if ($r) { return $r.Value }
    return ''
}

function Unescape-IcsText {
    param([string] $S)
    if (-not $S) { return '' }
    $S = $S -replace '\\n', "`n" -replace '\\N', "`n"
    $S = $S -replace '\\,', ',' -replace '\\;', ';'
    $S = $S -replace '\\\\', '\'
    return $S.Trim()
}

function Parse-IcsDate {
    param([string] $V)
    if (-not $V) { return $null }
    $V = $V.Trim()
    $fmts = @('yyyyMMddTHHmmssZ', 'yyyyMMddTHHmmss', 'yyyyMMdd')
    foreach ($f in $fmts) {
        [datetime] $d = [datetime]::MinValue
        $styles = if ($f -eq 'yyyyMMddTHHmmssZ') {
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
        } else {
            [System.Globalization.DateTimeStyles]::None
        }
        if ([datetime]::TryParseExact($V, $f, [cultureinfo]::InvariantCulture, $styles, [ref]$d)) {
            return $d
        }
    }
    return $null
}

# ---------------------------------------------------------------- classification

<#
  Event kinds used by the answer engine. Order matters: the first matching
  rule wins, so the more specific patterns come first.

    closed            - no school for students or staff
    early_dismissal   - school opens as usual, dismisses early
    single_session    - district's term for a shortened (AM-only style) day
    delayed_opening   - school starts late
    no_school_students - staff in, students out (PD day etc.)
    break             - multi-day recess
    last_day / first_day
    event             - everything else (concerts, picture day, ...)
#>
$script:EventRules = @(
    @{ Kind = 'delayed_opening';    Pattern = 'delayed\s+opening|late\s+start|delayed\s+start|2\s*hour\s+delay' }
    @{ Kind = 'early_dismissal';    Pattern = 'early\s+dismissal|early\s+release|minimum\s+day' }
    @{ Kind = 'single_session';     Pattern = 'single\s+session' }
    @{ Kind = 'break';              Pattern = '\b(recess|break)\b' }
    @{ Kind = 'no_school_students'; Pattern = 'no\s+school\s+for\s+students|students?\s+do\s+not\s+report|staff\s+(only|development|in-?service)|professional\s+development\s+day' }
    @{ Kind = 'closed';             Pattern = 'schools?\s+closed|school\s+closed|closed\b|no\s+school' }
    @{ Kind = 'last_day';           Pattern = 'last\s+day\s+of\s+school' }
    @{ Kind = 'first_day';          Pattern = 'first\s+day\s+of\s+school|schools?\s+open\b' }
)

function Get-EventKind {
    param([string] $Summary, [string] $Description = '')
    $hay = (($Summary + ' ' + $Description)).ToLowerInvariant()
    foreach ($r in $script:EventRules) {
        if ($hay -match $r.Pattern) { return $r.Kind }
    }
    return 'event'
}

function Test-EventClosesSchool {
    param([string] $Kind)
    return ($Kind -in @('closed', 'break'))
}

function Get-EventTitleClean {
    <# Strips the district's "Districtwide: " / "MON - " style prefixes. #>
    param([string] $Summary)
    $s = $Summary
    $s = [regex]::Replace($s, '^\s*districtwide\s*:\s*', '', 'IgnoreCase')
    $s = [regex]::Replace($s, '^\s*(MON|TUE|TUES|WED|THU|THUR|THURS|FRI|SAT|SUN)\s*[-–]\s*', '', 'IgnoreCase')
    $s = [regex]::Replace($s, '^\s*\d{1,2}:\d{2}\s*(am|pm)\s*[-–]\s*', '', 'IgnoreCase')
    return $s.Trim()
}
