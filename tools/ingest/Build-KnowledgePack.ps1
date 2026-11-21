<#
.SYNOPSIS
    Builds the Edison Township Public Schools knowledge pack used by the
    Edison Parent iOS app.

.DESCRIPTION
    Pulls from the district's own public sources:
      * window.clientWorkStateTemp  - the Apptegy CMS content tree embedded in
                                      every page (headings, tables, links). This
                                      is the district's structured content, not
                                      scraped HTML, so there is no nav/footer
                                      boilerplate to strip.
      * /api/v4/o/20425/cms/events  - the public events API (gives us the
                                      section -> school attribution).
      * .../events/generate_ical    - the iCal export the district's own
                                      "Download Calendar" button links to; one
                                      request per school section instead of 488
                                      pages of JSON.
      * <school>/sitemap.xml        - per-school page inventory.

    Output: dist/knowledge-pack.json

.PARAMETER OutFile
    Where to write the pack. Defaults to ../dist/knowledge-pack.json

.PARAMETER SkipSchoolPages
    Skip the per-school page crawl (faster; calendar + hours only).

.PARAMETER Offline
    Reuse the HTTP cache in .cache instead of hitting the network.
#>
[CmdletBinding()]
param(
    [string] $OutFile,
    [switch] $SkipSchoolPages,
    [switch] $Offline,
    [string] $CacheDir,

    # Which district to collect. The defaults are Edison, the district this
    # was written for; every other district on the same website software
    # works the same way, which is why these are arguments rather than
    # constants buried in the file.
    [string] $DistrictHost = 'www.edison.k12.nj.us',
    [int]    $OrgId        = 20425,
    [string] $DistrictName = 'Edison Township Public Schools',
    [string] $DistrictShortName = 'Edison',
    [string] $TimeZone     = 'America/New_York'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Proj = Split-Path -Parent $Here
. "$Here\lib\Web.ps1"
. "$Here\lib\Calendar.ps1"
. "$Here\lib\Pack.ps1"
. "$Proj\engine\Answer-Query.ps1"   # D / DA / Resolve-MonthDay, used by Alerts
. "$Proj\engine\Alerts.ps1"

if (-not $OutFile)  { $OutFile  = Join-Path (Split-Path -Parent $Here) 'dist\knowledge-pack.json' }
if (-not $CacheDir) { $CacheDir = Join-Path $Here '.cache' }
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

$ApiBase = "https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o/$OrgId/cms"

$script:Stats = [ordered]@{ fetched = 0; cached = 0; failed = 0 }

function Get-CacheKey {
    <#
      A filename for a downloaded page.

      Readable where it can be, hashed where it cannot. Truncating was a real
      bug: these feed addresses are identical except for the school id at the
      very end, so chopping them to a fixed length gave all twenty schools the
      same filename, and every school ended up with whichever was downloaded
      first - the district's calendar. Every school's events and its own
      closings were silently wrong.
    #>
    param([Parameter(Mandatory)][string] $Url)
    $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Url)) -replace '[/+=]', '_'
    if ($key.Length -le 120) { return $key }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url))).Replace('-', '')
    } finally { $sha.Dispose() }
    # Keep a readable head so the folder can still be eyeballed.
    return ($key.Substring(0, 60) + '_' + $hash.Substring(0, 32))
}

function Get-Cached {
    <# HTTP with an on-disk cache so reruns and -Offline are cheap. #>
    param([Parameter(Mandatory)][string] $Url)
    $key  = Get-CacheKey -Url $Url
    $file = Join-Path $CacheDir "$key.txt"

    if ((Test-Path $file) -and ($Offline -or ((Get-Item $file).LastWriteTime -gt (Get-Date).AddHours(-6)))) {
        $script:Stats.cached++
        return [IO.File]::ReadAllText($file)
    }
    if ($Offline) { $script:Stats.failed++; return $null }

    $body = Get-Web -Url $Url
    if ($null -eq $body) { $script:Stats.failed++; return $null }
    [IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding $false))
    $script:Stats.fetched++
    return $body
}

function Get-PageContentNodes {
    <# Fetch a CMS page and return its flattened content nodes + page name. #>
    param([Parameter(Mandatory)][string] $Url)
    $html = Get-Cached -Url $Url
    if (-not $html) { return $null }
    $cws = Get-ClientWorkState -Html $html
    if (-not $cws) { return $null }
    $page = Get-Prop $cws 'page'
    $struct = Get-Prop (Get-Prop $page 'content') 'structure'
    if (-not $struct) { return $null }
    return [pscustomobject]@{
        Name  = [string](Get-Prop $page 'name')
        Nodes = @(Get-ContentNodes -Node $struct)
        State = $cws
    }
}

function Get-NodesText {
    param($Nodes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in @($Nodes)) {
        if ($n.type -eq 'table') {
            foreach ($r in $n.rows) { [void]$sb.AppendLine(($r -join ' | ')) }
        } elseif ($n.ContainsKey('text') -and $n.text) {
            [void]$sb.AppendLine([string]$n.text)
        }
        if ($n.ContainsKey('url') -and $n.url) { [void]$sb.AppendLine([string]$n.url) }
    }
    return $sb.ToString()
}

Write-Host ''
Write-Host '=== Edison Parent - knowledge pack build ===' -ForegroundColor Cyan
Write-Host ("mode: {0}" -f $(if ($Offline) { 'OFFLINE (cache only)' } else { 'online' }))
Write-Host ''

# ============================================================ 1. schools

Write-Host '[1/6] District site model (schools, site map)...' -ForegroundColor Yellow
$homeHtml = Get-Cached -Url "https://$DistrictHost/"
if (-not $homeHtml) { throw "Could not load https://$DistrictHost/ - no cache and no network." }
$districtState = Get-ClientWorkState -Html $homeHtml
if (-not $districtState) { throw 'Could not parse the district CMS state (clientWorkStateTemp missing).' }

$orgs = @(Get-Prop $districtState 'organizations')
if (-not $orgs.Count) { throw 'No organizations found in district CMS state.' }

# ============================================================ 2. event sections

Write-Host '[2/6] Event sections...' -ForegroundColor Yellow
$sectionsByName = @{}
$evJson = Get-Cached -Url "$ApiBase/events"
if ($evJson) {
    try {
        $ev = ConvertFrom-JsonBig -Json $evJson
        foreach ($s in @(Get-Prop (Get-Prop $ev 'meta') 'sections')) {
            $nm = ([string](Get-Prop $s 'name')).Trim()
            if ($nm) { $sectionsByName[$nm.ToLowerInvariant()] = [string](Get-Prop $s 'id') }
        }
    } catch { Write-Warning "Events meta parse failed: $($_.Exception.Message)" }
}
Write-Host ("      {0} sections" -f $sectionsByName.Count)

# Section names are short codes ("HHMS", "James Monroe"); match them to schools
# through the alias table rather than guessing.
function Find-SectionIdForSchool {
    param($School)
    $cands = @($School.id, $School.shortName) + @($School.aliases)
    foreach ($c in $cands) {
        $k = ([string]$c).Trim().ToLowerInvariant()
        if ($k -and $sectionsByName.ContainsKey($k)) { return $sectionsByName[$k] }
    }
    return ''
}

$schools = New-Object System.Collections.ArrayList
foreach ($o in $orgs) {
    if (Get-Prop $o 'primary') { continue }       # the district itself
    $rec = New-SchoolRecord -Org $o
    $rec.sectionId = Find-SectionIdForSchool $rec
    [void]$schools.Add($rec)
}
Write-Host ("      {0} schools" -f $schools.Count)

$districtSectionId = ''
foreach ($k in @('district events', 'district')) {
    if ($sectionsByName.ContainsKey($k)) { $districtSectionId = $sectionsByName[$k]; break }
}

# ============================================================ 3. bell schedules

Write-Host '[3/6] School hours...' -ForegroundColor Yellow
$bells = New-Object System.Collections.ArrayList
$hoursUrl = "https://$DistrictHost/page/school-hours/"
$hoursPage = Get-PageContentNodes -Url $hoursUrl
if ($hoursPage) {
    $lastHeading = ''
    foreach ($n in $hoursPage.Nodes) {
        if ($n.type -eq 'heading') { $lastHeading = [string]$n.text; continue }
        if ($n.type -ne 'table')   { continue }
        foreach ($col in @(Get-BellSchedulesFromTable -Rows $n.rows)) {
            if ($null -eq $col) { continue }
            $levels = @(Get-LevelsForHoursColumn -Column $col.column -Heading $lastHeading)
            if (-not $levels.Count) { continue }
            foreach ($lvl in $levels) {
                [void]$bells.Add([ordered]@{
                    level   = $lvl
                    label   = ($col.column -replace '\s+', ' ').Trim()
                    regular = $col.regular
                    delayed = $col.delayed
                    early   = $col.early
                    url     = $hoursUrl
                })
            }
        }
    }
}
Write-Host ("      {0} bell schedules" -f $bells.Count)

# ============================================================ 4. calendar

Write-Host '[4/6] Calendar (iCal per section)...' -ForegroundColor Yellow
$calendar = New-Object System.Collections.ArrayList
$seenEvent = @{}

function Add-CalendarEvents {
    param([string] $SectionId, [string[]] $SchoolIds, [string] $Scope, [string] $SourceUrl)
    $url = "$ApiBase/events/generate_ical?section_ids=$SectionId"
    $ics = Get-Cached -Url $url
    if (-not $ics) { return 0 }
    $n = 0
    foreach ($e in (Get-IcsEvents -Ics $ics)) {
        $kind  = Get-EventKind -Summary $e.Summary -Description $e.Description
        # Only district-wide operational events and school closures matter for
        # "is school open" answers; individual club meetings would drown them.
        $title = Get-EventTitleClean $e.Summary
        $key   = '{0}|{1}|{2}' -f $e.Start.ToString('yyyyMMdd'), $title.ToLowerInvariant(), ($SchoolIds -join ',')
        if ($seenEvent.ContainsKey($key)) { continue }
        $seenEvent[$key] = $true
        [void]$calendar.Add([ordered]@{
            date      = $e.Start.ToString('yyyy-MM-dd')
            endDate   = $e.End.ToString('yyyy-MM-dd')
            title     = $title
            rawTitle  = $e.Summary
            kind      = $kind
            scope     = $Scope
            schoolIds = @($SchoolIds)
            allDay    = $e.AllDay
            startTime = $e.StartTime
            url       = $SourceUrl
        })
        $n++
    }
    return $n
}

if ($districtSectionId) {
    $c = Add-CalendarEvents -SectionId $districtSectionId -SchoolIds @() -Scope 'district' `
                            -SourceUrl "https://$DistrictHost/events/"
    Write-Host ("      district: {0} events" -f $c)
}

foreach ($s in $schools) {
    if (-not $s.sectionId) { continue }
    $c = Add-CalendarEvents -SectionId $s.sectionId -SchoolIds @($s.id) -Scope 'school' `
                            -SourceUrl ("{0}/events/" -f $s.url)
    Write-Verbose ("      {0}: {1} events" -f $s.id, $c)
}
Write-Host ("      {0} calendar entries total" -f $calendar.Count)

# ============================================================ 5. district facts

Write-Host '[5/6] District policy & procedure pages...' -ForegroundColor Yellow

# Priority pages - the questions parents ask every week. Tags are hand-set so
# retrieval has good handles even when the page's own wording is thin.
$DistrictPages = @(
    @{ Slug = 'school-closingdelayed-opening-information'; Tags = @('closing','closed','delayed opening','snow','weather','emergency','late start') }
    @{ Slug = 'school-hours';                             Tags = @('hours','times','dismissal','start time','bell') }
    @{ Slug = 'district-yearly-calendar';                 Tags = @('calendar','school year','breaks','holidays') }
    @{ Slug = 'chain-of-communication';                   Tags = @('contact','complaint','who do i call','communication') }
    @{ Slug = 'transportation';                           Tags = @('bus','transportation','route','bus stop') }
    @{ Slug = 'food-services';                            Tags = @('lunch','breakfast','meals','cafeteria','menu') }
    @{ Slug = 'health-services';                          Tags = @('nurse','health','medication','immunization') }
    @{ Slug = 'parentsquare';                             Tags = @('parentsquare','notifications','messages') }
    @{ Slug = 'parentsquare-faq';                         Tags = @('parentsquare','faq','notifications') }
    @{ Slug = 'parent-portal';                            Tags = @('portal','genesis','grades','login') }
    @{ Slug = 'office-of-enrollment-and-data';            Tags = @('enroll','registration','register','new student') }
    @{ Slug = 'enroll-resources';                         Tags = @('enroll','registration','documents') }
    @{ Slug = 'enrollment-placement';                     Tags = @('enroll','placement') }
    @{ Slug = 'harrassment-intimidation-bullying-information'; Tags = @('hib','bullying','harassment','intimidation') }
    @{ Slug = 'notices-plans-policies';                   Tags = @('policy','policies','board','regulation','notices') }
    @{ Slug = 'special-services';                         Tags = @('special education','iep','child study team') }
    @{ Slug = 'parent-helpdesk-support';                  Tags = @('help desk','tech support','device','chromebook') }
    @{ Slug = 'school-safety-and-security';               Tags = @('safety','security','drill','visitor') }
    @{ Slug = 'school-mealssummer-ebt-application';       Tags = @('free lunch','reduced','meals','ebt','application') }
    @{ Slug = 'anti-bullying-specialists';                Tags = @('hib','bullying','specialist') }
)

# Everything the district publishes gets pulled. Pages that are plainly for
# staff rather than parents are still collected, but marked, so that a parent's
# question is answered from a parent page unless they actually asked about
# payroll or certification.
$StaffOnlySlug = 'payroll|salary|tuition-reimburs|workers-comp|certification|substitute|employee|employment|hr-|human-resources|staff-development|professional-development|purchasing|vendor|bids|rfp|audit|budget|business-office|travel-resources|internal-|educator|teacher-ai|teacher-prompt|grab-go|breakout-room|morning-brew|tech-tutorial|google-suite|seesaw|non-tenured|hybrid-teaching|modern-classroom|for-fun'

$facts = New-Object System.Collections.ArrayList
$seenFactUrl = @{}

function Add-PageFact {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Id,
        [string]   $TitlePrefix = '',
        [string]   $SchoolId    = '',
        [string[]] $Tags        = @(),
        [int]      $MinChars    = 40,
        [string]   $Audience    = 'parent'
    )
    if ($seenFactUrl.ContainsKey($Url)) { return $false }
    $pg = Get-PageContentNodes -Url $Url
    if (-not $pg) { return $false }
    $text = Get-NodesText $pg.Nodes
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Trim().Length -lt $MinChars) { return $false }
    $seenFactUrl[$Url] = $true
    $title = if ($pg.Name) { $pg.Name } else { $Id }
    if ($TitlePrefix) { $title = "$TitlePrefix - $title" }
    $rec = New-FactRecord -Id $Id -Title $title -Text $text -Url $Url -SchoolId $SchoolId -Tags $Tags
    $rec.audience = $Audience
    [void]$facts.Add($rec)
    return $true
}

function Get-AudienceForSlug {
    param([string] $Slug, [string] $Title = '')
    $hay = ("$Slug $Title").ToLowerInvariant()
    if ($hay -match $StaffOnlySlug) { return 'staff' }
    return 'parent'
}

# --- priority pages
foreach ($p in $DistrictPages) {
    $ok = Add-PageFact -Url "https://$DistrictHost/page/$($p.Slug)/" -Id "district:$($p.Slug)" -Tags $p.Tags
    if (-not $ok) { Write-Verbose "      miss: $($p.Slug)" }
}
$priorityCount = $facts.Count
Write-Host ("      {0} priority pages" -f $priorityCount)

# --- sweep the rest of the district sitemap
$districtSitemap = Get-Cached -Url "https://$DistrictHost/sitemap.xml"
$swept = 0
$staffCount = 0
if ($districtSitemap) {
    $slugs = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($districtSitemap, '<loc>([^<]+)</loc>')) {
        $u = $m.Groups[1].Value
        if ($u -match '/page/([^/]+)/?$') { [void]$slugs.Add($Matches[1]) }
    }
    Write-Host ("      sweeping all {0} district pages..." -f $slugs.Count)
    $i = 0
    foreach ($sl in $slugs) {
        $i++
        if ($i % 25 -eq 0) { Write-Host ("        {0}/{1}" -f $i, $slugs.Count) -ForegroundColor DarkGray }
        $aud = Get-AudienceForSlug -Slug $sl
        if (Add-PageFact -Url "https://$DistrictHost/page/$sl/" -Id "district:$sl" -Audience $aud) {
            $swept++
            if ($aud -eq 'staff') { $staffCount++ }
        }
    }
}
Write-Host ("      {0} district pages ({1} priority + {2} swept; {3} staff-only)" -f `
    $facts.Count, $priorityCount, $swept, $staffCount)

# --- menu links to outside services
# Several of the things parents hunt for most - CommunityPass, MySchoolBucks,
# Genesis, ParentSquare - are not pages at all. They are entries in the
# district's menu pointing at someone else's website, so a page crawl finds
# nothing and "what is CommunityPass" comes back empty. Collect the menu
# itself so the app can at least say what each one is and where it lives.
$linkCount = 0
$hoursHtml = Get-Cached -Url "https://$DistrictHost/page/school-hours/"
if ($hoursHtml) {
    $mapState = Get-ClientWorkState -Html $hoursHtml
    $seenLink = @{}

    function Add-MenuLinks {
        param($Nodes, [string] $Trail)
        foreach ($n in @($Nodes)) {
            if ($null -eq $n) { continue }
            $name = [string](Get-Prop $n 'name')
            $type = [string](Get-Prop $n 'type')
            $url  = [string](Get-Prop $n 'url')
            $here = if ($Trail) { "$Trail > $name" } else { $name }

            if ($type -eq 'link' -and $url -and $name) {
                # Skip links back into the district's own site: those pages
                # are already collected in full.
                if ($url -notmatch '^/' -and $url -notmatch [regex]::Escape($DistrictHost)) {
                    $key = $name.ToLowerInvariant()
                    if (-not $seenLink.ContainsKey($key)) {
                        $seenLink[$key] = $true
                        $text = "{0} is linked from the Edison Township Public Schools website, under {1}.`n{2}" -f $name, $here, $url
                        $rec = New-FactRecord -Id ("link:" + ($key -replace '[^a-z0-9]+','-')) `
                               -Title $name -Text $text -Url $url `
                               -Tags @('link', 'service', $key)
                        $rec.audience = 'parent'
                        [void]$facts.Add($rec)
                        $script:linkCount++
                    }
                }
            }
            $kids = Get-Prop $n 'children'
            if ($kids -is [object[]]) { Add-MenuLinks -Nodes $kids -Trail $here }
        }
    }

    $siteMap = Get-Prop $mapState 'fullSiteMap'
    if ($siteMap) { Add-MenuLinks -Nodes $siteMap -Trail '' }
}
Write-Host ("      {0} links to outside services" -f $linkCount)

# ============================================================ 6. per-school pages

if (-not $SkipSchoolPages) {
    Write-Host '[6/6] Per-school pages (attendance, offices, health)...' -ForegroundColor Yellow

    # Slugs worth pulling from every school site. attendance is the big one:
    # "where do I report my kid absent" is the single most asked question.
    $SchoolSlugs = @(
        @{ Slug = 'attendance';      Tags = @('absent','absence','attendance','sick','report','call out') }
        @{ Slug = 'administration';  Tags = @('principal','administration','office','contact') }
        @{ Slug = 'offices';         Tags = @('office','contact','phone','secretary') }
        @{ Slug = 'health-services'; Tags = @('nurse','health','medication','sick') }
        @{ Slug = 'about-our-school';Tags = @('about','address','hours','contact') }
        @{ Slug = 'counseling';      Tags = @('counselor','counseling','guidance') }
    )

    $contacts = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($s in $schools) {
        $i++
        Write-Host ("      ({0}/{1}) {2}" -f $i, $schools.Count, $s.name)
        if (-not $s.url) { continue }

        # Use the school's own sitemap so we only request pages that exist.
        $available = @{}
        $sx = Get-Cached -Url ("https://{0}/sitemap.xml" -f $s.host)
        if ($sx) {
            foreach ($m in [regex]::Matches($sx, '<loc>([^<]+)</loc>')) {
                $u = $m.Groups[1].Value
                if ($u -match '/page/([^/]+)/?$') { $available[$Matches[1].ToLowerInvariant()] = $u }
            }
        }

        # Main office number + street address come from the site footer.
        $footer = [ordered]@{ phone = ''; fax = ''; address = '' }
        $homeTxt = Get-Cached -Url $s.url
        if ($homeTxt) { $footer = Get-FooterContact -PageText (Convert-HtmlToText $homeTxt) }

        $phones = @(); $emails = @()

        # The curated slugs first, so they carry their hand-set tags, then
        # every other page the school publishes.
        $tagFor = @{}
        foreach ($sl in $SchoolSlugs) { $tagFor[$sl.Slug] = $sl.Tags }

        $ordered = @()
        foreach ($sl in $SchoolSlugs) { if ($available.ContainsKey($sl.Slug)) { $ordered += $sl.Slug } }
        foreach ($k in $available.Keys) { if ($ordered -notcontains $k) { $ordered += $k } }
        if (-not $sx) { $ordered = @($SchoolSlugs | ForEach-Object { $_.Slug }) }

        $kept = 0
        foreach ($slug in $ordered) {
            $u = if ($available.ContainsKey($slug)) { $available[$slug] }
                 else { "https://{0}/page/{1}/" -f $s.host, $slug }

            $tags = if ($tagFor.ContainsKey($slug)) { $tagFor[$slug] } else { @() }
            $aud = Get-AudienceForSlug -Slug $slug

            $before = $facts.Count
            [void](Add-PageFact -Url $u -Id ("{0}:{1}" -f $s.id, $slug) `
                   -TitlePrefix $s.shortName -SchoolId $s.id -Tags $tags -Audience $aud)
            if ($facts.Count -gt $before) {
                $kept++
                if ($slug -in @('attendance','offices','administration','about-our-school','main-office','contact-us')) {
                    $txt = [string]$facts[$facts.Count - 1].text
                    $phones += Get-PhonesFromText $txt
                    $emails += Get-EmailsFromText $txt
                }
            }
        }
        Write-Host ("            {0} pages" -f $kept) -ForegroundColor DarkGray

        # The main office line goes first; attendance-page numbers follow it.
        $allPhones = @()
        if ($footer.phone) { $allPhones += [string]$footer.phone }
        $allPhones += @($phones)

        [void]$contacts.Add([ordered]@{
            schoolId = $s.id
            phone    = [string]$footer.phone
            fax      = [string]$footer.fax
            address  = [string]$footer.address
            phones   = @($allPhones | Where-Object { $_ } | Select-Object -Unique)
            emails   = @($emails   | Where-Object { $_ } | Select-Object -Unique)
            url      = $s.url
        })
    }
} else {
    Write-Host '[6/6] Per-school pages SKIPPED' -ForegroundColor DarkGray
    $contacts = New-Object System.Collections.ArrayList
}

# ============================================================ 7. live alerts

Write-Host '[7/7] Emergency closing alerts (live feed)...' -ForegroundColor Yellow

# The district posts weather closings and delayed openings to its public live
# feed the afternoon before. We snapshot what is current now; the app re-reads
# the same endpoint itself so it is not limited to what shipped in the pack.
$alertFeedUrl = "$ApiBase/live_feeds"
$ThrillshareBase = 'https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o'
$alerts = @()
$schoolFeeds = [ordered]@{}

try {
    $rulesPath = Join-Path $Here 'rules\intents.json'
    $rulesObj  = Import-Rules -Path $rulesPath

    # District feed: applies to everyone. Several pages, because every school
    # republishes these posts and the de-duplication can only recognise one as
    # a district announcement if it has actually seen it. Schools post less
    # often, so their 20-post window reaches further back than the district's.
    for ($p = 1; $p -le 5; $p++) {
        $u = if ($p -eq 1) { $alertFeedUrl } else { "$alertFeedUrl`?page_no=$p" }
        $feedJson = Get-Cached -Url $u
        if (-not $feedJson) { break }
        $alerts += @(Get-AlertsFromFeed -Feed (ConvertFrom-JsonBig -Json $feedJson) -Rules $rulesObj)
    }

    # Each school's own feed: a boiler failure or a building-specific early
    # dismissal only ever appears here. Every school also republishes the
    # district's posts, which Merge-Alerts drops as duplicates.
    foreach ($s in $schools) {
        $oid = [string]$s.orgId
        if (-not $oid) { continue }
        $url = "$ThrillshareBase/$oid/cms/live_feeds"
        $schoolFeeds[[string]$s.id] = $url
        $j = Get-Cached -Url $url
        if (-not $j) { continue }
        try {
            $alerts += @(Get-AlertsFromFeed -Feed (ConvertFrom-JsonBig -Json $j) -Rules $rulesObj -SchoolId ([string]$s.id))
        } catch {
            Write-Warning "$($s.id) feed parse failed: $($_.Exception.Message)"
        }
    }

    $alerts = @(Merge-Alerts -Alerts $alerts)

    # Keep only days still ahead of us. A closing from last February is pure
    # weight in the pack: the published calendar already answers questions
    # about the past, and the app only ever shows or notifies about what is
    # still coming. Yesterday is kept for time-zone slop.
    $cutoff = (Get-Date).Date.AddDays(-1)
    $alerts = @($alerts | Where-Object {
        $d = Parse-PackDate ([string]$_.date)
        $d -and $d -ge $cutoff
    })
} catch {
    Write-Warning "Alert feed parse failed: $($_.Exception.Message)"
}

$districtCount = @($alerts | Where-Object { -not (Get-AlertSchoolId $_) }).Count
Write-Host ("      {0} current alerts ({1} district, {2} school-specific)" -f `
    @($alerts).Count, $districtCount, (@($alerts).Count - $districtCount))
foreach ($a in @($alerts)) {
    $who = Get-AlertSchoolId $a
    if (-not $who) { $who = 'district' }
    Write-Host ("      {0}  {1,-16} {2}" -f $a.date, $a.kind, $who) -ForegroundColor DarkGray
}

# ============================================================ emit

# A repeating event - a weekly club, a monthly board meeting - comes out of the
# district's feed projected decades ahead. Left alone that is 9,000 entries
# reaching to the year 2099, nearly seven megabytes, for information nobody
# will ever ask about. Keep this school year and the start of the next.
$horizon = if ((Get-Date).Month -ge 8) {
    (Get-Date -Year ((Get-Date).Year + 1) -Month 8 -Day 31).Date
} else {
    (Get-Date -Year (Get-Date).Year -Month 8 -Day 31).Date
}
$horizonKey = $horizon.ToString('yyyy-MM-dd')
$before = @($calendar).Count
$calendar = @($calendar | Where-Object { [string]$_.date -le $horizonKey })
Write-Host ("      calendar trimmed to {0}: {1} kept, {2} dropped as far-future repeats" -f `
    $horizonKey, @($calendar).Count, ($before - @($calendar).Count)) -ForegroundColor DarkGray

$pack = [ordered]@{
    schemaVersion = 1
    generatedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    district      = [ordered]@{
        name      = $DistrictName
        shortName = $DistrictShortName
        url       = "https://$DistrictHost"
        orgId     = $OrgId
        phone     = '732-452-4900'
        address   = '312 Pierson Avenue, Edison, New Jersey 08837'
        timeZone  = $TimeZone
        # Where an answer sends you to check for yourself. Each district
        # arranges its own site, so these travel with its information rather
        # than being written into the engine.
        pages     = [ordered]@{
            calendar = "https://$DistrictHost/page/district-yearly-calendar/"
            events   = "https://$DistrictHost/events/"
            hours    = "https://$DistrictHost/page/school-hours/"
            feed     = "https://$DistrictHost/live-feed/"
        }
        # Groupings this district uses beyond elementary/middle/high.
        levelLabels = [ordered]@{
            elementary = 'Elementary schools (K-5)'
            academy    = 'Edison Success Academy'
            eelc       = 'Edison Early Learning Center'
            fdr        = 'FDR Preschool'
        }
    }
    schools  = @($schools)
    bells    = @($bells)
    calendar = @($calendar | Sort-Object { $_.date })
    facts    = @($facts)
    contacts = @($contacts)
    # Where the app polls for closings posted after this pack was built:
    # the district feed always, plus the saved school's own feed.
    alertFeedUrl     = $alertFeedUrl
    schoolFeedUrls   = $schoolFeeds
    alerts           = @($alerts)
}

$size = Write-PackJson -Object $pack -Path $OutFile
Write-Host ''
Write-Host ('=== pack written: {0} ({1:N0} bytes) ===' -f $OutFile, $size) -ForegroundColor Green
Write-Host ('    schools {0} | bells {1} | calendar {2} | facts {3} | contacts {4}' -f `
    @($schools).Count, @($bells).Count, @($calendar).Count, @($facts).Count, @($contacts).Count)
Write-Host ('    http: {0} fetched, {1} cached, {2} failed' -f $script:Stats.fetched, $script:Stats.cached, $script:Stats.failed)
Write-Host ''
