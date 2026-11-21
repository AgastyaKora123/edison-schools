# Web.ps1 - HTTP fetching + Apptegy/Thrillshare content extraction.
# Windows PowerShell 5.1 compatible. No external dependencies.

Set-StrictMode -Version Latest

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:UserAgent = 'EdisonParentAgent/1.0 (district information cache; contact webmaster@edison.k12.nj.us)'

# ---------------------------------------------------------------- HTTP

function Get-Web {
    <#
      Fetches a URL as text with retry + polite delay. Returns $null on failure.
    #>
    param(
        [Parameter(Mandatory)][string] $Url,
        [int] $Retries = 3,
        [int] $TimeoutSec = 45,
        [int] $DelayMs = 350
    )
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UserAgent $script:UserAgent `
                 -UseBasicParsing -TimeoutSec $TimeoutSec
            Start-Sleep -Milliseconds $DelayMs
            return [string]$r.Content
        } catch {
            $msg = $_.Exception.Message
            # 404 and other hard client errors: no point retrying.
            if ($msg -match '\(4\d\d\)' -and $msg -notmatch '\(429\)') {
                Write-Verbose "GET $Url -> $msg (not retrying)"
                return $null
            }
            if ($i -eq $Retries) {
                Write-Warning "GET $Url failed after $Retries tries: $msg"
                return $null
            }
            Start-Sleep -Milliseconds (600 * $i)
        }
    }
    return $null
}

# ---------------------------------------------------------------- JS string literal

function ConvertFrom-JsStringLiteral {
    <#
      Given HTML and the index just past `JSON.parse(`, reads the following
      double-quoted JS string literal and returns its decoded contents.

      A JS double-quoted literal is also a valid JSON string, so we locate the
      terminating unescaped quote and let the JSON parser do the unescaping.
    #>
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int]    $OpenQuoteIndex
    )
    if ($Text[$OpenQuoteIndex] -ne '"') { return $null }
    $i = $OpenQuoteIndex + 1
    $len = $Text.Length
    while ($i -lt $len) {
        $c = $Text[$i]
        if ($c -eq '\') { $i += 2; continue }   # skip escape pair
        if ($c -eq '"') {
            $literal = $Text.Substring($OpenQuoteIndex, $i - $OpenQuoteIndex + 1)
            try   { return (ConvertFrom-JsonBig -Json $literal -AsString) }
            catch { Write-Warning "Could not decode JS string literal: $($_.Exception.Message)"; return $null }
        }
        $i++
    }
    return $null
}

function ConvertFrom-JsonBig {
    <#
      JSON parse that tolerates large documents. PowerShell 5.1's
      ConvertFrom-Json chokes on deep/large payloads, so we use
      JavaScriptSerializer with a raised limit and convert to PSObjects.

      -AsString: the JSON document is a bare string; return it unescaped.
    #>
    param(
        [Parameter(Mandatory)][string] $Json,
        [switch] $AsString
    )
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 2000
    $obj = $ser.DeserializeObject($Json)
    if ($AsString) { return [string]$obj }
    return (ConvertTo-PsObjectTree $obj)
}

function ConvertTo-PsObjectTree {
    # JavaScriptSerializer hands back Dictionary/Object[] - normalise to
    # PSCustomObject/array so downstream code can use dotted access.
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $Node.Keys) {
            $key = [string]$k
            # The CMS emits the occasional "" key (empty table cells, blank
            # properties). [pscustomobject] rejects an empty member name, so
            # such keys are dropped - nothing downstream addresses them.
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $h[$key] = ConvertTo-PsObjectTree $Node[$k]
        }
        return [pscustomobject]$h
    }
    if ($Node -is [object[]] -or ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string])) {
        return @(foreach ($x in $Node) { ConvertTo-PsObjectTree $x })
    }
    return $Node
}

function Get-ClientWorkState {
    <#
      Extracts the Apptegy page model from `window.<name> = JSON.parse("...")`.
      This is the CMS's own structured content tree - headings, tables, links -
      which is far more reliable than scraping rendered HTML (no nav boilerplate).

      `clientWorkStateTemp` is the full model (page.content, organizations,
      fullSiteMap, customSections); `clientWorkState` is a trimmed copy. We
      prefer the full one and fall back.
    #>
    param(
        [Parameter(Mandatory)][string] $Html,
        [string[]] $Names = @('clientWorkStateTemp', 'clientWorkState')
    )
    foreach ($name in $Names) {
        $m = [regex]::Match($Html, ('window\.' + [regex]::Escape($name) + '\s*=\s*JSON\.parse\('))
        if (-not $m.Success) { continue }
        $q = $Html.IndexOf('"', $m.Index + $m.Length)
        if ($q -lt 0) { continue }
        $json = ConvertFrom-JsStringLiteral -Text $Html -OpenQuoteIndex $q
        if (-not $json) { continue }
        try {
            $obj = ConvertFrom-JsonBig -Json $json
            if ($obj) { return $obj }
        } catch {
            Write-Warning "$name parse failed: $($_.Exception.Message)"
        }
    }
    return $null
}

# ---------------------------------------------------------------- HTML -> text

function Convert-HtmlToText {
    param([string] $Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $t = $Html
    $t = [regex]::Replace($t, '(?is)<(script|style|svg|noscript)\b[^>]*>.*?</\1>', ' ')
    $t = [regex]::Replace($t, '(?is)<br\s*/?>', "`n")
    $t = [regex]::Replace($t, '(?is)</(p|div|li|tr|h[1-6]|section|article)>', "`n")
    $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '[ ​]', ' '
    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, '(?m)^[ \t]+|[ \t]+$', '')
    $t = [regex]::Replace($t, '(\r?\n){2,}', "`n")
    return $t.Trim()
}

function Convert-HtmlTableToRows {
    <# Returns an array of string[] rows from an HTML <table>. #>
    param([string] $Html)
    $rows = @()
    foreach ($tr in [regex]::Matches($Html, '(?s)<tr\b.*?</tr>')) {
        $cells = @()
        foreach ($td in [regex]::Matches($tr.Value, '(?s)<t[dh]\b.*?</t[dh]>')) {
            $cells += (Convert-HtmlToText $td.Value) -replace "`n", ' '
        }
        if ($cells.Count) { $rows += ,@($cells) }
    }
    return $rows
}

# ---------------------------------------------------------------- content tree walk

function Get-ContentNodes {
    <#
      Depth-first walk of an Apptegy content structure, yielding flat records:
        @{ type = 'heading'|'text'|'table'|'button'|'file'; text; rows; url }
    #>
    param($Node)

    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Node) { return @() }

    $stack = New-Object System.Collections.Stack
    $stack.Push($Node)
    # Collect in document order: push children in reverse.
    $ordered = New-Object System.Collections.ArrayList
    while ($stack.Count) {
        $n = $stack.Pop()
        if ($null -eq $n) { continue }
        if ($n -is [object[]]) {
            for ($i = $n.Count - 1; $i -ge 0; $i--) { $stack.Push($n[$i]) }
            continue
        }
        [void]$ordered.Add($n)
        $kids = Get-Prop $n 'nodes'
        if ($kids -is [object[]]) {
            for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push($kids[$i]) }
        }
    }

    foreach ($n in $ordered) {
        $type = [string](Get-Prop $n 'type')
        if (-not $type) { continue }
        $html = [string](Get-Prop (Get-Prop $n 'content') 'html')

        switch -Regex ($type) {
            'CONTENT_NODE_HEADING' {
                $tx = Convert-HtmlToText $html
                if ($tx) { [void]$out.Add(@{ type = 'heading'; text = $tx }) }
            }
            'CONTENT_NODE_TABLE' {
                $rows = Convert-HtmlTableToRows $html
                if ($rows.Count) { [void]$out.Add(@{ type = 'table'; rows = $rows }) }
            }
            'CONTENT_NODE_(TEXT|PARAGRAPH|RICH_TEXT|LIST)' {
                $tx = Convert-HtmlToText $html
                if ($tx) { [void]$out.Add(@{ type = 'text'; text = $tx }) }
            }
            'CONTENT_NODE_(BUTTON|LINK)' {
                $props = Get-Prop $n 'properties'
                $url   = [string](Get-Prop $props 'url')
                $label = [string](Get-Prop $props 'label')
                if (-not $label) { $label = Convert-HtmlToText $html }
                if ($url -or $label) { [void]$out.Add(@{ type = 'button'; text = $label; url = $url }) }
            }
            'CONTENT_NODE_FILE' {
                $props = Get-Prop $n 'properties'
                $url   = [string](Get-Prop $props 'url')
                $label = [string](Get-Prop $props 'name')
                if ($url) { [void]$out.Add(@{ type = 'file'; text = $label; url = $url }) }
            }
            default {
                # Unknown node that still carries prose - keep the text.
                if ($html) {
                    $tx = Convert-HtmlToText $html
                    if ($tx) { [void]$out.Add(@{ type = 'text'; text = $tx }) }
                }
            }
        }
    }
    return $out.ToArray()
}

function Get-Prop {
    <# Safe property access under Set-StrictMode. #>
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}
