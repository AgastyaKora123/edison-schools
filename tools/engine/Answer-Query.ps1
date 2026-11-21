<#
  Answer-Query.ps1 - the Edison Parent answer engine, reference implementation.

  This is the ORACLE. ios/EdisonParent/AnswerEngine.swift is a port of it, and
  tests/questions.jsonl is the contract both must satisfy. If you change
  behaviour here, change it there and rerun tests/Run-Tests.ps1.

  Pipeline:
    normalise -> extract slots (date, school, level, schedule kind)
              -> score intents -> run the winning resolver -> compose answer

  Everything is deterministic and offline: no model call, no network. For the
  question set parents actually ask (is there school, what time, when is the
  break, who do I call) a resolver beats retrieval, because the answer has to
  be a specific date or time, not a paragraph that mentions one.
#>

Set-StrictMode -Version Latest

# ================================================================ loading

function Import-KnowledgePack {
    param([Parameter(Mandatory)][string] $Path)
    $raw = [IO.File]::ReadAllText($Path)
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 2000
    return $ser.DeserializeObject($raw)   # nested Dictionary/Object[]
}

function Import-Rules {
    param([Parameter(Mandatory)][string] $Path)
    return Import-KnowledgePack -Path $Path
}

function D {
    <# Dictionary/array field access that tolerates missing keys. #>
    param($Obj, [string] $Key)
    if ($null -eq $Obj) { return $null }
    # JavaScriptSerializer yields Dictionary<string,object>: its Contains()
    # takes a KeyValuePair, so go through ContainsKey.
    if ($Obj -is [System.Collections.Generic.IDictionary[string, object]]) {
        if ($Obj.ContainsKey($Key)) { return $Obj[$Key] }
        return $null
    }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Key)) { return $Obj[$Key] }
        return $null
    }
    if ($Obj -is [psobject]) {
        $p = $Obj.PSObject.Properties[$Key]
        if ($p) { return $p.Value }
    }
    return $null
}

function DA {
    <# Field access that always yields an array. #>
    param($Obj, [string] $Key)
    $v = D $Obj $Key
    if ($null -eq $v) { return @() }
    return @($v)
}

# ================================================================ text utils

function Normalize-Query {
    param([string] $Q)
    if (-not $Q) { return '' }
    $s = $Q.ToLowerInvariant()
    $s = $s -replace '[‘’ʼ]', "'"
    $s = $s -replace '[“”]', '"'
    $s = $s -replace '&', ' and '
    # keep digits, letters, and the separators dates use
    $s = [regex]::Replace($s, "[^a-z0-9/:'\-\. ]", ' ')
    $s = [regex]::Replace($s, '\s+', ' ')
    return $s.Trim()
}

function Get-Tokens {
    param([string] $Norm)
    if (-not $Norm) { return @() }
    return @([regex]::Split($Norm, "[^a-z0-9]+") | Where-Object { $_.Length -gt 0 })
}

function Test-ContainsPhrase {
    <# Whole-word phrase containment. #>
    param([string] $Haystack, [string] $Needle)
    if (-not $Needle) { return $false }
    $pat = '(?<![a-z0-9])' + [regex]::Escape($Needle).Replace('\ ', '\s+') + '(?![a-z0-9])'
    return [regex]::IsMatch($Haystack, $pat)
}

function Get-SquashedDoubles {
    <# "dissmisal" and "dismissal" both become "dismisal". #>
    param([string] $Text)
    return [regex]::Replace($Text, '([a-z])\1+', '$1')
}

function Test-ContainsPhrasePlural {
    <#
      Like Test-ContainsPhrase, but lets the last word be plural. "How many
      late starts this year" was finding no schedule kind at all: the word
      list holds "late start" and the whole-word match stopped at the "s".
      Listing every plural by hand is the treadmill; allowing one is not.
    #>
    param([string] $Haystack, [string] $Needle)
    if (-not $Needle) { return $false }
    $pat = '(?<![a-z0-9])' + [regex]::Escape($Needle).Replace('\ ', '\s+') + '(?:es|s)?(?![a-z0-9])'
    return [regex]::IsMatch($Haystack, $pat)
}

# ================================================================ date slots

function New-DateSlot {
    param([datetime] $Start, [datetime] $End, [string] $Kind, [string] $Phrase)
    return [pscustomobject]@{
        Start  = $Start.Date
        End    = $End.Date
        Kind   = $Kind      # day | range
        Phrase = $Phrase
    }
}

function Resolve-DateSlot {
    <#
      Finds a date reference in the query. Returns a date slot or $null.
      $Today is injected so tests are stable.
    #>
    param(
        [Parameter(Mandatory)][string] $Norm,
        [Parameter(Mandatory)][datetime] $Today,
        [Parameter(Mandatory)] $Rules
    )

    # 1. "this week" / "next week" / "this month"
    if (Test-ContainsPhrase $Norm 'next week') {
        $mon = Get-WeekStart $Today
        $s = $mon.AddDays(7)
        return New-DateSlot $s $s.AddDays(6) 'range' 'next week'
    }
    if (Test-ContainsPhrase $Norm 'this week') {
        $s = Get-WeekStart $Today
        return New-DateSlot $s $s.AddDays(6) 'range' 'this week'
    }
    if (Test-ContainsPhrase $Norm 'next month') {
        $s = (Get-Date -Year $Today.Year -Month $Today.Month -Day 1).AddMonths(1)
        return New-DateSlot $s $s.AddMonths(1).AddDays(-1) 'range' 'next month'
    }
    if (Test-ContainsPhrase $Norm 'this month') {
        $s = Get-Date -Year $Today.Year -Month $Today.Month -Day 1
        return New-DateSlot $s.Date $s.AddMonths(1).AddDays(-1).Date 'range' 'this month'
    }

    # 2. relative day words - longest phrase first so "day after tomorrow"
    #    is not eaten by "tomorrow".
    $dw = D $Rules 'dateWords'
    if ($dw) {
        $words = @($dw.Keys) | Sort-Object { -$_.Length }
        foreach ($w in $words) {
            if (Test-ContainsPhrase $Norm $w) {
                $off = [int](D (D $dw $w) 'offsetDays')
                $d = $Today.AddDays($off)
                return New-DateSlot $d $d 'day' $w
            }
        }
    }

    # 3. explicit month + day  ("november 25", "25 november", "nov 25th")
    $months = D $Rules 'months'
    if ($months) {
        $names = @($months.Keys) | Sort-Object { -$_.Length }
        $alt = ($names | ForEach-Object { [regex]::Escape($_) }) -join '|'

        $m = [regex]::Match($Norm, "(?<![a-z])($alt)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*(\d{4}))?(?![0-9])")
        if (-not $m.Success) {
            $m = [regex]::Match($Norm, "(?<![0-9])(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?($alt)\.?(?:\s*,?\s*(\d{4}))?(?![0-9])")
            if ($m.Success) {
                $d = Resolve-MonthDay -Month ([int](D $months $m.Groups[2].Value)) `
                                      -Day ([int]$m.Groups[1].Value) `
                                      -Year $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }) `
                                      -Today $Today
                if ($d) { return New-DateSlot $d $d 'day' $m.Value.Trim() }
            }
        } else {
            $d = Resolve-MonthDay -Month ([int](D $months $m.Groups[1].Value)) `
                                  -Day ([int]$m.Groups[2].Value) `
                                  -Year $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }) `
                                  -Today $Today
            if ($d) { return New-DateSlot $d $d 'day' $m.Value.Trim() }
        }

        # bare month name = that whole month
        foreach ($n in $names) {
            if (Test-ContainsPhrase $Norm $n) {
                $mo = [int](D $months $n)
                $yr = $Today.Year
                if ($mo -lt $Today.Month - 6) { $yr++ }
                $s = Get-Date -Year $yr -Month $mo -Day 1
                return New-DateSlot $s.Date $s.AddMonths(1).AddDays(-1).Date 'range' $n
            }
        }
    }

    # 4. numeric  M/D, M/D/YY, M-D
    $m = [regex]::Match($Norm, '(?<![0-9])(\d{1,2})[/\-](\d{1,2})(?:[/\-](\d{2,4}))?(?![0-9])')
    if ($m.Success) {
        $yr = 0
        if ($m.Groups[3].Success) {
            $yr = [int]$m.Groups[3].Value
            if ($yr -lt 100) { $yr += 2000 }
        }
        $d = Resolve-MonthDay -Month ([int]$m.Groups[1].Value) -Day ([int]$m.Groups[2].Value) -Year $yr -Today $Today
        if ($d) { return New-DateSlot $d $d 'day' $m.Value }
    }

    # 4b. named holidays. The calendar wins where it names the day itself, so
    #     "thanksgiving" lands on Thanksgiving Recess rather than a bare date.
    $hol = D $Rules 'holidays'
    if ($hol) {
        $names = @($hol.Keys) | Sort-Object { -$_.Length }
        foreach ($n in $names) {
            if (-not (Test-ContainsPhrase $Norm $n)) { continue }
            $md = @(DA $hol $n)
            if ($md.Count -lt 2) { continue }
            $d = Resolve-MonthDay -Month ([int]$md[0]) -Day ([int]$md[1]) -Year 0 -Today $Today
            if ($d) { return New-DateSlot $d $d 'day' $n }
        }
    }

    # 5. weekday names.  "next friday" = first Friday strictly after today;
    #    bare / "this" friday = first Friday from today onward.
    $wd = D $Rules 'weekdays'
    if ($wd) {
        $names = @($wd.Keys) | Sort-Object { -$_.Length }
        foreach ($n in $names) {
            if (-not (Test-ContainsPhrase $Norm $n)) { continue }
            $target = [int](D $wd $n)
            $isNext = [regex]::IsMatch($Norm, '(?<![a-z])next\s+' + [regex]::Escape($n))
            $d = Get-NextWeekday -From $Today -Weekday $target -StrictlyAfter:$isNext
            return New-DateSlot $d $d 'day' $(if ($isNext) { "next $n" } else { $n })
        }
    }

    return $null
}

function Resolve-MonthDay {
    param([int] $Month, [int] $Day, [int] $Year, [datetime] $Today)
    if ($Month -lt 1 -or $Month -gt 12 -or $Day -lt 1 -or $Day -gt 31) { return $null }
    if ($Year -gt 0) {
        try { return (Get-Date -Year $Year -Month $Month -Day $Day).Date } catch { return $null }
    }
    # No year given: pick the reading nearest to today, preferring the future.
    # "when is march 10" asked in November means next March, not last March.
    $best = $null; $bestScore = [double]::MaxValue
    # Each element is parenthesised on purpose: in @($a.Year - 1, $a.Year, ...)
    # PowerShell binds the comma list as the right operand of the subtraction
    # and fails with "Object[] does not contain op_Subtraction".
    foreach ($y in @(($Today.Year - 1), ($Today.Year), ($Today.Year + 1))) {
        try { $cand = (Get-Date -Year $y -Month $Month -Day $Day).Date } catch { continue }
        $delta = ($cand - $Today.Date).TotalDays
        # future dates are cheap, past dates cost 3x
        $score = if ($delta -ge -3) { [math]::Abs($delta) } else { [math]::Abs($delta) * 3 }
        if ($score -lt $bestScore) { $bestScore = $score; $best = $cand }
    }
    return $best
}

function Get-WeekStart {
    # Monday-based week start.
    param([datetime] $D)
    $dow = [int]$D.DayOfWeek          # Sunday = 0
    $back = if ($dow -eq 0) { 6 } else { $dow - 1 }
    return $D.Date.AddDays(-$back)
}

function Get-NextWeekday {
    param([datetime] $From, [int] $Weekday, [switch] $StrictlyAfter)
    $start = if ($StrictlyAfter) { $From.Date.AddDays(1) } else { $From.Date }
    for ($i = 0; $i -lt 8; $i++) {
        $d = $start.AddDays($i)
        if ([int]$d.DayOfWeek -eq $Weekday) { return $d }
    }
    return $From.Date
}

# ================================================================ other slots

function Resolve-SchoolSlot {
    <# Longest alias wins, so "james madison primary" beats "madison". #>
    param([string] $Norm, [Parameter(Mandatory)] $Pack)
    $best = $null; $bestLen = 0
    foreach ($s in (DA $Pack 'schools')) {
        $cands = @([string](D $s 'name'), [string](D $s 'shortName')) + @(DA $s 'aliases')
        foreach ($c in $cands) {
            $c = ([string]$c).ToLowerInvariant().Trim()
            if ($c.Length -lt 2) { continue }
            if ((Test-ContainsPhrase $Norm $c) -and $c.Length -gt $bestLen) {
                $best = $s; $bestLen = $c.Length
            }
        }
    }
    return $best
}

function Resolve-LevelSlot {
    param([string] $Norm, [Parameter(Mandatory)] $Rules)
    $lw = D $Rules 'levelWords'
    if (-not $lw) { return $null }
    $hits = @()
    foreach ($lvl in @($lw.Keys)) {
        foreach ($w in (DA $lw $lvl)) {
            if (Test-ContainsPhrase $Norm ([string]$w)) { $hits += [pscustomobject]@{ Level = $lvl; Len = ([string]$w).Length } }
        }
    }
    if (-not $hits.Count) { return $null }
    return ($hits | Sort-Object -Property Len -Descending | Select-Object -First 1).Level
}

function Resolve-ScheduleKindSlot {
    param([string] $Norm, [Parameter(Mandatory)] $Rules)
    $sw = D $Rules 'scheduleWords'
    if (-not $sw) { return $null }
    $best = $null; $bestLen = 0
    foreach ($k in @($sw.Keys)) {
        foreach ($w in (DA $sw $k)) {
            $w = [string]$w
            if ((Test-ContainsPhrasePlural $Norm $w) -and $w.Length -gt $bestLen) { $best = $k; $bestLen = $w.Length }
        }
    }
    if ($best) { return $best }

    # Last resort: squash repeated letters, so "dissmisal" and "dismissal"
    # both become "dismisal". Doubled or dropped double letters are far and
    # away the commonest typo in these particular words. Only on words of six
    # letters or more, because on short words it destroys meaning: "off"
    # would squash to "of", and a day off is not a day of.
    $squashed = Get-SquashedDoubles $Norm
    foreach ($k in @($sw.Keys)) {
        foreach ($w in (DA $sw $k)) {
            $w = [string]$w
            if (($w -replace '[^a-z]', '').Length -lt 6) { continue }
            if ((Test-ContainsPhrasePlural $squashed (Get-SquashedDoubles $w)) -and $w.Length -gt $bestLen) {
                $best = $k; $bestLen = $w.Length
            }
        }
    }
    return $best
}

function Resolve-BreakSlot {
    param([string] $Norm, [Parameter(Mandatory)] $Rules)
    $br = D $Rules 'breaks'
    if (-not $br) { return $null }
    $best = $null; $bestLen = 0
    foreach ($k in @($br.Keys)) {
        foreach ($w in (DA $br $k)) {
            $w = [string]$w
            if ((Test-ContainsPhrase $Norm $w) -and $w.Length -gt $bestLen) { $best = $k; $bestLen = $w.Length }
        }
    }
    return $best
}

# ================================================================ intent scoring

function Test-NamesOwnTopic {
    <#
      Does this question name a topic of its own?

      "What about Tuesday?" does not - it is pure reference, and means
      whatever the last question meant. "What about transportation?" does, and
      must not be answered as if it were still about closing times.

      Anything left after removing filler, dates and school names counts.
    #>
    param(
        [Parameter(Mandatory)][string] $Norm,
        [Parameter(Mandatory)] $Pack,
        [Parameter(Mandatory)] $Rules
    )

    $stop = @('what','when','where','who','how','why','is','are','do','does','did','the','a','an',
              'my','our','i','we','you','to','for','of','in','on','at','it','its','be','can','could',
              'should','would','will','there','their','and','or','if','about','from','me','kid','kids',
              'child','children','son','daughter','school','schools','edison','district','please','tell',
              'but','ok','okay','so','then','also','what if')

    $dateish = @{}
    foreach ($k in @((D $Rules 'dateWords').Keys)) { $dateish[$k] = $true }
    foreach ($k in @((D $Rules 'weekdays').Keys))  { $dateish[$k] = $true }
    foreach ($k in @((D $Rules 'months').Keys))    { $dateish[$k] = $true }
    foreach ($k in @('week','month','day','today','tomorrow','next','this','last')) { $dateish[$k] = $true }

    $schoolWords = @{}
    foreach ($s in (DA $Pack 'schools')) {
        $terms = @([string](D $s 'name'), [string](D $s 'shortName')) + @(DA $s 'aliases')
        foreach ($t in $terms) {
            foreach ($w in (Get-Tokens ([string]$t).ToLowerInvariant())) { $schoolWords[$w] = $true }
        }
    }

    foreach ($w in (Get-Tokens $Norm)) {
        if ($stop -contains $w) { continue }
        if ($dateish.ContainsKey($w)) { continue }
        if ($schoolWords.ContainsKey($w)) { continue }
        if ($w -match '^\d+(st|nd|rd|th)?$') { continue }
        return $true
    }
    return $false
}

function Test-FollowUp {
    <#
      Is this question leaning on the one before it?

      Either it opens like a follow-up ("what about Tuesday", "and Friday?"),
      or it is too short to stand alone ("what time?", "Lincoln?").
    #>
    param([Parameter(Mandatory)][string] $Norm)

    if ($Norm -match '^(what|how) about\b')        { return $true }
    if ($Norm -match '^(and|but|ok|okay|so)\b')    { return $true }
    if ($Norm -match '^what if\b')                 { return $true }
    if ($Norm -match '^(then|also)\b')             { return $true }

    # Three words or fewer with no verb of its own: "what time?", "next week?"
    $words = @(Get-Tokens $Norm)
    if ($words.Count -le 3 -and $Norm -notmatch '\b(is|are|do|does|can|when|where|who|how)\b.*\b(school|open|closed)\b') {
        return $true
    }
    return $false
}

function Get-IntentScores {
    param([string] $Norm, [Parameter(Mandatory)] $Rules)
    $tokens = Get-Tokens $Norm
    $tokSet = @{}
    foreach ($t in $tokens) { $tokSet[$t] = $true }

    $results = New-Object System.Collections.ArrayList
    foreach ($intent in (DA $Rules 'intents')) {
        $score = 0.0
        $why = @()

        # requireAny: a hard gate. An intent whose patterns are necessarily
        # broad ("who do I contact about X") declares the vocabulary that must
        # be present, so it cannot win on sentence shape alone.
        $req = @(DA $intent 'requireAny')
        if ($req.Count) {
            $ok = $false
            foreach ($r in $req) {
                if (Test-ContainsPhrase $Norm ([string]$r)) { $ok = $true; break }
            }
            if (-not $ok) {
                [void]$results.Add([pscustomobject]@{
                    Id = [string](D $intent 'id'); Resolver = [string](D $intent 'resolver')
                    Priority = [double](D $intent 'priority'); Score = 0.0; Why = @('gated')
                })
                continue
            }
        }

        $kw = D $intent 'keywords'
        if ($kw) {
            foreach ($k in @($kw.Keys)) {
                $w = [double](D $kw $k)
                if ($k -match '\s') {
                    if (Test-ContainsPhrase $Norm $k) { $score += $w; $why += $k }
                } elseif ($tokSet.ContainsKey($k)) {
                    $score += $w; $why += $k
                }
            }
        }
        foreach ($p in (DA $intent 'patterns')) {
            try {
                if ([regex]::IsMatch($Norm, [string]$p)) { $score += 8.0; $why += 'pattern' }
            } catch { }
        }

        [void]$results.Add([pscustomobject]@{
            Id       = [string](D $intent 'id')
            Resolver = [string](D $intent 'resolver')
            Priority = [double](D $intent 'priority')
            Score    = $score
            Why      = $why
        })
    }
    return @($results | Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='Priority';Descending=$true})
}

# ================================================================ calendar lookup

function Get-CalendarOn {
    <#
      Calendar entries covering $Date that apply to $School (or district-wide).
      Entries are inclusive of endDate - the ingest step already converted
      iCal's exclusive DTEND.
    #>
    param(
        [Parameter(Mandatory)] $Pack,
        [Parameter(Mandatory)][datetime] $Date,
        $School
    )
    $sid = if ($School) { [string](D $School 'id') } else { '' }
    $out = New-Object System.Collections.ArrayList
    foreach ($e in (DA $Pack 'calendar')) {
        $s = Parse-PackDate ([string](D $e 'date'))
        if (-not $s) { continue }
        $en = Parse-PackDate ([string](D $e 'endDate'))
        if (-not $en) { $en = $s }
        if ($Date.Date -lt $s -or $Date.Date -gt $en) { continue }

        $scope = [string](D $e 'scope')
        if ($scope -eq 'district') { [void]$out.Add($e); continue }
        if (-not $sid) { continue }
        if ((DA $e 'schoolIds') -contains $sid) { [void]$out.Add($e) }
    }
    return $out.ToArray()
}

function Parse-PackDate {
    param([string] $S)
    if (-not $S) { return $null }
    [datetime] $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($S, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d.Date }
    return $null
}

function Get-AlertOn {
    <#
      The most recently posted live alert covering $Date, or $null.
      Closure outranks delayed opening outranks early dismissal, so a day with
      both a delay and then a closure reads as closed.

      A district alert applies to everyone. A school's own alert applies only
      to that school - Lincoln losing heat is not a district closing, and must
      not answer "is there school tomorrow" for a Woodbrook parent.
    #>
    param([Parameter(Mandatory)] $Pack, [Parameter(Mandatory)][datetime] $Date, $School)

    $sid = if ($School) { [string](D $School 'id') } else { '' }
    $rank = @{ 'closed' = 3; 'delayed_opening' = 2; 'early_dismissal' = 1 }
    $best = $null; $bestRank = 0; $bestPosted = [datetime]::MinValue

    foreach ($a in (DA $Pack 'alerts')) {
        $d = Parse-PackDate ([string](D $a 'date'))
        if (-not $d -or $d -ne $Date.Date) { continue }

        $asid = [string](D $a 'schoolId')
        if ($asid -and $asid -ne $sid) { continue }

        $k = [string](D $a 'kind')
        $r = if ($rank.ContainsKey($k)) { $rank[$k] } else { 0 }
        if ($r -eq 0) { continue }

        [datetime] $posted = [datetime]::MinValue
        [void][datetime]::TryParse([string](D $a 'postedAt'), [ref]$posted)

        if ($r -gt $bestRank -or ($r -eq $bestRank -and $posted -gt $bestPosted)) {
            $best = $a; $bestRank = $r; $bestPosted = $posted
        }
    }
    return $best
}

function Get-SchoolYearSpan {
    param([Parameter(Mandatory)] $Pack)
    $min = $null; $max = $null
    foreach ($e in (DA $Pack 'calendar')) {
        if ([string](D $e 'scope') -ne 'district') { continue }
        $s = Parse-PackDate ([string](D $e 'date'))
        if (-not $s) { continue }
        $en = Parse-PackDate ([string](D $e 'endDate')); if (-not $en) { $en = $s }
        if (-not $min -or $s -lt $min) { $min = $s }
        if (-not $max -or $en -gt $max) { $max = $en }
    }
    return [pscustomobject]@{ Start = $min; End = $max }
}

function Get-DayKind {
    <#
      What sort of school day is $Date?
        closed | early_dismissal | delayed_opening | regular | weekend | unknown
      Reason carries the calendar title so answers can say *why*.
    #>
    param([Parameter(Mandatory)] $Pack, [Parameter(Mandatory)][datetime] $Date, $School)

    if ([int]$Date.DayOfWeek -eq 0 -or [int]$Date.DayOfWeek -eq 6) {
        return [pscustomobject]@{ Kind = 'weekend'; Reason = ''; Entry = $null; Alert = $null }
    }

    # A live alert outranks the published calendar: a snow closing is exactly
    # the case where the calendar says "normal full day" and is wrong.
    $alert = Get-AlertOn -Pack $Pack -Date $Date -School $School
    if ($alert) {
        $k = [string](D $alert 'kind')
        $reason = [string](D $alert 'text')
        if ($reason.Length -gt 160) { $reason = $reason.Substring(0, 157) + '...' }
        $mapped = switch ($k) {
            'closed'          { 'closed' }
            'delayed_opening' { 'delayed_opening' }
            'early_dismissal' { 'early_dismissal' }
            default           { '' }
        }
        if ($mapped) {
            return [pscustomobject]@{
                Kind    = $mapped
                Reason  = $reason
                Entry   = $null
                Alert   = $alert
            }
        }
    }

    $entries = Get-CalendarOn -Pack $Pack -Date $Date -School $School
    # Closure beats a shortened day: if both are listed, there is no school.
    foreach ($e in $entries) {
        $k = [string](D $e 'kind')
        if ($k -in @('closed', 'break')) {
            return [pscustomobject]@{ Kind = 'closed'; Reason = [string](D $e 'title'); Entry = $e; Alert = $null }
        }
    }
    foreach ($e in $entries) {
        if ([string](D $e 'kind') -eq 'no_school_students') {
            return [pscustomobject]@{ Kind = 'closed'; Reason = [string](D $e 'title'); Entry = $e; Alert = $null }
        }
    }
    foreach ($e in $entries) {
        $k = [string](D $e 'kind')
        if ($k -in @('early_dismissal', 'single_session')) {
            return [pscustomobject]@{ Kind = 'early_dismissal'; Reason = [string](D $e 'title'); Entry = $e; Alert = $null }
        }
    }
    foreach ($e in $entries) {
        if ([string](D $e 'kind') -eq 'delayed_opening') {
            return [pscustomobject]@{ Kind = 'delayed_opening'; Reason = [string](D $e 'title'); Entry = $e; Alert = $null }
        }
    }

    $span = Get-SchoolYearSpan -Pack $Pack
    if ($span.Start -and $span.End) {
        # Summer / outside the published year: say so rather than guess "open".
        if ($Date -gt $span.End) {
            return [pscustomobject]@{ Kind = 'unknown'; Reason = 'after the published school year'; Entry = $null; Alert = $null }
        }
    }
    return [pscustomobject]@{ Kind = 'regular'; Reason = ''; Entry = $null; Alert = $null }
}

# ================================================================ bells

function Get-BellsForLevel {
    param([Parameter(Mandatory)] $Pack, [string] $Level)
    $out = @()
    foreach ($b in (DA $Pack 'bells')) {
        if ($Level -and [string](D $b 'level') -ne $Level) { continue }
        $out += $b
    }
    return $out
}

function Format-Time12 {
    param([string] $Hhmm)
    if (-not $Hhmm -or $Hhmm -notmatch '^(\d{1,2}):(\d{2})$') { return $Hhmm }
    $h = [int]$Matches[1]; $m = [int]$Matches[2]
    $ap = if ($h -ge 12) { 'PM' } else { 'AM' }
    $h12 = $h % 12; if ($h12 -eq 0) { $h12 = 12 }
    return ('{0}:{1:00} {2}' -f $h12, $m, $ap)
}

function Get-LevelLabel {
    param([string] $Level)
    switch ($Level) {
        'elementary' { 'Elementary schools (K-5)' }
        'middle'     { 'Middle schools' }
        'high'       { 'High schools' }
        'academy'    { 'Edison Success Academy' }
        'eelc'       { 'Edison Early Learning Center' }
        'fdr'        { 'FDR Preschool' }
        default      { $Level }
    }
}

# ================================================================ fact retrieval

function Get-FactMatches {
    <#
      Lightweight BM25-ish retrieval. Title and tags are boosted because the
      district's page bodies are often short and the page NAME carries the
      topic ("Attendance", "Transportation").
    #>
    param(
        [Parameter(Mandatory)] $Pack,
        [string[]] $Terms,
        $School,
        [string[]] $RequireTags = @(),
        [int] $Top = 3
    )
    $facts = @(DA $Pack 'facts')
    if (-not $facts.Count -or -not @($Terms).Count) { return @() }

    $sid = if ($School) { [string](D $School 'id') } else { '' }

    # document frequency
    $df = @{}
    $docs = @()
    foreach ($f in $facts) {
        $title = ([string](D $f 'title')).ToLowerInvariant()
        $body  = ([string](D $f 'text')).ToLowerInvariant()
        $tags  = (@(DA $f 'tags') -join ' ').ToLowerInvariant()
        $bag = @{}
        foreach ($t in (Get-Tokens "$title $body $tags")) { $bag[$t] = 1 + $(if ($bag.ContainsKey($t)) { $bag[$t] } else { 0 }) }
        foreach ($t in @($bag.Keys)) { $df[$t] = 1 + $(if ($df.ContainsKey($t)) { $df[$t] } else { 0 }) }
        $docs += [pscustomobject]@{ Fact = $f; Title = $title; Body = $body; Tags = $tags; Bag = $bag }
    }
    $N = $docs.Count

    $scored = New-Object System.Collections.ArrayList
    foreach ($d in $docs) {
        if (@($RequireTags).Count) {
            $hit = $false
            foreach ($rt in $RequireTags) { if ($d.Tags -match [regex]::Escape($rt)) { $hit = $true; break } }
            if (-not $hit) { continue }
        }

        $score = 0.0
        foreach ($t in $Terms) {
            $tf = if ($d.Bag.ContainsKey($t)) { [double]$d.Bag[$t] } else { 0.0 }
            if ($tf -le 0) { continue }
            $n = if ($df.ContainsKey($t)) { [double]$df[$t] } else { 1.0 }
            $idf = [math]::Log(1.0 + ($N - $n + 0.5) / ($n + 0.5))
            $score += $idf * ($tf / ($tf + 1.5))
            if (Test-ContainsPhrase $d.Title $t) { $score += $idf * 1.2 }
            if (Test-ContainsPhrase $d.Tags  $t) { $score += $idf * 1.0 }
        }
        if ($score -le 0) { continue }

        # A question about one school is answered from that school's page or
        # from a district-wide one - never from a different school's. Lincoln
        # has no attendance page, and a mere score penalty let JMI's page win,
        # handing a Lincoln parent JMI's attendance email.
        $fsid = [string](D $d.Fact 'schoolId')
        if ($sid) {
            if ($fsid -eq $sid)   { $score *= 2.2 }
            elseif ($fsid -eq '') { $score *= 1.0 }
            else                  { continue }
        } elseif ($fsid -ne '') {
            $score *= 0.7
        }

        # Staff pages (payroll, certification, tuition reimbursement) are in
        # the pack so the app covers everything the district publishes, but a
        # parent's question should not be answered from one unless they clearly
        # asked about it. The query terms decide: if they overlap the page's
        # own title the penalty lifts.
        if ([string](D $d.Fact 'audience') -eq 'staff') {
            $deliberate = $false
            foreach ($t in $Terms) {
                if (Test-ContainsPhrase $d.Title $t) { $deliberate = $true; break }
            }
            if (-not $deliberate) { $score *= 0.2 }
        }

        [void]$scored.Add([pscustomobject]@{ Fact = $d.Fact; Score = $score })
    }
    return @($scored | Sort-Object -Property Score -Descending | Select-Object -First $Top)
}

function Get-FactExcerpt {
    <#
      Pulls the sentences that actually mention the query terms, so the answer
      is a few relevant lines rather than a whole page.
    #>
    param([Parameter(Mandatory)] $Fact, [string[]] $Terms, [int] $MaxChars = 420)
    $text = [string](D $Fact 'text')
    if (-not $text) { return '' }

    $lines = @($text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    if (-not $lines.Count) { return '' }

    $scored = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i].ToLowerInvariant()
        $hits = 0
        foreach ($t in $Terms) { if (Test-ContainsPhrase $l $t) { $hits++ } }
        # Lines carrying a phone number or an action verb are worth keeping.
        if ($l -match '\d{3}[-.\s]\d{3}[-.\s]\d{4}') { $hits += 2 }
        if ($l -match '@[a-z0-9.\-]+\.[a-z]{2,}')    { $hits += 1 }
        $scored += [pscustomobject]@{ Index = $i; Hits = $hits; Line = $lines[$i] }
    }

    $keep = @($scored | Where-Object { $_.Hits -gt 0 } | Sort-Object -Property Hits -Descending | Select-Object -First 6)
    if (-not $keep.Count) { $keep = @($scored | Select-Object -First 4) }
    $ordered = @($keep | Sort-Object -Property Index)

    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $ordered) {
        if ($sb.Length -gt 0) { [void]$sb.Append("`n") }
        if ($sb.Length + $k.Line.Length -gt $MaxChars) { break }
        [void]$sb.Append($k.Line)
    }
    $r = $sb.ToString()
    if (-not $r) { $r = $lines[0] }
    return $r
}

# ================================================================ formatting

function Add-TerminalPeriod {
    # Alert text is quoted verbatim from the district and often already ends
    # in punctuation; don't produce "December 10..".
    param([string] $S)
    if (-not $S) { return '' }
    $t = $S.TrimEnd()
    if ($t -match '[.!?]$') { return $t }
    return "$t."
}

function Format-DateLong {
    param([datetime] $D)
    return $D.ToString('dddd, MMMM d, yyyy', [cultureinfo]::GetCultureInfo('en-US'))
}

function Format-DateShort {
    param([datetime] $D)
    return $D.ToString('ddd, MMM d', [cultureinfo]::GetCultureInfo('en-US'))
}

function Format-DateRange {
    param([datetime] $S, [datetime] $E)
    if ($S -eq $E) { return (Format-DateLong $S) }
    $ci = [cultureinfo]::GetCultureInfo('en-US')
    if ($S.Year -eq $E.Year -and $S.Month -eq $E.Month) {
        return ('{0} {1}-{2}, {3}' -f $S.ToString('MMMM', $ci), $S.Day, $E.Day, $S.Year)
    }
    if ($S.Year -eq $E.Year) {
        return ('{0} - {1}, {2}' -f $S.ToString('MMMM d', $ci), $E.ToString('MMMM d', $ci), $S.Year)
    }
    return ('{0} - {1}' -f $S.ToString('MMMM d, yyyy', $ci), $E.ToString('MMMM d, yyyy', $ci))
}

function New-Answer {
    param(
        [string]   $Text,
        [string]   $Intent,
        [string[]] $Sources   = @(),
        [double]   $Confidence = 0.8,
        [string]   $SchoolId  = '',
        [string]   $Kind      = ''
    )
    return [pscustomobject]@{
        answer     = $Text
        intent     = $Intent
        kind       = $Kind
        sources    = @($Sources | Where-Object { $_ } | Select-Object -Unique)
        confidence = $Confidence
        schoolId   = $SchoolId
    }
}

# ================================================================ resolvers

function Test-AsksAboutSomeOtherDay {
    <#
      Did the question name a particular day that we failed to work out?

      "Is there school on christmas eve" used to answer "yes, open on Monday
      November 23" - the words were not understood, the date quietly fell back
      to today, and the answer was confidently wrong about a day the district
      is closed. Saying "I'm not sure which day you mean" is far better.
    #>
    param([string] $Norm, $Rules)
    foreach ($h in (DA $Rules 'dayHints')) {
        if ($Norm -match [regex]::Escape([string]$h)) { return $true }
    }
    return $false
}

# Is the question "how many of them are there?" rather than "is it one
# today?" - and does it span the year rather than a day?
#
# "How many early dismissal days are in this school year" used to score
# highest on day_schedule (on the words "early" and "dismissal"), find no
# date, quietly fall back to today and answer "Saturday, November 21, 2026 is
# a Saturday - no school." Confidently wrong, and about the wrong question.
# Counting and enumerating are never about a single day.
$script:CountingRe   = '(?<![a-z0-9])(how many|how much|how often|number of|count of)(?![a-z0-9])'
$script:SpanRe       = '(?<![a-z0-9])(this (school )?year|the (school )?year|whole year|rest of the|all year|left|remaining)(?![a-z0-9])'
$script:EnumerateRe  = '(?<![a-z0-9])(list|every|all the|all of the)(?![a-z0-9])'

# Resolvers that answer about one day. Any of these reached by a counting
# question is a routing mistake.
$script:OneDayResolvers = @('school_status', 'day_schedule', 'bell_times', 'fact_search')
$script:MultiDaySubject = '(?<![a-z0-9])(days? off|holidays?|closings?|closures?|no school|half days?|early dismissals?|single sessions?|late starts?|delayed openings?|snow days?)(?![a-z0-9])'

function Test-AsksForCount {
    param([string] $Norm)
    return [regex]::IsMatch($Norm, $script:CountingRe)
}

function Test-AsksForAll {
    param([string] $Norm)
    return ([regex]::IsMatch($Norm, $script:CountingRe) -or
            [regex]::IsMatch($Norm, $script:EnumerateRe) -or
            [regex]::IsMatch($Norm, $script:SpanRe))
}

function Invoke-Resolver-SchoolStatus {
    param($Pack, $Rules, $Ctx)
    $slot = $Ctx.Date
    if (-not $slot) {
        if (Test-AsksAboutSomeOtherDay -Norm $Ctx.Norm -Rules $Rules) {
            return New-Answer -Text ("I'm not sure which day you mean. Try naming the date - " +
                                     '"is there school on December 24" - or ask about today or tomorrow.') `
                              -Intent 'school_status' -Kind 'unclear_date' -Confidence 0.2 `
                              -Sources @('https://www.edison.k12.nj.us/page/district-yearly-calendar/')
        }
        $slot = New-DateSlot $Ctx.Today $Ctx.Today 'day' 'today'
    }

    $school = $Ctx.School
    $label  = if ($school) { [string](D $school 'name') } else { 'Edison schools' }
    $isAre  = if ($school) { 'is' } else { 'are' }

    if ($slot.Kind -eq 'range') {
        $lines = @()
        $d = $slot.Start
        while ($d -le $slot.End) {
            $dk = Get-DayKind -Pack $Pack -Date $d -School $school
            if ($dk.Kind -ne 'weekend') {
                $desc = switch ($dk.Kind) {
                    'closed'          { "closed - $($dk.Reason)" }
                    'early_dismissal' { "early dismissal - $($dk.Reason)" }
                    'delayed_opening' { "delayed opening - $($dk.Reason)" }
                    'regular'         { 'normal full day' }
                    default           { 'no calendar entry' }
                }
                $lines += ('{0}: {1}' -f (Format-DateShort $d), $desc)
            }
            $d = $d.AddDays(1)
        }
        $txt = ("{0} for {1}:`n{2}" -f $label, $slot.Phrase, ($lines -join "`n"))
        return New-Answer -Text $txt -Intent 'school_status' -Kind 'range' `
                          -Sources @("https://www.edison.k12.nj.us/events/") -SchoolId $(if($school){[string](D $school 'id')}else{''})
    }

    $date = $slot.Start
    $dk = Get-DayKind -Pack $Pack -Date $date -School $school
    $src = @()
    if ($dk.Entry) { $src += [string](D $dk.Entry 'url') }
    if ($dk.Alert) { $src += 'https://www.edison.k12.nj.us/live-feed/' }
    $src += 'https://www.edison.k12.nj.us/page/district-yearly-calendar/'

    # An announcement is worth marking as one - a parent should be able to see
    # that this came from the district saying so today, not from the calendar.
    $alertNote = ''
    if ($dk.Alert) {
        [datetime] $ap = [datetime]::MinValue
        if ([datetime]::TryParse([string](D $dk.Alert 'postedAt'), [ref]$ap)) {
            $alertNote = "`nDistrict announcement posted {0}." -f $ap.ToString('ddd MMM d, h:mm tt', [cultureinfo]::GetCultureInfo('en-US'))
        } else {
            $alertNote = "`nFrom a district announcement."
        }
    }

    switch ($dk.Kind) {
        'weekend' {
            $t = '{0} is a {1}, so there is no school.' -f (Format-DateLong $date), $date.DayOfWeek
            return New-Answer -Text $t -Intent 'school_status' -Kind 'weekend' -Sources $src -Confidence 0.95
        }
        'closed' {
            $t = 'No - {0} {1} closed on {2}.' -f $label, $isAre, (Format-DateLong $date)
            if ($dk.Reason) { $t += ' Reason: ' + (Add-TerminalPeriod $dk.Reason) }
            $t += $alertNote
            return New-Answer -Text $t -Intent 'school_status' -Kind 'closed' -Sources $src -Confidence 0.95
        }
        'early_dismissal' {
            $t = 'Yes - {0} {1} open on {2}, but it is an early dismissal day ({3}).' -f `
                 $label, $isAre, (Format-DateLong $date), $dk.Reason
            $t += "`n" + (Get-BellLines -Pack $Pack -Ctx $Ctx -DayKind 'early_dismissal')
            return New-Answer -Text $t -Intent 'school_status' -Kind 'early_dismissal' -Sources $src -Confidence 0.9
        }
        'delayed_opening' {
            $t = 'Yes - {0} {1} open on {2}, on a delayed opening ({3}).' -f `
                 $label, $isAre, (Format-DateLong $date), $dk.Reason
            $t += "`n" + (Get-BellLines -Pack $Pack -Ctx $Ctx -DayKind 'delayed_opening')
            $t += $alertNote
            return New-Answer -Text $t -Intent 'school_status' -Kind 'delayed_opening' -Sources $src -Confidence 0.9
        }
        'regular' {
            $t = 'Yes - {0} {1} open on {2}, a normal full day.' -f $label, $isAre, (Format-DateLong $date)
            return New-Answer -Text $t -Intent 'school_status' -Kind 'open' -Sources $src -Confidence 0.85
        }
        default {
            $t = "I don't have a calendar entry for {0} ({1}). Check the district calendar to be sure." -f `
                 (Format-DateLong $date), $dk.Reason
            return New-Answer -Text $t -Intent 'school_status' -Kind 'unknown' -Sources $src -Confidence 0.4
        }
    }
}

function Get-BellLines {
    param($Pack, $Ctx, [string] $DayKind)
    $lvls = @()
    if ($Ctx.Level)      { $lvls = @($Ctx.Level) }
    elseif ($Ctx.School) { $lvls = @([string](D $Ctx.School 'level')) }
    else                 { $lvls = @('elementary', 'middle', 'high') }

    $field = switch ($DayKind) {
        'early_dismissal' { 'early' }
        'delayed_opening' { 'delayed' }
        default           { 'regular' }
    }

    $lines = @()
    foreach ($lvl in $lvls) {
        foreach ($b in (Get-BellsForLevel -Pack $Pack -Level $lvl)) {
            $sch = D $b $field
            if (-not $sch) { continue }
            $s = Format-Time12 ([string](D $sch 'start'))
            $e = Format-Time12 ([string](D $sch 'end'))
            if (-not $s) { continue }
            $lines += ('{0}: {1} to {2}' -f (Get-LevelLabel $lvl), $s, $e)
        }
    }
    return ($lines | Select-Object -Unique) -join "`n"
}

function Invoke-Resolver-DaySchedule {
    param($Pack, $Rules, $Ctx)
    $asked = $Ctx.ScheduleKind
    $slot  = $Ctx.Date
    if (-not $slot) { $slot = New-DateSlot $Ctx.Today $Ctx.Today 'day' 'today' }

    # "is there an early dismissal this week" - scan the range.
    if ($slot.Kind -eq 'range') {
        $hits = @()
        $d = $slot.Start
        while ($d -le $slot.End) {
            $dk = Get-DayKind -Pack $Pack -Date $d -School $Ctx.School
            if ($asked -and $dk.Kind -eq $asked) { $hits += [pscustomobject]@{ D = $d; R = $dk.Reason } }
            elseif (-not $asked -and $dk.Kind -in @('early_dismissal','delayed_opening','closed')) {
                $hits += [pscustomobject]@{ D = $d; R = "$($dk.Kind): $($dk.Reason)" }
            }
            $d = $d.AddDays(1)
        }
        if (-not $hits.Count) {
            $what = if ($asked) { ($asked -replace '_', ' ') } else { 'schedule change' }
            return New-Answer -Text ("No {0} is listed for {1}." -f $what, $slot.Phrase) `
                              -Intent 'day_schedule' -Kind 'none' -Confidence 0.85 `
                              -Sources @('https://www.edison.k12.nj.us/events/')
        }
        $lines = foreach ($h in $hits) { '{0} - {1}' -f (Format-DateShort $h.D), $h.R }
        return New-Answer -Text (("For {0}:`n" -f $slot.Phrase) + ($lines -join "`n")) `
                          -Intent 'day_schedule' -Kind 'range' -Confidence 0.9 `
                          -Sources @('https://www.edison.k12.nj.us/events/')
    }

    $date = $slot.Start
    $dk = Get-DayKind -Pack $Pack -Date $date -School $Ctx.School
    $src = @()
    if ($dk.Entry) { $src += [string](D $dk.Entry 'url') }
    $src += 'https://www.edison.k12.nj.us/page/school-hours/'

    if ($dk.Kind -eq 'weekend') {
        return New-Answer -Text ('{0} is a {1} - no school.' -f (Format-DateLong $date), $date.DayOfWeek) `
                          -Intent 'day_schedule' -Kind 'weekend' -Sources $src -Confidence 0.95
    }
    if ($dk.Kind -eq 'closed') {
        $t = 'Schools are closed on {0}{1}, so there is no dismissal.' -f (Format-DateLong $date), `
             $(if ($dk.Reason) { " ($($dk.Reason))" } else { '' })
        return New-Answer -Text $t -Intent 'day_schedule' -Kind 'closed' -Sources $src -Confidence 0.92
    }

    $effective = $asked
    if (-not $effective) { $effective = 'early_dismissal' }
    # The district runs "Single Session Day" and "Early Dismissal" on the same
    # shortened bell schedule, and Get-DayKind folds both into
    # early_dismissal. Fold the question the same way, or asking about a
    # single session day on a single session day answers "no". The calendar's
    # own title is echoed back, so the reply still names which one it is.
    if ($effective -eq 'single_session') { $effective = 'early_dismissal' }

    if ($dk.Kind -eq $effective) {
        $what = $effective -replace '_', ' '
        $t = 'Yes - {0} is {1} {2} ({3}).' -f (Format-DateLong $date), `
             $(if ($what -match '^[aeiou]') { 'an' } else { 'a' }), $what, $dk.Reason
        $bl = Get-BellLines -Pack $Pack -Ctx $Ctx -DayKind $effective
        if ($bl) { $t += "`n" + $bl }
        return New-Answer -Text $t -Intent 'day_schedule' -Kind $effective -Sources $src -Confidence 0.92
    }

    $what = $effective -replace '_', ' '
    $t = 'No - {0} is not {1} {2}.' -f (Format-DateLong $date), `
         $(if ($what -match '^[aeiou]') { 'an' } else { 'a' }), $what
    if ($dk.Kind -eq 'regular') {
        $t += ' It is a normal full day.'
        $bl = Get-BellLines -Pack $Pack -Ctx $Ctx -DayKind 'regular'
        if ($bl) { $t += "`n" + $bl }
    } elseif ($dk.Kind -in @('early_dismissal','delayed_opening')) {
        $t += (' It is listed as {0} ({1}).' -f ($dk.Kind -replace '_',' '), $dk.Reason)
    }
    return New-Answer -Text $t -Intent 'day_schedule' -Kind 'no' -Sources $src -Confidence 0.88
}

function Invoke-Resolver-BellTimes {
    param($Pack, $Rules, $Ctx)
    $slot = $Ctx.Date
    $date = if ($slot -and $slot.Kind -eq 'day') { $slot.Start } else { $null }

    $dayKind = 'regular'; $reason = ''

    # "what time does school start on a delayed opening" names the day type
    # instead of a date - answer for that schedule, not the regular one.
    if (-not $date -and $Ctx.ScheduleKind) {
        switch ($Ctx.ScheduleKind) {
            'delayed_opening' { $dayKind = 'delayed_opening' }
            'early_dismissal' { $dayKind = 'early_dismissal' }
            'single_session'  { $dayKind = 'early_dismissal' }
        }
    }

    if ($date) {
        $dk = Get-DayKind -Pack $Pack -Date $date -School $Ctx.School
        if ($dk.Kind -eq 'weekend') {
            return New-Answer -Text ('{0} is a {1} - no school.' -f (Format-DateLong $date), $date.DayOfWeek) `
                              -Intent 'bell_times' -Kind 'weekend' -Confidence 0.95 `
                              -Sources @('https://www.edison.k12.nj.us/page/school-hours/')
        }
        if ($dk.Kind -eq 'closed') {
            return New-Answer -Text ('Schools are closed on {0}{1}.' -f (Format-DateLong $date), `
                                     $(if ($dk.Reason) { " ($($dk.Reason))" } else { '' })) `
                              -Intent 'bell_times' -Kind 'closed' -Confidence 0.92 `
                              -Sources @('https://www.edison.k12.nj.us/page/district-yearly-calendar/')
        }
        if ($dk.Kind -in @('early_dismissal','delayed_opening')) { $dayKind = $dk.Kind; $reason = $dk.Reason }
    }

    $bl = Get-BellLines -Pack $Pack -Ctx $Ctx -DayKind $dayKind
    if (-not $bl) {
        return New-Answer -Text "I don't have published hours for that." -Intent 'bell_times' -Kind 'none' -Confidence 0.3
    }

    $head = if ($date) {
        if ($dayKind -eq 'regular') { 'Hours for {0}:' -f (Format-DateLong $date) }
        else { '{0} is {1} ({2}). Hours:' -f (Format-DateLong $date), ($dayKind -replace '_',' '), $reason }
    } elseif ($dayKind -eq 'delayed_opening') {
        'Delayed opening hours:'
    } elseif ($dayKind -eq 'early_dismissal') {
        'Early dismissal / single session hours:'
    } else {
        'Regular school hours:'
    }
    $t = "$head`n$bl"
    if ($dayKind -eq 'regular' -and -not $date) {
        $t += "`nDelayed opening starts 2 hours later; early dismissal/single session ends early."
    }
    return New-Answer -Text $t -Intent 'bell_times' -Kind $dayKind -Confidence 0.9 `
                      -Sources @('https://www.edison.k12.nj.us/page/school-hours/') `
                      -SchoolId $(if ($Ctx.School) { [string](D $Ctx.School 'id') } else { '' })
}

function Invoke-Resolver-NextOccurrence {
    param($Pack, $Rules, $Ctx)
    $kind = $Ctx.ScheduleKind
    $wanted = switch ($kind) {
        'early_dismissal' { @('early_dismissal','single_session') }
        'single_session'  { @('single_session') }
        'delayed_opening' { @('delayed_opening') }
        'closed'          { @('closed','break') }
        default           { @('closed','break','early_dismissal','single_session','delayed_opening') }
    }

    $today = $Ctx.Today.Date
    $sid = if ($Ctx.School) { [string](D $Ctx.School 'id') } else { '' }
    $best = $null; $bestDate = $null
    foreach ($e in (DA $Pack 'calendar')) {
        if (([string](D $e 'kind')) -notin $wanted) { continue }
        $scope = [string](D $e 'scope')
        if ($scope -ne 'district') {
            if (-not $sid) { continue }
            if ((DA $e 'schoolIds') -notcontains $sid) { continue }
        }
        $s = Parse-PackDate ([string](D $e 'date'))
        if (-not $s -or $s -lt $today) { continue }
        if (-not $bestDate -or $s -lt $bestDate) { $bestDate = $s; $best = $e }
    }

    if (-not $best) {
        $what = if ($kind) { ($kind -replace '_',' ') } else { 'schedule change' }
        return New-Answer -Text ("Nothing further is published for a {0} this school year." -f $what) `
                          -Intent 'next_occurrence' -Kind 'none' -Confidence 0.6 `
                          -Sources @('https://www.edison.k12.nj.us/events/')
    }

    $s  = Parse-PackDate ([string](D $best 'date'))
    $e2 = Parse-PackDate ([string](D $best 'endDate')); if (-not $e2) { $e2 = $s }
    $days = [int]($s - $today).TotalDays
    $when = switch ($days) { 0 { 'today' } 1 { 'tomorrow' } default { "in $days days" } }
    $t = 'The next one is {0} - {1} ({2}).' -f (Format-DateRange $s $e2), [string](D $best 'title'), $when
    $bk = [string](D $best 'kind')
    if ($bk -in @('early_dismissal','single_session','delayed_opening')) {
        $bl = Get-BellLines -Pack $Pack -Ctx $Ctx -DayKind $(if ($bk -eq 'delayed_opening') { 'delayed_opening' } else { 'early_dismissal' })
        if ($bl) { $t += "`n" + $bl }
    }
    return New-Answer -Text $t -Intent 'next_occurrence' -Kind $bk -Confidence 0.9 `
                      -Sources @([string](D $best 'url'))
}

function Invoke-Resolver-BreakDates {
    param($Pack, $Rules, $Ctx)
    $brk = $Ctx.Break
    if (-not $brk) {
        # "when does school end" style - fall through to last day of school.
        if ($Ctx.Norm -match 'last day') { $brk = 'summer break' }
        elseif ($Ctx.Norm -match 'first day|when does school start|when does school begin') { $brk = '__first__' }
    }

    $today = $Ctx.Today.Date
    $cands = @()

    if ($brk -eq '__first__') {
        foreach ($e in (DA $Pack 'calendar')) {
            if ([string](D $e 'kind') -eq 'first_day') { $cands += $e }
        }
    } else {
        $syn = @()
        if ($brk) { $syn = @(DA (D $Rules 'breaks') $brk) }
        if (-not @($syn).Count) { $syn = @('recess','break') }
        foreach ($e in (DA $Pack 'calendar')) {
            $title = ([string](D $e 'title')).ToLowerInvariant()
            foreach ($s in $syn) {
                if ($title -match [regex]::Escape(([string]$s).ToLowerInvariant())) { $cands += $e; break }
            }
        }
    }

    if (-not @($cands).Count) {
        return New-Answer -Text ("I couldn't find {0} on the published calendar." -f $(if ($brk) { $brk } else { 'that break' })) `
                          -Intent 'break_dates' -Kind 'none' -Confidence 0.4 `
                          -Sources @('https://www.edison.k12.nj.us/page/district-yearly-calendar/')
    }

    # A break closes the whole district, so the district's own entry is the
    # answer. Without this, a school's "FDR Thanksgiving Feast" or "Single
    # Session Day- Spring Break" outranks the actual recess and a parent is
    # told the wrong week.
    $districtOnly = @($cands | Where-Object { [string](D $_ 'scope') -eq 'district' })
    if (@($districtOnly).Count) { $cands = $districtOnly }

    # Prefer the next upcoming one; fall back to the most recent.
    $future = @($cands | Where-Object { $d = Parse-PackDate ([string](D $_ 'date')); $d -and $d -ge $today } |
                Sort-Object { Parse-PackDate ([string](D $_ 'date')) })
    $pick = if (@($future).Count) { $future[0] } else {
        @($cands | Sort-Object { Parse-PackDate ([string](D $_ 'date')) } -Descending)[0]
    }

    $s  = Parse-PackDate ([string](D $pick 'date'))
    $e2 = Parse-PackDate ([string](D $pick 'endDate')); if (-not $e2) { $e2 = $s }
    $nDays = [int]($e2 - $s).TotalDays + 1
    $label = [string](D $pick 'title')

    $t = '{0}: {1}' -f $label, (Format-DateRange $s $e2)
    if ($nDays -gt 1) { $t += " ({0} days)" -f $nDays }
    $t += '.'
    if ($s -ge $today) {
        $away = [int]($s - $today).TotalDays
        $t += $(switch ($away) { 0 { ' That starts today.' } 1 { ' That starts tomorrow.' } default { " That starts in $away days." } })
        $back = $e2.AddDays(1)
        while ([int]$back.DayOfWeek -eq 0 -or [int]$back.DayOfWeek -eq 6) { $back = $back.AddDays(1) }
        $t += ' Students return {0}.' -f (Format-DateShort $back)
    }
    return New-Answer -Text $t -Intent 'break_dates' -Kind 'break' -Confidence 0.92 `
                      -Sources @([string](D $pick 'url'), 'https://www.edison.k12.nj.us/page/district-yearly-calendar/')
}

function Invoke-Resolver-ListOccurrences {
    <#
      "List every early dismissal", "what are all the days off this year".

      Shows the whole school year rather than the next fortnight: a parent
      asking for the list is planning, not checking today.
    #>
    param($Pack, $Rules, $Ctx)

    $kind = $Ctx.ScheduleKind
    $wanted = switch ($kind) {
        'early_dismissal' { @('early_dismissal', 'single_session') }
        'single_session'  { @('single_session') }
        'delayed_opening' { @('delayed_opening') }
        'closed'          { @('closed', 'break') }
        default           { @('closed', 'break', 'early_dismissal', 'single_session', 'delayed_opening') }
    }
    $label = switch ($kind) {
        'early_dismissal' { 'Early dismissal and single session days' }
        'single_session'  { 'Single session days' }
        'delayed_opening' { 'Delayed openings' }
        'closed'          { 'Days schools are closed' }
        default           { 'Days that are not a normal full day' }
    }

    $sid = if ($Ctx.School) { [string](D $Ctx.School 'id') } else { '' }
    $today = $Ctx.Today.Date

    # Schools republish the district's own dates on their own calendars, so a
    # districtwide early dismissal shows up once for the district and again
    # for each of your children's schools. Collapse by date and title, and
    # let the district's copy win.
    $byKey = @{}
    foreach ($e in (DA $Pack 'calendar')) {
        if (([string](D $e 'kind')) -notin $wanted) { continue }
        $scope = [string](D $e 'scope')
        if ($scope -ne 'district') {
            if (-not $sid) { continue }
            if ((DA $e 'schoolIds') -notcontains $sid) { continue }
        }
        $s = Parse-PackDate ([string](D $e 'date'))
        if (-not $s) { continue }
        $en = Parse-PackDate ([string](D $e 'endDate')); if (-not $en) { $en = $s }
        $title = [string](D $e 'title')
        $key = ('{0}|{1}' -f $s.ToString('yyyy-MM-dd'), $title.ToLowerInvariant())
        if ($byKey.ContainsKey($key) -and $byKey[$key].Scope -eq 'district') { continue }
        $byKey[$key] = [pscustomobject]@{ S = $s; E = $en; T = $title; Scope = $scope }
    }
    $rows = New-Object System.Collections.ArrayList
    foreach ($v in $byKey.Values) { [void]$rows.Add($v) }

    if (-not $rows.Count) {
        return New-Answer -Text "Nothing like that is on the published calendar." `
                          -Intent 'list_occurrences' -Kind 'none' -Confidence 0.5 `
                          -Sources @('https://www.edison.k12.nj.us/page/district-yearly-calendar/')
    }

    $sorted = @($rows | Sort-Object S)
    $upcoming = @($sorted | Where-Object { $_.E -ge $today })
    $past = @($sorted | Where-Object { $_.E -lt $today })

    $lines = foreach ($r in $upcoming) {
        $d = if ($r.S -eq $r.E) { Format-DateShort $r.S } else { '{0}-{1}' -f (Format-DateShort $r.S), (Format-DateShort $r.E) }
        '{0} - {1}' -f $d, $r.T
    }

    if ($Ctx.Counting) {
        # They asked for a number, so lead with the number - for the whole
        # year, which is what "in this school year" means, not just what is
        # left. The list that follows is the part they can still plan around.
        $t = "{0}: {1} on this school year's calendar." -f $label, @($sorted).Count
        if (@($upcoming).Count) {
            $t += (" {0} still to come:" -f @($upcoming).Count) + "`n" + ($lines -join "`n")
        } else {
            $t += ' None left.'
        }
        if ($past.Count) { $t += "`n`n({0} already passed.)" -f $past.Count }
    } else {
        $t = "{0} still to come ({1}):" -f $label, @($upcoming).Count
        if (-not @($upcoming).Count) {
            $t = "{0}: none left this school year." -f $label
        } else {
            $t += "`n" + ($lines -join "`n")
        }
        if ($past.Count) { $t += "`n`n({0} already passed this school year.)" -f $past.Count }
    }

    return New-Answer -Text $t -Intent 'list_occurrences' -Kind 'list' -Confidence 0.92 `
                      -Sources @('https://www.edison.k12.nj.us/page/district-yearly-calendar/') `
                      -SchoolId $sid
}

function Invoke-Resolver-CalendarList {
    param($Pack, $Rules, $Ctx)
    $slot = $Ctx.Date
    if (-not $slot) {
        $s = $Ctx.Today.Date
        $slot = New-DateSlot $s $s.AddDays(13) 'range' 'the next two weeks'
    }
    $sid = if ($Ctx.School) { [string](D $Ctx.School 'id') } else { '' }

    $rows = New-Object System.Collections.ArrayList
    foreach ($e in (DA $Pack 'calendar')) {
        $s = Parse-PackDate ([string](D $e 'date'))
        if (-not $s) { continue }
        $en = Parse-PackDate ([string](D $e 'endDate')); if (-not $en) { $en = $s }
        if ($en -lt $slot.Start -or $s -gt $slot.End) { continue }
        $scope = [string](D $e 'scope')
        if ($scope -ne 'district') {
            if (-not $sid) { continue }
            if ((DA $e 'schoolIds') -notcontains $sid) { continue }
        }
        [void]$rows.Add([pscustomobject]@{ S = $s; E = $en; T = [string](D $e 'title'); K = [string](D $e 'kind') })
    }

    if (-not $rows.Count) {
        return New-Answer -Text ("Nothing is listed for {0}." -f $slot.Phrase) -Intent 'calendar_list' `
                          -Kind 'none' -Confidence 0.7 -Sources @('https://www.edison.k12.nj.us/events/')
    }
    $lines = foreach ($r in ($rows | Sort-Object S | Select-Object -First 12)) {
        $d = if ($r.S -eq $r.E) { Format-DateShort $r.S } else { '{0}-{1}' -f (Format-DateShort $r.S), (Format-DateShort $r.E) }
        '{0}: {1}' -f $d, $r.T
    }
    return New-Answer -Text (("{0}:`n" -f $slot.Phrase) + ($lines -join "`n")) -Intent 'calendar_list' `
                      -Kind 'list' -Confidence 0.85 -Sources @('https://www.edison.k12.nj.us/events/')
}

function Invoke-Resolver-AbsenceReport {
    param($Pack, $Rules, $Ctx)
    $school = $Ctx.School
    $terms = @('absent','absence','attendance','report','phone','call','secretary','email','sick')

    $hits = @(Get-FactMatches -Pack $Pack -Terms $terms -School $school -RequireTags @('absent','attendance','absence') -Top 2)

    if ($school) {
        # Absence procedure is per school, so only that school's own page will
        # do. A district page that merely mentions "call" or "email" - the
        # parent help desk, say - is not an answer to "who do I call about
        # Lincoln", and neither is another school's attendance page.
        $sid = [string](D $school 'id')
        $hits = @($hits | Where-Object { [string](D $_.Fact 'schoolId') -eq $sid })

        if (-not $hits.Count) {
            foreach ($c in (DA $Pack 'contacts')) {
                if ([string](D $c 'schoolId') -ne $sid) { continue }
                $ph = [string](D $c 'phone')
                if (-not $ph) { break }
                $t = "Call the {0} office to report an absence: {1}." -f [string](D $school 'name'), $ph
                $em = @(DA $c 'emails' | Select-Object -First 1)
                if ($em.Count) { $t += " You can also email {0}." -f $em[0] }
                $t += "`n{0} does not publish a separate attendance page, so this is the main office line." -f [string](D $school 'shortName')
                return New-Answer -Text $t -Intent 'absence_report' -Kind 'contact' -Confidence 0.7 `
                                  -Sources @([string](D $c 'url')) -SchoolId $sid
            }
        }
    } elseif (-not $hits.Count) {
        $hits = @(Get-FactMatches -Pack $Pack -Terms $terms -School $school -Top 2)
    }

    if (-not $hits.Count) {
        $phone = [string](D (D $Pack 'district') 'phone')
        if (-not $phone) { $phone = '732-452-4900' }
        $t = "Report an absence by calling your child's school office. The district's main number is $phone."
        return New-Answer -Text $t -Intent 'absence_report' -Kind 'fallback' -Confidence 0.35 `
                          -Sources @('https://www.edison.k12.nj.us/page/chain-of-communication/')
    }

    $f = $hits[0].Fact
    $excerpt = Get-FactExcerpt -Fact $f -Terms $terms
    $head = if ($school) {
        'To report an absence at {0}:' -f [string](D $school 'name')
    } else {
        'Absences are reported to your child''s own school office. From {0}:' -f [string](D $f 'title')
    }
    $t = "$head`n$excerpt"
    if (-not $school) {
        $t += "`n`nTell me which school and I'll give you that office's number."
    }
    return New-Answer -Text $t -Intent 'absence_report' -Kind 'fact' -Confidence 0.85 `
                      -Sources @([string](D $f 'url')) `
                      -SchoolId $(if ($school) { [string](D $school 'id') } else { '' })
}

function Invoke-Resolver-ContactInfo {
    param($Pack, $Rules, $Ctx)

    $school = $Ctx.School
    if ($school) {
        $sid = [string](D $school 'id')
        $rec = $null
        foreach ($c in (DA $Pack 'contacts')) {
            if ([string](D $c 'schoolId') -eq $sid) { $rec = $c; break }
        }

        $lines = @([string](D $school 'name'))
        if ($rec) {
            $ph = [string](D $rec 'phone')
            $fx = [string](D $rec 'fax')
            $ad = [string](D $rec 'address')
            if ($ad) { $lines += "Address: $ad" }
            if ($ph) { $lines += "Phone: $ph" }
            if ($fx) { $lines += "Fax: $fx" }

            # Attendance / office numbers beyond the main line are useful too.
            $extra = @(DA $rec 'phones' | Where-Object { $_ -and $_ -ne $ph } | Select-Object -First 2)
            if ($extra.Count) { $lines += 'Also: ' + ($extra -join ', ') }
            $em = @(DA $rec 'emails' | Select-Object -First 2)
            if ($em.Count) { $lines += 'Email: ' + ($em -join ', ') }
        }
        $lines += 'Website: ' + [string](D $school 'url')

        if ($lines.Count -gt 2) {
            return New-Answer -Text ($lines -join "`n") -Intent 'contact_info' -Kind 'school' `
                              -Confidence 0.88 -Sources @([string](D $school 'url')) -SchoolId $sid
        }
        # Only a name and a URL: say so against the district rather than
        # silently answering about a different office.
        $d0 = D $Pack 'district'
        $t0 = ($lines -join "`n")
        if ($d0) { $t0 += "`n`nDistrict main line: " + [string](D $d0 'phone') }
        return New-Answer -Text $t0 -Intent 'contact_info' -Kind 'school_partial' `
                          -Confidence 0.6 -Sources @([string](D $school 'url')) -SchoolId $sid
    }

    $dist = D $Pack 'district'
    if ($dist) {
        $lines = @([string](D $dist 'name'))
        $p = [string](D $dist 'phone');   if ($p) { $lines += "Phone: $p" }
        $a = [string](D $dist 'address'); if ($a) { $lines += "Address: $a" }
        $u = [string](D $dist 'url');     if ($u) { $lines += "Website: $u" }
        $t = ($lines -join "`n")
        if (-not $school) {
            $t += "`n`nFor a specific school, name it and I'll give you that office."
        }
        return New-Answer -Text $t -Intent 'contact_info' -Kind 'district' -Confidence 0.85 `
                          -Sources @([string](D $dist 'url'))
    }
    return Invoke-Resolver-FactSearch -Pack $Pack -Rules $Rules -Ctx $Ctx
}

function Invoke-Resolver-FactSearch {
    param($Pack, $Rules, $Ctx)

    # Drop question scaffolding so retrieval sees the topic words.
    $stop = @('what','when','where','who','how','why','is','are','do','does','did','the','a','an',
              'my','our','i','we','you','to','for','of','in','on','at','it','its','be','can','could',
              'should','would','will','there','their','and','or','if','about','from','me','kid','kids',
              'child','children','son','daughter','school','schools','edison','district','please','tell')
    $terms = @(Get-Tokens $Ctx.Norm | Where-Object { $_.Length -gt 2 -and $stop -notcontains $_ })
    if (-not $terms.Count) {
        $terms = @(Get-Tokens $Ctx.Norm | Where-Object { $_.Length -gt 2 })
    }
    if (-not $terms.Count) {
        return New-Answer -Text 'Ask me about school hours, closings, the calendar, absences, buses, meals or policies.' `
                          -Intent 'fact_search' -Kind 'empty' -Confidence 0.1
    }

    $hits = @(Get-FactMatches -Pack $Pack -Terms $terms -School $Ctx.School -Top 3)
    if (-not $hits.Count) {
        return New-Answer -Text ("I couldn't find that in the district's published pages. " +
                                 'Try rewording, or check https://www.edison.k12.nj.us') `
                          -Intent 'fact_search' -Kind 'none' -Confidence 0.15 `
                          -Sources @('https://www.edison.k12.nj.us')
    }

    $f = $hits[0].Fact
    $excerpt = Get-FactExcerpt -Fact $f -Terms $terms
    $t = ('{0}:' -f [string](D $f 'title')) + "`n" + $excerpt
    $srcs = @([string](D $f 'url'))
    if ($hits.Count -gt 1) {
        $also = @()
        foreach ($h in $hits[1..($hits.Count - 1)]) {
            $also += [string](D $h.Fact 'title')
            $srcs += [string](D $h.Fact 'url')
        }
        $t += "`n`nAlso relevant: " + ($also -join '; ') + '.'
    }
    # Retrieval confidence tracks the margin over the runner-up.
    $conf = [math]::Min(0.8, 0.35 + 0.1 * $hits[0].Score)
    return New-Answer -Text $t -Intent 'fact_search' -Kind 'fact' -Confidence $conf -Sources $srcs
}

# ================================================================ entry point

function Invoke-Query {
    <#
    .SYNOPSIS
        Answers one parent question against the knowledge pack.
    .PARAMETER Today
        Injected "now" so behaviour is reproducible in tests.
    .PARAMETER DefaultSchoolId
        The school saved in app settings; used when the question names none.
    #>
    param(
        [Parameter(Mandatory)] $Pack,
        [Parameter(Mandatory)] $Rules,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Query,
        [datetime] $Today = (Get-Date),
        [string] $DefaultSchoolId = '',
        # What the last question resolved to, so a follow-up can lean on it.
        # @{ Resolver; DateStart; DateEnd; DateIsRange; DatePhrase; SchoolId }
        $Previous = $null
    )

    $norm = Normalize-Query $Query
    if (-not $norm) {
        return New-Answer -Text 'Ask me anything about Edison schools - hours, closings, the calendar, absences.' `
                          -Intent 'empty' -Confidence 0.0
    }

    $school = Resolve-SchoolSlot -Norm $norm -Pack $Pack
    if (-not $school -and $DefaultSchoolId) {
        foreach ($s in (DA $Pack 'schools')) {
            if ([string](D $s 'id') -eq $DefaultSchoolId) { $school = $s; break }
        }
    }

    $ctx = [pscustomobject]@{
        Query        = $Query
        Norm         = $norm
        Today        = $Today.Date
        School       = $school
        Level        = (Resolve-LevelSlot        -Norm $norm -Rules $Rules)
        Date         = (Resolve-DateSlot         -Norm $norm -Today $Today.Date -Rules $Rules)
        ScheduleKind = (Resolve-ScheduleKindSlot -Norm $norm -Rules $Rules)
        Break        = (Resolve-BreakSlot        -Norm $norm -Rules $Rules)
        Counting     = (Test-AsksForCount        -Norm $norm)
    }

    # ---- follow-ups
    # "Is there school tomorrow?" then "what time?" is one conversation, not
    # two unrelated questions. A follow-up borrows whatever the last question
    # settled and the new one leaves out.
    $isFollowUp = Test-FollowUp -Norm $norm
    if ($Previous) {
        # "and the 27th?" means the 27th of the month we were just discussing.
        if (-not $ctx.Date -and $Previous.DateStart) {
            $m = [regex]::Match($norm, '(?:^|[^0-9])(\d{1,2})(?:st|nd|rd|th)(?![a-z0-9])')
            if ($m.Success) {
                $prev = [datetime]$Previous.DateStart
                $day = [int]$m.Groups[1].Value
                try {
                    $cand = (Get-Date -Year $prev.Year -Month $prev.Month -Day $day).Date
                    if ($cand.Day -eq $day) {
                        $ctx.Date = New-DateSlot $cand $cand 'day' $m.Groups[1].Value
                    }
                } catch { }
            }
        }
        if (-not $ctx.Date -and $isFollowUp -and $Previous.DateStart) {
            $ctx.Date = New-DateSlot ([datetime]$Previous.DateStart) ([datetime]$Previous.DateEnd) `
                        $(if ($Previous.DateIsRange) { 'range' } else { 'day' }) ([string]$Previous.DatePhrase)
        }
        if (-not $ctx.School -and [string]$Previous.SchoolId) {
            foreach ($s in (DA $Pack 'schools')) {
                if ([string](D $s 'id') -eq [string]$Previous.SchoolId) { $ctx.School = $s; break }
            }
        }
    }

    $scores = Get-IntentScores -Norm $norm -Rules $Rules
    $top = if (@($scores).Count) { $scores[0] } else { $null }

    # Slot evidence disambiguates intents that share vocabulary. A named break
    # ("spring break") is a break question even if "when" also scored
    # next_occurrence; "next" with a schedule kind is next_occurrence.
    $resolver = if ($top -and $top.Score -ge 3.0) { $top.Resolver } else { 'fact_search' }

    # "What about Tuesday?" carries no topic of its own - it means whatever the
    # last question meant. Borrow only when this question showed no intent at
    # all: "what time?" names its own topic and should give the times for the
    # day we were discussing, not repeat the whole answer.
    if ($isFollowUp -and $Previous -and [string]$Previous.Resolver -and
        -not (Test-NamesOwnTopic -Norm $norm -Pack $Pack -Rules $Rules)) {
        if (-not $top -or $top.Score -lt 3.0) { $resolver = [string]$Previous.Resolver }
    }

    # Asking what the rules ARE is a different question from asking what today
    # is. "What is the snow day policy" was being answered "yes, school is
    # open today" - it matched on "school" and "snow" and then had no date.
    if ($norm -match '\b(policy|policies|procedure|protocol|rules? (for|about|on)|how does .{0,20}work)\b' -and -not $ctx.Date) {
        $resolver = 'fact_search'
    }

    if ($ctx.Break -and $norm -notmatch '(?<![a-z])next(?![a-z])') { $resolver = 'break_dates' }
    elseif ($norm -match '(?<![a-z])(next|upcoming)(?![a-z])' -and $ctx.ScheduleKind -and -not $ctx.Date) {
        $resolver = 'next_occurrence'
    }

    # Counting or enumerating is the list question, however it is worded.
    # Without this, "how many early dismissal days are in this school year"
    # landed on day_schedule, found no date and answered about today. The word
    # list in the rules will always miss a phrasing; this does not, because it
    # keys off the shape of the question, not its vocabulary.
    if ($resolver -in $script:OneDayResolvers -and -not $ctx.Date) {
        if ((Test-AsksForAll -Norm $norm) -and
            ($ctx.ScheduleKind -or [regex]::IsMatch($norm, $script:MultiDaySubject))) {
            $resolver = 'list_occurrences'
        }
        elseif (Test-AsksForCount -Norm $norm) {
            # Counting something that is not on the calendar - "how many
            # schools are in the district", "how many students go to edison
            # high". Still not a question about today, and school_status was
            # answering it "Saturday, November 21 is a Saturday, so there is
            # no school."
            $resolver = 'fact_search'
        }
    }

    $ans = switch ($resolver) {
        'school_status'   { Invoke-Resolver-SchoolStatus  -Pack $Pack -Rules $Rules -Ctx $ctx }
        'day_schedule'    { Invoke-Resolver-DaySchedule   -Pack $Pack -Rules $Rules -Ctx $ctx }
        'bell_times'      { Invoke-Resolver-BellTimes     -Pack $Pack -Rules $Rules -Ctx $ctx }
        'next_occurrence' { Invoke-Resolver-NextOccurrence -Pack $Pack -Rules $Rules -Ctx $ctx }
        'break_dates'     { Invoke-Resolver-BreakDates    -Pack $Pack -Rules $Rules -Ctx $ctx }
        'calendar_list'   { Invoke-Resolver-CalendarList  -Pack $Pack -Rules $Rules -Ctx $ctx }
        'list_occurrences'{ Invoke-Resolver-ListOccurrences -Pack $Pack -Rules $Rules -Ctx $ctx }
        'absence_report'  { Invoke-Resolver-AbsenceReport -Pack $Pack -Rules $Rules -Ctx $ctx }
        'contact_info'    { Invoke-Resolver-ContactInfo   -Pack $Pack -Rules $Rules -Ctx $ctx }
        default           { Invoke-Resolver-FactSearch    -Pack $Pack -Rules $Rules -Ctx $ctx }
    }

    # Expose the slots for debugging and for the app's "why this answer" view.
    Add-Member -InputObject $ans -NotePropertyName debug -NotePropertyValue ([pscustomobject]@{
        resolver     = $resolver
        topIntent    = $(if ($top) { $top.Id } else { '' })
        topScore     = $(if ($top) { $top.Score } else { 0 })
        dateSlot     = $(if ($ctx.Date) { '{0}..{1} ({2})' -f $ctx.Date.Start.ToString('yyyy-MM-dd'), $ctx.Date.End.ToString('yyyy-MM-dd'), $ctx.Date.Phrase } else { '' })
        schoolSlot   = $(if ($ctx.School) { [string](D $ctx.School 'id') } else { '' })
        levelSlot    = [string]$ctx.Level
        scheduleSlot = [string]$ctx.ScheduleKind
        breakSlot    = [string]$ctx.Break
        followUp     = $isFollowUp
    }) -Force

    # Handed back to the caller to pass in as -Previous next time.
    Add-Member -InputObject $ans -NotePropertyName context -NotePropertyValue ([pscustomobject]@{
        Resolver    = $resolver
        DateStart   = $(if ($ctx.Date) { $ctx.Date.Start } else { $null })
        DateEnd     = $(if ($ctx.Date) { $ctx.Date.End } else { $null })
        DateIsRange = $(if ($ctx.Date) { $ctx.Date.Kind -eq 'range' } else { $false })
        DatePhrase  = $(if ($ctx.Date) { $ctx.Date.Phrase } else { '' })
        SchoolId    = $(if ($ctx.School) { [string](D $ctx.School 'id') } else { '' })
    }) -Force
    return $ans
}
