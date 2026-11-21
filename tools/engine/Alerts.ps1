<#
  Alerts.ps1 - reads emergency closings out of the district's public live feed.

  This is the reference implementation; ios/EdisonParent/AlertMonitor.swift is
  the port, and tests/alerts.jsonl is the contract. Both are exercised against
  the district's own historical posts, including the false positives
  ("Closed session: 5:30 PM", "we closed it out by having Rutgers players...").

  Why this works at all: Edison posts weather closings and delayed openings to
  the public live feed the AFTERNOON BEFORE - 14:00 to 16:30 in every case on
  record - not at 5am. A phone that checks a few times a day catches them.

  Dot-source Web.ps1 (Convert-HtmlToText) and Answer-Query.ps1 (D / DA /
  Resolve-MonthDay) before this file.
#>

Set-StrictMode -Version Latest

function Get-AlertsFromPost {
    <#
    .SYNOPSIS
        Extracts operational alerts from one live-feed post.
    .PARAMETER Status
        The post's `status` field - the message body, as HTML.
    .PARAMETER PostedAt
        The post's publishing time; bare dates ("Friday, September 11") are
        resolved against it.
    .OUTPUTS
        Zero or more @{ kind; date; line } records.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Status,
        [Parameter(Mandatory)][datetime] $PostedAt,
        [Parameter(Mandatory)] $Rules
    )

    $cfg = D $Rules 'alerts'
    if (-not $cfg) { return @() }

    $text = Convert-HtmlToText $Status
    if (-not $text) { return @() }

    $kinds      = D $cfg 'kinds'
    $reject     = @(DA $cfg 'reject')
    $subjects   = @(DA $cfg 'subjects')
    $subjReq    = @(DA $cfg 'subjectRequiredFor')
    $maxLead    = [int](D $cfg 'maxLeadDays')
    if (-not $maxLead) { $maxLead = 7 }

    $out = New-Object System.Collections.ArrayList

    foreach ($rawLine in ($text -split "`n")) {
        $line = $rawLine.Trim()
        if ($line.Length -lt 8) { continue }
        $low = $line.ToLowerInvariant()

        # Hard rejects first - these beat any positive match.
        $skip = $false
        foreach ($r in $reject) {
            if ($low.Contains(([string]$r).ToLowerInvariant())) { $skip = $true; break }
        }
        if ($skip) { continue }

        # Closure outranks a shortened day, matching the calendar's precedence:
        # if a line somehow says both, there is no school.
        $kind = ''
        foreach ($k in @('closed', 'delayed_opening', 'early_dismissal')) {
            foreach ($phrase in (DA $kinds $k)) {
                if ($low.Contains(([string]$phrase).ToLowerInvariant())) { $kind = $k; break }
            }
            if ($kind) { break }
        }
        if (-not $kind) { continue }

        if ($subjReq -contains $kind) {
            $hasSubject = $false
            foreach ($s in $subjects) {
                if (Test-ContainsPhrase $low ([string]$s)) { $hasSubject = $true; break }
            }
            if (-not $hasSubject) { continue }
        }

        $date = Get-AlertDate -Line $line -PostedAt $PostedAt -Rules $Rules
        if (-not $date) { continue }

        # A weather post always refers to today or tomorrow. The lead-day
        # window keeps a "save the date" note from overriding the calendar.
        $lead = [int]($date - $PostedAt.Date).TotalDays
        if ($lead -lt -1 -or $lead -gt $maxLead) { continue }

        [void]$out.Add([pscustomobject]@{
            Kind = $kind
            Date = $date
            Line = $line
        })
    }
    return $out.ToArray()
}

function Get-AlertDate {
    <#
      Finds the date a line refers to. An explicit date wins; "tomorrow" /
      "today" relative to the post is the fallback.

      Tolerates the district's real punctuation, e.g. "Closed on Monday,
      January, 26." - note the comma between month and day.
    #>
    param(
        [Parameter(Mandatory)][string] $Line,
        [Parameter(Mandatory)][datetime] $PostedAt,
        [Parameter(Mandatory)] $Rules
    )

    $low = $Line.ToLowerInvariant()
    $months = D $Rules 'months'
    $names = @($months.Keys) | Sort-Object { -$_.Length }
    $alt = ($names | ForEach-Object { [regex]::Escape($_) }) -join '|'

    # "February 25, 2026" / "January, 26" / "September 11"
    $m = [regex]::Match($low, "(?<![a-z])($alt)\.?\s*,?\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*(\d{4}))?(?![0-9])")
    if ($m.Success) {
        $mo = [int](D $months $m.Groups[1].Value)
        $dy = [int]$m.Groups[2].Value
        $yr = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }
        $d = Resolve-MonthDay -Month $mo -Day $dy -Year $yr -Today $PostedAt.Date
        if ($d) { return $d }
    }

    # "6/19" or "1.27.26"
    $m = [regex]::Match($low, '(?<![0-9])(\d{1,2})[/.\-](\d{1,2})(?:[/.\-](\d{2,4}))?(?![0-9])')
    if ($m.Success) {
        $yr = 0
        if ($m.Groups[3].Success) {
            $yr = [int]$m.Groups[3].Value
            if ($yr -lt 100) { $yr += 2000 }
        }
        $d = Resolve-MonthDay -Month ([int]$m.Groups[1].Value) -Day ([int]$m.Groups[2].Value) `
                              -Year $yr -Today $PostedAt.Date
        if ($d) { return $d }
    }

    if ($low -match '(?<![a-z])tomorrow(?![a-z])') { return $PostedAt.Date.AddDays(1) }
    if ($low -match '(?<![a-z])today(?![a-z])')    { return $PostedAt.Date }

    return $null
}

function Merge-Alerts {
    <#
      Collapses many posts into one alert per (scope+school, kind, date),
      keeping the most recently posted wording.

      Then drops any school alert that merely repeats a district one: every
      school's feed carries the district's own closing posts verbatim, so
      without this a district snow day would show up 21 times.
    #>
    param([Parameter(Mandatory)] $Alerts)

    $byKey = @{}
    foreach ($a in @($Alerts)) {
        if ($null -eq $a) { continue }
        $sid = ''
        if ($a.PSObject.Properties['schoolId']) { $sid = [string]$a.schoolId }
        elseif ($a -is [System.Collections.IDictionary] -and $a.Contains('schoolId')) { $sid = [string]$a['schoolId'] }

        $key = ('{0}|{1}|{2}' -f $sid, $a.kind, $a.date)
        if ($byKey.ContainsKey($key)) {
            $existing = $byKey[$key]
            if ([datetime]$a.postedAt -le [datetime]$existing.postedAt) { continue }
        }
        $byKey[$key] = $a
    }

    # Every -f expression below is parenthesised: inside an index or a method
    # call, PowerShell splits the comma list and passes the extra operands as
    # further arguments instead of as format values.
    $all = @($byKey.Values)
    $districtKeys = @{}
    foreach ($a in $all) {
        $sid = Get-AlertSchoolId $a
        if (-not $sid) {
            $k = ('{0}|{1}' -f $a.kind, $a.date)
            $districtKeys[$k] = $true
        }
    }
    $kept = @($all | Where-Object {
        $sid = Get-AlertSchoolId $_
        $k = ('{0}|{1}' -f $_.kind, $_.date)
        (-not $sid) -or (-not $districtKeys.ContainsKey($k))
    })

    return @($kept | Sort-Object -Property @{Expression = { [datetime]$_.date }; Descending = $true })
}

function Get-AlertSchoolId {
    param($Alert)
    if ($null -eq $Alert) { return '' }
    if ($Alert -is [System.Collections.IDictionary]) {
        if ($Alert.Contains('schoolId')) { return [string]$Alert['schoolId'] }
        return ''
    }
    $p = $Alert.PSObject.Properties['schoolId']
    if ($p) { return [string]$p.Value }
    return ''
}

function Get-AlertsFromFeed {
    <#
      Parses a whole /live_feeds JSON response into alert records ready for the
      knowledge pack.

    .PARAMETER SchoolId
        Set when reading one school's own feed. Those alerts apply only to that
        school - a boiler failure at Lincoln is not a district closing.
        Left empty for the district feed, which applies to everyone.
    #>
    param(
        [Parameter(Mandatory)] $Feed,
        [Parameter(Mandatory)] $Rules,
        [string] $SchoolId = '',
        [datetime] $Now = (Get-Date)
    )

    $cfg = D $Rules 'alerts'
    $fresh = [int](D $cfg 'freshDays')
    if (-not $fresh) { $fresh = 14 }

    $out = New-Object System.Collections.ArrayList
    foreach ($post in (DA $Feed 'live_feeds')) {
        $status = [string](D $post 'status')
        $pubRaw = [string](D $post 'publishing_at')
        if (-not $pubRaw) { $pubRaw = [string](D $post 'formatted_date') }
        [datetime] $posted = [datetime]::MinValue
        if (-not [datetime]::TryParse($pubRaw, [ref]$posted)) { continue }

        foreach ($a in (Get-AlertsFromPost -Status $status -PostedAt $posted -Rules $Rules)) {
            [void]$out.Add([ordered]@{
                # Composite, matching AlertMonitor.swift: one post can carry
                # several alerts (a single session AND a closure), and the app
                # uses this id both for SwiftUI identity and to avoid
                # notifying twice about the same thing.
                # Parenthesised: inside a hashtable literal the -f operator's
                # comma list collides with the entry separator and the file
                # will not parse.
                id       = ('{0}-{1}-{2}' -f [string](D $post 'id'), $a.Kind, $a.Date.ToString('yyyy-MM-dd'))
                kind     = $a.Kind
                date     = $a.Date.ToString('yyyy-MM-dd')
                postedAt = $posted.ToString('yyyy-MM-ddTHH:mm:ssK')
                text     = $a.Line
                author   = [string](D $post 'author_name')
                scope    = $(if ($SchoolId) { 'school' } else { 'district' })
                schoolId = $SchoolId
            })
        }
    }
    return (Merge-Alerts -Alerts $out.ToArray())
}
