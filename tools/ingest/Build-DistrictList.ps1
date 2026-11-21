<#
.SYNOPSIS
    Turns the raw search results into the district list the app ships with.

.DESCRIPTION
    Discover-Districts.ps1 walks the organisation numbers and writes down
    which ones answer and what calendar sections they have. That file holds
    both districts and individual schools, and names neither.

    This picks out the districts and gives them names.

    Telling a district from one of its schools: a district publishes a
    calendar section per school, so it has several; a school publishes one or
    two. That is the whole of it, and it is why the threshold is a setting
    rather than a constant - small districts sit close to the line.

    Naming them: every district's uploaded images live under a folder named
    after the district, which is how the name is recovered. Where the
    district also lists a Facebook page, that is usually its own name written
    out properly, so it wins.

    Websites: mined from the links a district posts, when the same address
    keeps coming up. Often there is none, and that is fine - the app simply
    does not offer a "check for yourself" link for that district.

.PARAMETER MinSections
    How many calendar sections an organisation needs before it is treated as
    a district rather than a school. Default 3.
#>
[CmdletBinding()]
param(
    [string] $OrgsFile,
    [string] $OutFile,
    [int]    $MinSections = 3,
    [int]    $Concurrency = 6,
    [int]    $PauseMs = 200,
    [switch] $NamesOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Proj = Split-Path -Parent $Here
$CacheDir = Join-Path $Here '.cache'
if (-not $OrgsFile) { $OrgsFile = Join-Path $CacheDir 'orgs.jsonl' }
if (-not $OutFile)  { $OutFile  = Join-Path $Proj 'web\data\districts.js' }
$NamesFile = Join-Path $CacheDir 'district-names.jsonl'

if (-not (Test-Path $OrgsFile)) { throw "No search results at $OrgsFile - run Discover-Districts.ps1 first." }

$UserAgent = 'EdisonParentAgent/1.0 (building a parent information app; +https://github.com/AgastyaKora123/edison-schools)'
$ApiRoot   = 'https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o'

Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue

function Read-SharedLines {
    <#
      Reads a file the searches may still be appending to.

      The plain reader asks for exclusive access and fails outright while a
      search is running, which makes it impossible to check the list is
      coming out right until the whole hour is over. This asks only to read,
      and lets the writer carry on.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $out = New-Object System.Collections.ArrayList
    $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open,
                                          [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding $false))
        try { while ($null -ne ($l = $sr.ReadLine())) { [void]$out.Add($l) } }
        finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
    return $out.ToArray()
}

# ------------------------------------------------- 1. which ones are districts

Write-Host ''
Write-Host '=== Building the district list ===' -ForegroundColor Cyan

# Everything the first search found, whether or not it looks like a district.
$orgs = @{}
foreach ($line in Read-SharedLines $OrgsFile) {
    $t = $line.Trim()
    if (-not $t -or $t -notmatch '"sectionCount"') { continue }
    $o = $null
    try { $o = $ser.DeserializeObject($t) } catch { continue }
    $id = [int]$o['id']
    if ($orgs.ContainsKey($id)) { continue }
    $orgs[$id] = [pscustomobject]@{
        Id       = $id
        Count    = [int]$o['sectionCount']
        Sections = @($o['sectionNames'] | ForEach-Object { [string]$_ })
    }
}

$candidates = New-Object System.Collections.ArrayList
$OwnersFile = Join-Path $CacheDir 'org-owners.jsonl'

if (Test-Path $OwnersFile) {
    # The good way. Everything a district uploads lives in one folder named
    # after the district, and its schools upload into the same folder, so the
    # folder name groups an organisation with its district however many
    # calendars it keeps. Within a group the district is the one publishing
    # most calendars, and failing that the oldest number - the one created
    # when the district signed up.
    #
    # This matters because counting calendars alone found only 647 districts
    # out of several thousand: most districts never split their calendar up,
    # and judged on calendars they look exactly like a single school.
    $groups = @{}
    foreach ($line in Read-SharedLines $OwnersFile) {
        $t = $line.Trim()
        if (-not $t -or $t -notmatch '"slug"') { continue }
        $o = $null
        try { $o = $ser.DeserializeObject($t) } catch { continue }
        $slug = [string]$o['slug']
        if (-not $slug) { continue }
        $id = [int]$o['id']
        if (-not $orgs.ContainsKey($id)) { continue }
        if (-not $groups.ContainsKey($slug)) { $groups[$slug] = New-Object System.Collections.ArrayList }
        [void]$groups[$slug].Add([pscustomobject]@{
            Id = $id; Count = $orgs[$id].Count; Sections = $orgs[$id].Sections
            Fb = [string]$o['fb']
        })
    }

    foreach ($slug in $groups.Keys) {
        $members = @($groups[$slug] | Sort-Object -Property @{ Expression = 'Count'; Descending = $true },
                                                   @{ Expression = 'Id' })
        $head = $members[0]
        # A folder with one organisation in it is a standalone school, not a
        # district with schools under it.
        if ($members.Count -lt 2 -and $head.Count -lt $MinSections) { continue }
        [void]$candidates.Add([pscustomobject]@{
            Id       = $head.Id
            Sections = $head.Sections
            Slug     = $slug
            Fb       = $head.Fb
            Members  = $members.Count
        })
    }
    Write-Host ("  {0} districts found by grouping organisations into their own folders" -f $candidates.Count)
} else {
    # The fallback, for when the grouping pass has not been run: a district
    # publishes a calendar per school, a school publishes one.
    foreach ($id in $orgs.Keys) {
        if ($orgs[$id].Count -lt $MinSections) { continue }
        [void]$candidates.Add([pscustomobject]@{
            Id = $id; Sections = $orgs[$id].Sections; Slug = ''; Fb = ''; Members = 0
        })
    }
    Write-Host ("  {0} organisations look like districts ({1}+ calendars)" -f $candidates.Count, $MinSections)
    Write-Host '  (run Discover-DistrictOwners.ps1 to find the rest)' -ForegroundColor DarkGray
}

# ------------------------------------------------- 2. give them names

$known = @{}
if (Test-Path $NamesFile) {
    foreach ($line in Read-SharedLines $NamesFile) {
        if ($line -match '"id":(\d+)') { $known[[int]$Matches[1]] = $line.Trim() }
    }
}
# A candidate found by grouping already carries its folder name and its
# Facebook page, so there is nothing left to ask about it.
foreach ($c in $candidates) {
    if ($c.Slug -and -not $known.ContainsKey($c.Id)) {
        $esc = { param($s) ('"' + (([string]$s) -replace '\\', '\\' -replace '"', '\"') + '"') }
        $known[$c.Id] = '{"id":' + $c.Id + ',"slug":' + (& $esc $c.Slug) +
                        ',"fb":' + (& $esc $c.Fb) + ',"site":""}'
    }
}
$todo = @($candidates | Where-Object { -not $known.ContainsKey($_.Id) })
Write-Host ("  {0} already named, {1} to look up" -f $known.Count, $todo.Count)

if ($todo.Count) {
    $work = {
        param([int] $Id, [string] $Root, [string] $Ua)
        $out = [ordered]@{ id = $Id; slug = ''; fb = ''; site = '' }
        try {
            $r = Invoke-WebRequest -Uri "$Root/$Id/cms/live_feeds" -UseBasicParsing -TimeoutSec 25 `
                                   -Headers @{ 'User-Agent' = $Ua } -ErrorAction Stop
            $body = ''
            try {
                $st = $r.RawContentStream
                if ($st) { $st.Position = 0; $body = [Text.Encoding]::UTF8.GetString($st.ToArray()) }
            } catch { }
            if (-not $body) { $body = [string]$r.Content }

            $m = [regex]::Match($body, 'core-docs\.s3\.amazonaws\.com/([a-z0-9_]+)/')
            if ($m.Success) { $out.slug = $m.Groups[1].Value }

            $f = [regex]::Match($body, '"facebook_page":"([^"]{2,80})"')
            if ($f.Success) { $out.fb = $f.Groups[1].Value }

            # The district's own address is the one it links to most. Anything
            # that is plainly somewhere else is thrown out first.
            $hosts = @{}
            foreach ($u in [regex]::Matches($body, 'https?://([a-z0-9.-]+\.(?:k12\.[a-z]{2}\.us|org|net|edu|us|com))')) {
                $h = $u.Groups[1].Value.ToLowerInvariant()
                if ($h -match 'thrillshare|apptegy|amazonaws|google|gstatic|youtu|facebook|twitter|instagram|vimeo|wikipedia|tiktok|linkedin|zoom\.us|docs\.|forms\.|bit\.ly|tinyurl') { continue }
                if (-not $hosts.ContainsKey($h)) { $hosts[$h] = 0 }
                $hosts[$h]++
            }
            $best = $null; $bestN = 0
            foreach ($k in $hosts.Keys) { if ($hosts[$k] -gt $bestN) { $best = $k; $bestN = $hosts[$k] } }
            # Two mentions, so a single stray link to a newspaper is not
            # mistaken for the district's own website.
            if ($best -and $bestN -ge 2) { $out.site = $best }
        } catch { }
        return $out
    }

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Concurrency)
    $pool.Open()
    $w = New-Object System.IO.StreamWriter($NamesFile, $true, (New-Object System.Text.UTF8Encoding $false))
    $w.AutoFlush = $true
    $done = 0
    try {
        for ($i = 0; $i -lt $todo.Count; $i += $Concurrency) {
            $batch = $todo[$i..([Math]::Min($i + $Concurrency - 1, $todo.Count - 1))]
            $running = @()
            foreach ($c in $batch) {
                $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
                [void]$ps.AddScript($work).AddArgument($c.Id).AddArgument($ApiRoot).AddArgument($UserAgent)
                $running += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
            }
            foreach ($r in $running) {
                $res = $null
                try { $res = $r.PS.EndInvoke($r.Handle) } catch { }
                finally { $r.PS.Dispose() }
                $done++
                if (-not $res) { continue }
                $rec = @($res)[0]
                if (-not $rec) { continue }
                $esc = { param($s) ('"' + (([string]$s) -replace '\\', '\\' -replace '"', '\"') + '"') }
                $w.WriteLine('{"id":' + $rec.id +
                             ',"slug":' + (& $esc $rec.slug) +
                             ',"fb":'   + (& $esc $rec.fb) +
                             ',"site":' + (& $esc $rec.site) + '}')
            }
            if ($PauseMs -gt 0) { Start-Sleep -Milliseconds $PauseMs }
            if ((($i / $Concurrency) % 20) -eq 0 -or ($i + $Concurrency) -ge $todo.Count) {
                Write-Host ("  named {0}/{1}" -f $done, $todo.Count)
            }
        }
    } finally {
        $w.Dispose(); $pool.Close(); $pool.Dispose()
    }

    foreach ($line in Read-SharedLines $NamesFile) {
        if ($line -match '"id":(\d+)') { $known[[int]$Matches[1]] = $line.Trim() }
    }
}

if ($NamesOnly) { Write-Host '  (names only; list not written)'; return }

# ------------------------------------------------- 3. write the list

function Get-NameFromSlug {
    param([string] $Slug)
    if (-not $Slug) { return '' }
    # Every folder ends in the same two letters; they are not a state.
    $s = $Slug -replace '_ar$', ''
    # A trailing state code is shown as the state, not as part of the name:
    # "Lincoln County Schools, NC" rather than "Lincoln County Schools Nc".
    $parts = @($s -split '_' | Where-Object { $_ })
    if ($parts.Count -ge 2 -and ($UsStates -contains $parts[-1].ToLowerInvariant())) {
        $s = ($parts[0..($parts.Count - 2)]) -join '_'
    }
    $s = $s -replace '_', ' '
    $s = ($s -replace '\s+', ' ').Trim()
    if (-not $s) { return '' }
    $s = (Get-Culture).TextInfo.ToTitleCase($s)
    # Title case turns ISD into Isd. These are how districts are known in
    # half the country, and a parent searching "Clifton ISD" should find it.
    $s = [regex]::Replace($s, '\b(Isd|Usd|Cusd|Cisd|Rsd|Psd|Sd|Esd|Ccsd|Jhs|Hs|Ms|Es|Stem|Ymca)\b', {
        param($m) $m.Groups[1].Value.ToUpperInvariant()
    })
    return $s
}

function Get-StateFromHost {
    param([string] $SiteHost)
    $m = [regex]::Match([string]$SiteHost, '\.k12\.([a-z]{2})\.us$')
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return ''
}

$UsStates = @('al','ak','az','ar','ca','co','ct','de','fl','ga','hi','id','il','in','ia','ks','ky',
              'la','me','md','ma','mi','mn','ms','mo','mt','ne','nv','nh','nj','nm','ny','nc','nd',
              'oh','ok','or','pa','ri','sc','sd','tn','tx','ut','vt','va','wa','wv','wi','wy','dc')

function Get-StateFromSlug {
    <#
      Districts that share a name often say which state they are in, right in
      the folder their uploads live in: lincoln_county_schools_nc. Six
      districts called Lincoln something, with nothing to tell them apart, is
      a parent guessing; "Lincoln County Schools, NC" is a parent choosing.

      Only the last word counts, and only when it is a real state code, so
      "Washington School District" keeps its name.
    #>
    param([string] $Slug)
    $s = ([string]$Slug) -replace '_ar$', ''
    $parts = @($s -split '_' | Where-Object { $_ })
    if ($parts.Count -lt 2) { return '' }
    $last = $parts[-1].ToLowerInvariant()
    if ($UsStates -contains $last) { return $last.ToUpperInvariant() }
    return ''
}

# Sections that say nothing about how many schools a district has. A school's
# own calendar looks exactly like this and nothing else, which is what makes
# it a school rather than a district.
$GenericSection = '(?i)^\s*(district\s*(wide)?\s*events?|all schools|events?|calendar|main|athletics?|athletic events?|sports|activities|live feed)\s*$'

function Get-SchoolSectionCount {
    param($Sections)
    return @($Sections | Where-Object { $_ -and ($_ -notmatch $GenericSection) }).Count
}

function Test-LooksLikeOneSchool {
    <#
      "Arcola Elementary School" and "Appomattox County High" are schools that
      happen to keep three calendars. A district is not named after one
      building, so a name that is sends the row to the bin.
    #>
    param([string] $Name)
    if ($Name -match '(?i)\b(high|elementary|middle|junior|primary|intermediate|preparatory|prep)\s+school\b') { return $true }
    if ($Name -match '(?i)\b(high|elementary|middle|junior high)\s*$') { return $true }
    if ($Name -match '(?i)\b(hs|ms|es|jhs)\s*$') { return $true }
    return $false
}

function Get-TrustedSite {
    <#
      A district's own address, or nothing.

      Mining links out of what a district posts turns up Scholastic,
      PowerSchool, Smore, photo-day services and the local paper. Sending a
      parent to scholastic.com under the words "where this came from" is
      worse than sending them nowhere, so an address is only kept when it is
      plainly the district's: a k12 address, or one whose name contains a
      real word from the district's own name.
    #>
    param([string] $SiteHost, [string] $Name)
    if (-not $SiteHost) { return '' }
    $h = $SiteHost.ToLowerInvariant()

    # Services that host things FOR districts are never the district.
    if ($h -match 'powerschool|aeries|smore|photoday|scholastic|schoology|canvas|clever|classlink|remind|sportsyou|rankone|8to18|gofan|hudl|maxpreps|eventlink|boarddocs|revtrak|myschoolbucks|paypal|amazon|signupgenius|surveymonkey|office\.com|microsoft|apple\.com|foundation|alumni|booster|ptsa|\bpto\b') { return '' }

    if ($h -match '\.k12\.[a-z]{2}\.us$') { return $h }

    # Match against the registered name only, never a subdomain. Otherwise
    # "chillicotheschools.schoolspring.com" passes as Chillicothe's website
    # when it is a jobs board that let them name their own subdomain - and
    # the same trick covers every hosted service a district signs up to.
    $labels = @($h -split '\.')
    if ($labels.Count -lt 2) { return '' }
    $registrable = ($labels[-2..-1] -join '.')

    # A real word from the district's name, four letters or more, has to show
    # up in it. "Altus Public Schools" -> altusps.com keeps it; "Atomic ISD"
    # -> montville.net does not.
    $stop = @('school','schools','district','public','county','independent','unified','community','consolidated','township','city','area','regional','local','joint','union','central','academy','the','and','isd','usd')
    foreach ($w in @(($Name.ToLowerInvariant() -split '[^a-z0-9]+'))) {
        if ($w.Length -lt 4) { continue }
        if ($stop -contains $w) { continue }
        if ($registrable.Replace('-', '').Contains($w)) { return $h }
    }
    return ''
}

$rows = New-Object System.Collections.ArrayList
foreach ($c in $candidates) {
    if (-not $known.ContainsKey($c.Id)) { continue }
    $info = $null
    try { $info = $ser.DeserializeObject($known[$c.Id]) } catch { continue }

    $fb   = [string]$info['fb']
    $slug = [string]$info['slug']
    $site = [string]$info['site']

    # The folder the district's own uploads live in is its own name for
    # itself, and it is consistent. The Facebook page is a fallback, because
    # plenty of districts point it at a mascot page - "Absarokee Huskies",
    # "Atomic ISD" - which no parent would search for.
    $name = Get-NameFromSlug $slug
    if (-not $name -and $fb -and $fb -notmatch '^https?://' -and $fb.Length -ge 4) { $name = $fb }
    if (-not $name) { continue }
    if (Test-LooksLikeOneSchool $name) { continue }

    # The platform's own test and demo organisations answer like districts
    # and are not districts. "ACtesting" in a list a parent is searching is
    # the sort of thing that makes an app look unfinished.
    # "testing" and "sandbox" are matched inside a word as well, because the
    # one that prompted this was "ACtesting" - no space, no boundary. The
    # rest need word boundaries: dropping every district whose name begins
    # "Ac" would have taken Ackerman and Academy District 20 with it.
    if ($name -match '(?i)(testing|sandbox|apptegy|thrillshare)') { continue }
    if ($name -match '(?i)\b(test|demo|training|example|sample|dummy|qa|staging|template)\b') { continue }

    # How many schools to show beside the name, so a parent can tell two
    # similarly named districts apart. The organisations sharing this
    # district's upload folder are its schools, which is a truer count than
    # its calendars - plenty of districts keep one calendar for everything.
    $k = Get-SchoolSectionCount $c.Sections
    if ($c.Members -gt 1 -and ($c.Members - 1) -gt $k) { $k = $c.Members - 1 }
    if ($k -lt 1) { continue }

    $trusted = Get-TrustedSite -SiteHost $site -Name $name

    # The website names the state most reliably; the upload folder is the
    # fallback and covers many more districts.
    $state = Get-StateFromHost $trusted
    if (-not $state) { $state = Get-StateFromSlug $slug }

    [void]$rows.Add([pscustomobject]@{
        o = $c.Id
        n = $name
        s = $state
        u = $trusted
        k = $k
    })
}

# Two districts can share a name, and the same district can be listed twice
# if it has a second organisation number. Keep the one with more schools.
$byName = @{}
foreach ($r in ($rows | Sort-Object -Property @{ Expression = 'n' }, @{ Expression = 'k'; Descending = $true })) {
    $key = ($r.n + '|' + $r.s).ToLowerInvariant()
    if ($byName.ContainsKey($key)) { continue }
    $byName[$key] = $r
}
$final = @($byName.Values | Sort-Object -Property n)

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// Generated by ingest/Build-DistrictList.ps1 - do not edit.')
[void]$sb.AppendLine('// o = organisation number, n = name, s = state, u = website, k = schools')
[void]$sb.AppendLine('window.DISTRICTS = [')
$i = 0
foreach ($r in $final) {
    $i++
    $esc = { param($s) (([string]$s) -replace '\\', '\\' -replace '"', '\"') }
    $line = '{{"o":{0},"n":"{1}","s":"{2}","u":"{3}","k":{4}}}' -f `
            $r.o, (& $esc $r.n), (& $esc $r.s), (& $esc $r.u), $r.k
    if ($i -lt $final.Count) { $line += ',' }
    [void]$sb.AppendLine($line)
}
[void]$sb.AppendLine('];')

[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))

Write-Host ''
Write-Host ('  {0} districts written, {1:N1} KB' -f $final.Count, ((Get-Item $OutFile).Length / 1KB)) -ForegroundColor Green
Write-Host ('  {0} have a website, {1} have a state' -f `
            @($final | Where-Object { $_.u }).Count, @($final | Where-Object { $_.s }).Count) -ForegroundColor DarkGray
Write-Host ("  {0}" -f $OutFile) -ForegroundColor Green
Write-Host ''
