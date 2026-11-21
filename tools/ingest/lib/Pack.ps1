# Pack.ps1 - knowledge pack assembly helpers: school identity, bell schedules,
#            fact records, and JSON emission.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------- school identity

<#
  Level drives which bell-schedule row a school uses and how we talk about it.
  The district's own School Hours page groups schools as:
    elementary (K-5, incl. the two James Madison schools) | middle | high
  with Edison Success Academy, EELC and FDR Preschool on their own schedules.
#>
$script:SchoolMeta = @{
    'bfes'           = @{ Level = 'elementary'; Short = 'Ben Franklin';   Aliases = @('ben franklin','benjamin franklin','bf','bfes','franklin') }
    'jmes'           = @{ Level = 'elementary'; Short = 'James Monroe';   Aliases = @('james monroe','monroe','jmes','jm') }
    'jomes'          = @{ Level = 'elementary'; Short = 'John Marshall';  Aliases = @('john marshall','marshall','jomes') }
    'les'            = @{ Level = 'elementary'; Short = 'Lincoln';        Aliases = @('lincoln','les') }
    'lind'           = @{ Level = 'elementary'; Short = 'Lindeneau';      Aliases = @('lindeneau','lind') }
    'mlk'            = @{ Level = 'elementary'; Short = 'MLK';            Aliases = @('mlk','martin luther king','king elementary','martin luther king jr') }
    'mpes'           = @{ Level = 'elementary'; Short = 'Menlo Park';     Aliases = @('menlo park','menlo','mpes') }
    'wes'            = @{ Level = 'elementary'; Short = 'Washington';     Aliases = @('washington','wes') }
    'wbk'            = @{ Level = 'elementary'; Short = 'Woodbrook';      Aliases = @('woodbrook','wbk','wbr') }
    'jmis'           = @{ Level = 'elementary'; Short = 'JMI';            Aliases = @('james madison intermediate','jmi','jmis','madison intermediate') }
    'jmps'           = @{ Level = 'elementary'; Short = 'JMP';            Aliases = @('james madison primary','jmp','jmps','madison primary') }
    'hhms'           = @{ Level = 'middle';     Short = 'Herbert Hoover'; Aliases = @('herbert hoover','hoover','hhms') }
    'jams'           = @{ Level = 'middle';     Short = 'John Adams';     Aliases = @('john adams','adams','jams') }
    'tjms'           = @{ Level = 'middle';     Short = 'Thomas Jefferson'; Aliases = @('thomas jefferson','jefferson','tjms','tj') }
    'wwms'           = @{ Level = 'middle';     Short = 'Woodrow Wilson'; Aliases = @('woodrow wilson','wilson','wwms') }
    'ehs'            = @{ Level = 'high';       Short = 'Edison High';    Aliases = @('edison high','ehs','edison high school') }
    'jpshs'          = @{ Level = 'high';       Short = 'J.P. Stevens';   Aliases = @('john p stevens','jp stevens','j p stevens','stevens','jpshs','jps','jp') }
    'successacademy' = @{ Level = 'academy';    Short = 'Edison Success Academy'; Aliases = @('edison success academy','success academy','esa') }
    'eelc'           = @{ Level = 'eelc';       Short = 'EELC';           Aliases = @('edison early learning center','early learning center','eelc') }
    'fdrp'           = @{ Level = 'fdr';        Short = 'FDR Preschool';  Aliases = @('fdr preschool','fdr','roosevelt preschool') }
}

function Get-SchoolMetaFor {
    param([string] $Alias)
    if ($script:SchoolMeta.ContainsKey($Alias)) { return $script:SchoolMeta[$Alias] }
    return @{ Level = 'other'; Short = $Alias; Aliases = @($Alias) }
}

function New-SchoolRecord {
    param(
        [Parameter(Mandatory)] $Org,
        [string] $SectionId = ''
    )
    $alias = [string](Get-Prop $Org 'alias')
    $name  = [string](Get-Prop $Org 'name')
    $url   = [string](Get-Prop $Org 'org_url')
    $meta  = Get-SchoolMetaFor $alias

    # org_url arrives as "host/o/alias" - split into a browsable https URL.
    $host0 = $url
    if ($url -match '^([^/]+)') { $host0 = $Matches[1] }
    $browse = if ($url) { "https://$url" } else { '' }

    return [ordered]@{
        id        = $alias
        name      = $name
        shortName = [string]$meta.Short
        level     = [string]$meta.Level
        aliases   = @($meta.Aliases)
        orgId     = [int](Get-Prop $Org 'id')
        host      = $host0
        url       = $browse
        sectionId = $SectionId
    }
}

# ---------------------------------------------------------------- bell schedules

function Get-TimesFromCell {
    <#
      A School Hours cell holds a start and an end time, e.g. "8:55 AM 3:30 PM".
      Returns @(start, end) as 24h "HH:mm" strings, or $null.
    #>
    param([string] $Cell)
    if (-not $Cell) { return $null }
    $ms = [regex]::Matches($Cell, '(\d{1,2}):(\d{2})\s*([AaPp])\.?[Mm]\.?')
    if ($ms.Count -lt 1) { return $null }
    $times = @()
    foreach ($m in $ms) {
        $h = [int]$m.Groups[1].Value
        $n = [int]$m.Groups[2].Value
        $pm = $m.Groups[3].Value.ToLowerInvariant() -eq 'p'
        if ($pm -and $h -lt 12) { $h += 12 }
        if (-not $pm -and $h -eq 12) { $h = 0 }
        $times += ('{0:00}:{1:00}' -f $h, $n)
    }
    if ($times.Count -eq 1) { return @($times[0], '') }
    return @($times[0], $times[1])
}

function Get-ScheduleRowKind {
    param([string] $Label)
    $l = $Label.ToLowerInvariant()
    if ($l -match 'delayed')                       { return 'delayed' }
    if ($l -match 'single session|early dismissal'){ return 'early' }
    if ($l -match 'regular|full day')              { return 'regular' }
    return ''
}

function Get-BellSchedulesFromTable {
    <#
      Converts one School Hours table into bell records keyed by column.
      Returns @( @{ column = 'ELEMENTARY...'; regular=@{start;end}; delayed=...; early=... } )
    #>
    param([Parameter(Mandatory)] $Rows)

    if (@($Rows).Count -lt 2) { return @() }
    $header = @($Rows)[0]
    # Column 0 is the row label; columns 1..n are audiences.
    $cols = @()
    for ($c = 1; $c -lt @($header).Count; $c++) {
        $cols += [ordered]@{ column = [string]@($header)[$c]; regular = $null; delayed = $null; early = $null }
    }
    if (-not $cols.Count) { return @() }

    foreach ($row in (@($Rows) | Select-Object -Skip 1)) {
        $cells = @($row)
        if ($cells.Count -lt 2) { continue }
        $kind = Get-ScheduleRowKind $cells[0]
        if (-not $kind) { continue }
        for ($c = 1; $c -lt $cells.Count -and ($c - 1) -lt $cols.Count; $c++) {
            $t = Get-TimesFromCell $cells[$c]
            if ($t) { $cols[$c - 1][$kind] = [ordered]@{ start = $t[0]; end = $t[1] } }
        }
    }
    return $cols
}

function Get-LevelsForHoursColumn {
    <#
      Maps a School Hours column header onto the school levels it applies to.

      The COLUMN is checked before the heading, and they are never merged: the
      district's main table sits under the heading "Elementary Schools, Middle
      Schools, Edison High School and John P. Stevens High School", so a
      combined match would label every column 'elementary'. The heading is only
      consulted for the single-column tables (Edison Success Academy, EELC,
      FDR) whose column header is just "FULL DAY".
    #>
    param([string] $Column, [string] $Heading)
    foreach ($src in @([string]$Column, [string]$Heading)) {
        $c = $src.ToLowerInvariant()
        if ($c -match 'success academy')     { return @('academy') }
        if ($c -match 'eelc|early learning') { return @('eelc') }
        if ($c -match '\bfdr\b|preschool')   { return @('fdr') }
        if ($c -match 'elementary')          { return @('elementary') }
        if ($c -match 'middle')              { return @('middle') }
        if ($c -match 'high')                { return @('high') }
    }
    return @()
}

# ---------------------------------------------------------------- facts

function New-FactRecord {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $Text,
        [string]   $Url      = '',
        [string]   $SchoolId = '',
        [string[]] $Tags     = @()
    )
    # Collapse the whitespace the CMS leaves behind, and drop rule-off lines
    # ("______") the editors use as separators.
    $t = $Text -replace '_{4,}', ' '
    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, '(?m)^\s+|\s+$', '')
    $t = [regex]::Replace($t, '(\r?\n){2,}', "`n")
    return [ordered]@{
        id       = $Id
        title    = $Title
        text     = $t.Trim()
        url      = $Url
        schoolId = $SchoolId
        tags     = @($Tags)
    }
}

function Get-FooterContact {
    <#
      Every Apptegy school site renders a "Find Us" footer carrying the
      school's street address plus labelled phone and fax numbers, e.g.

        Lincoln Elementary School 53 Brookville Road Edison , New Jersey 08817
        732.650.5270 (Phone) 732.650.5275 (Fax)

      The footer is markup, not part of page.content, so it is read from the
      rendered homepage text rather than the CMS content tree. Returns
      @{ phone; fax; address } with empty strings for anything absent.
    #>
    param([Parameter(Mandatory)][string] $PageText)

    $res = [ordered]@{ phone = ''; fax = ''; address = '' }

    # Narrow to the footer when we can, so a phone number in page copy does
    # not get mistaken for the main office line.
    $scope = $PageText
    $i = $PageText.IndexOf('Find Us')
    if ($i -ge 0) { $scope = $PageText.Substring($i, [Math]::Min(600, $PageText.Length - $i)) }

    # Match an exact phone shape, not a loose run of digits and separators:
    # the address line ends in a 5-digit zip immediately before the number, and
    # a permissive class swallows "08817 732.650.5300" as one capture.
    $phonePat = '(\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4})'

    $m = [regex]::Match($scope, $phonePat + '\s*\(\s*Phone\s*\)', 'IgnoreCase')
    if ($m.Success) { $res.phone = Format-PhoneDigits $m.Groups[1].Value }

    $m = [regex]::Match($scope, $phonePat + '\s*\(\s*Fax\s*\)', 'IgnoreCase')
    if ($m.Success) { $res.fax = Format-PhoneDigits $m.Groups[1].Value }

    $m = [regex]::Match($scope, '(\d+\s+[A-Za-z0-9 .''\-]{3,45}?)\s*,?\s*(Edison)\s*,?\s*(?:New Jersey|NJ)\s*,?\s*(\d{5})')
    if ($m.Success) {
        $res.address = ('{0}, Edison, NJ {1}' -f ($m.Groups[1].Value -replace '\s+', ' ').Trim(), $m.Groups[3].Value)
    }
    return $res
}

function Format-PhoneDigits {
    param([string] $Raw)
    $d = ($Raw -replace '[^\d]', '')
    if ($d.Length -eq 11 -and $d.StartsWith('1')) { $d = $d.Substring(1) }
    if ($d.Length -ne 10) { return $Raw.Trim() }
    return ('{0}-{1}-{2}' -f $d.Substring(0,3), $d.Substring(3,3), $d.Substring(6,4))
}

function Get-PhonesFromText {
    param([string] $Text)
    $out = @()
    foreach ($m in [regex]::Matches($Text, '(?:\+?1[\s.\-]?)?\(?(\d{3})\)?[\s.\-]?(\d{3})[\s.\-](\d{4})(?:\s*(?:x|ext\.?|extension)\s*(\d{2,6}))?')) {
        $num = '{0}-{1}-{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value
        if ($m.Groups[4].Success) { $num += ' x' + $m.Groups[4].Value }
        if ($out -notcontains $num) { $out += $num }
    }
    return $out
}

function Get-EmailsFromText {
    param([string] $Text)
    $out = @()
    foreach ($m in [regex]::Matches($Text, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')) {
        if ($out -notcontains $m.Value) { $out += $m.Value }
    }
    return $out
}

# ---------------------------------------------------------------- JSON output

function Write-PackJson {
    <#
      Writes UTF-8 (no BOM) JSON. Swift's JSONDecoder is fine with a BOM but
      Set-Content -Encoding utf8 on PS 5.1 adds one, and a BOM breaks naive
      consumers, so we write bytes ourselves.
    #>
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)][string] $Path,
        [int] $Depth = 12
    )
    $json = $Object | ConvertTo-Json -Depth $Depth
    # PS 5.1 escapes non-ASCII as \uXXXX which is valid JSON - leave it.

    # An empty PowerShell array comes out as null, not [], and that cost us
    # the whole iPhone app: Swift expects a list of tags, found null, and
    # refused to load the information file at all. Every one of its checks
    # failed on the same line. Nothing caught it for months because the
    # PowerShell and browser engines both shrug at a null where a list
    # should be, and because nobody had ever compiled the Swift.
    #
    # Done on the text rather than on the objects, so it cannot be
    # sidestepped by some new field somewhere nobody thought to look.
    $json = [regex]::Replace($json, '("(?:tags|aliases|schoolIds|phones|emails|sectionIds|sectionNames|alerts|screenshots)"\s*:\s*)null', '$1[]')

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
    return (Get-Item $Path).Length
}
