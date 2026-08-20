<#
.SYNOPSIS
  lspci for Windows. Reads Windows' PnP/PCI enumeration; no kernel driver.

.DESCRIPTION
  Accepts lspci's flags where they map onto data Windows exposes. Flags that
  would require configuration-space reads (-x, -xxx, capability decoding) are
  rejected with an explanation rather than silently ignored -- a tool that
  quietly does less than you asked is worse than one that says it cannot.

  Arguments are parsed here rather than by a param() block, on purpose.
  PowerShell's binder matches parameter names case-insensitively and by
  unique prefix, which is wrong for an lspci-shaped command line: `-p` bound
  to -PresentOnly and dumped every attribute, `-m` died asking for a value
  for -Match, `-D` collided with `-d`, and `-tv` / `-nnk` fell through and
  ran the plain unfiltered listing. A small lspci-aware parser gives
  case-sensitive short flags that combine (-tv, -nnk, -vvnn), a clear
  "not implemented" for the lspci flags this tool does not have, and a hard
  error for anything unknown.

  Exit codes: 0 ok; 1 a filter matched nothing; 2 the request is impossible or
  not implemented here; 64 usage error; 70 the WMI enumeration itself failed.

.EXAMPLE
  lspci
  lspci -nn
  lspci -d 11f8:
  lspci -vv -d ::0108
  lspci -s 01:00.0 -v
  lspci -tv
  lspci -Json
#>

$ErrorActionPreference = 'Stop'
# The module is imported AFTER argument parsing (see below): --help and usage
# errors then answer in ~0.5s instead of paying ~130ms for a module they never
# call into.

function Write-Usage {
    @'
Usage: lspci [<switches>]

Selection:        -s [[[<domain>]:]<bus>:]<device>[.<func>]   -d [<vendor>]:[<device>][:<class>]
Output:           -v / -vv / -vvv   -n   -nn   -k   -t   -D   -Downtrained
Machine-readable: -m   -mm   -Json   -Csv   -Delimited [-Delimiter <d>] [-Header]
Attributes:       -Attribute <names>   -Match <regex>   -PresentOnly   -ListAttributes
Lab:              -Baseline <file>   -Diff <file> [-IgnoreAttribute <names>] [-IncludeVolatile]
                  -Watch <seconds> [-Iterations <n>]   -i <pci.ids>
Remote:           -ComputerName <host,host,...> [-Credential <user>]   (WinRM)
Other:            -Version   --help

Short flags combine as in lspci (-tv, -nnk, -vvnn). Long names are
case-insensitive and may be abbreviated to a unique prefix.
Not available without a kernel driver: -x/-xxx/-xxxx (config space).
'@ | Write-Output
}

function Fail {
    param([string]$Message, [int]$Code)
    # [Console]::Error, not Write-Error: with $ErrorActionPreference = 'Stop'
    # Write-Error would terminate with exit 1 and the exit code below would
    # never be reached, so a caller could not tell "impossible request" from
    # any other failure.
    [Console]::Error.WriteLine("lspci: $Message")
    exit $Code
}

# ----------------------------------------------------------------- parsing

$opt = @{
    Device = ''; Slot = ''; Verbosity = 0; Numeric = 0; Tree = $false
    Domain = $false; Attribute = @(); Match = $null; PresentOnly = $false
    ListAttributes = $false; Csv = $false; Delimited = $false; Delimiter = '|'
    Header = $false; Json = $false; Downtrained = $false; Version = $false
    Machine = 0; IdsFile = $null
    Baseline = $null; Diff = $null; IgnoreAttribute = @(); IncludeVolatile = $false; Watch = 0; Iterations = 0
    ComputerName = @(); Credential = $null
}

# Long options: name -> takes a value? Matched case-insensitively, exact or
# unique prefix, with either -Name or --name, and -Name value / -Name:value.
$longOptions = [ordered]@{
    'Device' = $true; 'Slot' = $true; 'Tree' = $false; 'Domain' = $false
    'Attribute' = $true; 'Match' = $true; 'PresentOnly' = $false
    'ListAttributes' = $false; 'Csv' = $false; 'Delimited' = $false
    'Delimiter' = $true; 'Header' = $false; 'Json' = $false
    'Downtrained' = $false; 'Numeric' = $false; 'NumericAndNames' = $false
    'ShowDriver' = $false; 'Version' = $false; 'Help' = $false
    'Baseline' = $true; 'Diff' = $true; 'IgnoreAttribute' = $true; 'IncludeVolatile' = $false
    'Watch' = $true; 'Iterations' = $true; 'IdsFile' = $true
    'ComputerName' = $true; 'Credential' = $true
}

# Short flags are CASE-SENSITIVE, as in lspci: -D is domain, -d is a filter.
$shortSwitches = 'vnktDm'         # combinable, no value (-m once, -mm twice)
$shortWithValue = 'sdi'           # -s 01:00.0  or  -s01:00.0 ; -i <pci.ids>
# 'vnktDm' / 'sdi' are read by the parser below, never edit one without the other.

# lspci flags this tool knows about and deliberately does not implement. Said
# so, with a pointer, rather than bound to something unrelated or ignored.
# A case-SENSITIVE dictionary: a PowerShell hashtable literal folds 'm' and
# 'M' (or 'p' and 'P') into one key and refuses to load.
$notImplemented = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
$lookup  = 'online ID lookup is not implemented; run Update-PciIds to refresh pci.ids'
$access  = 'access methods do not apply: there is no config-space access on Windows'
$path    = 'path display is not implemented; -t shows the topology'
$notImplemented['b']  = 'bus-centric view is not implemented: Windows exposes no bus-relative view distinct from the CPU one'
$notImplemented['P']  = $path
$notImplemented['PP'] = $path
$notImplemented['q']  = $lookup
$notImplemented['qq'] = $lookup
$notImplemented['Q']  = $lookup
$notImplemented['p']  = 'a custom ID file is not implemented (-i <file> loads an alternate pci.ids)'
$notImplemented['M']  = 'bus mapping mode is not implemented'
foreach ($f in 'A', 'O', 'F', 'G', 'H1', 'H2') { $notImplemented[$f] = $access }

function Set-LongOption {
    param([string]$Name, $Value)
    switch ($Name) {
        'Device'          { $opt.Device = "$Value" }
        'Slot'            { $opt.Slot = "$Value" }
        'Tree'            { $opt.Tree = $true }
        'Domain'          { $opt.Domain = $true }
        'Attribute'       { $opt.Attribute += @("$Value" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        'Match'           { $opt.Match = "$Value" }
        'PresentOnly'     { $opt.PresentOnly = $true }
        'ListAttributes'  { $opt.ListAttributes = $true }
        'Csv'             { $opt.Csv = $true }
        'Delimited'       { $opt.Delimited = $true }
        'Delimiter'       { $opt.Delimiter = "$Value" }
        'Header'          { $opt.Header = $true }
        'Json'            { $opt.Json = $true }
        'Downtrained'     { $opt.Downtrained = $true }
        'Numeric'         { if ($opt.Numeric -lt 1) { $opt.Numeric = 1 } }
        'NumericAndNames' { $opt.Numeric = 2 }
        'ShowDriver'      { if ($opt.Verbosity -lt 1) { $opt.Verbosity = 1 } }
        'Version'         { $opt.Version = $true }
        'Help'            { Write-Usage; exit 0 }
        'Baseline'        { $opt.Baseline = "$Value" }
        'Diff'            { $opt.Diff = "$Value" }
        'IgnoreAttribute' { $opt.IgnoreAttribute += @("$Value" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        'IncludeVolatile' { $opt.IncludeVolatile = $true }
        'Watch'           { $opt.Watch = "$Value" }
        'Iterations'      { $opt.Iterations = "$Value" }
        'IdsFile'         { $opt.IdsFile = "$Value" }
        'ComputerName'    {
            # Keep blanks so they can be REFUSED: `-ComputerName %NODE%` with
            # the variable unset must not quietly list this machine.
            $names = @("$Value" -split ',' | ForEach-Object { $_.Trim() })
            if ($names.Count -eq 0 -or @($names | Where-Object { $_ -eq '' }).Count -gt 0) {
                Fail "-ComputerName contains an empty name ('$Value'); refusing to fall back to the local machine silently" 64
            }
            $opt.ComputerName += $names
        }
        'Credential'      { $opt.Credential = "$Value" }
    }
}

function Set-ShortSwitch {
    param([char]$Flag)
    switch -CaseSensitive ("$Flag") {
        'v' { if ($opt.Verbosity -lt 3) { $opt.Verbosity++ } }
        'n' { if ($opt.Numeric -lt 2) { $opt.Numeric++ } }   # -n ids, -nn both
        'k' { if ($opt.Verbosity -lt 1) { $opt.Verbosity = 1 } }  # driver is part of -v
        't' { $opt.Tree = $true }
        'D' { $opt.Domain = $true }
        'm' { if ($opt.Machine -lt 2) { $opt.Machine++ } }      # -m line form, -mm record form
    }
}

function Get-RawArguments {
    <#
      PowerShell tokenises `-Name:value` before a script ever sees it, and the
      colon does not survive: `-s01:` arrives as `-s01` (which under lspci's
      grammar is DEVICE 01, not bus 01), `-s01:00.0` arrives as `-s01` `00.0`,
      and `-d8086:` on its own arrives as nothing at all. When this script was
      started with `powershell.exe -File` (the lspci.cmd path), the process
      command line still holds the user's exact tokens, so take them from
      there. Invoked directly from a PowerShell prompt, $args is all there is;
      the attached forms are then best avoided (`-s 01:` with a space is safe).
    #>
    param($ScriptArgs)
    $raw = @([Environment]::GetCommandLineArgs())
    for ($k = 0; $k -lt $raw.Count - 1; $k++) {
        if ($raw[$k] -match '^[-/]f(i(le?)?)?$' -and $PSCommandPath) {
            $pathMatches = $false
            try {
                $pathMatches = ([IO.Path]::GetFullPath($raw[$k + 1]) -ieq [IO.Path]::GetFullPath($PSCommandPath))
            } catch { $pathMatches = $false }
            if ($pathMatches) {
                if ($k + 2 -lt $raw.Count) { return @($raw[($k + 2)..($raw.Count - 1)]) }
                return @()
            }
        }
    }
    # Fallback (invoked from a PowerShell prompt): the prompt's parser splits
    # `-Match:zzz` into `-Match:` + `zzz` and `-s01:00.0` into `-s01:` + `0`
    # (it reads `00.0` as a NUMBER). Re-join a colon-terminated token with the
    # value that follows it, which recovers the first and the plain `-s01:`
    # form; the numeric mangling is not recoverable here -- the README says to
    # quote selector values at the prompt, or use the lspci launcher.
    $fixed = @()
    $list = @($ScriptArgs)
    for ($k = 0; $k -lt $list.Count; $k++) {
        # A [double] here means the prompt ate a dot: `.0` or `00.0` arrived
        # as the number 0, which is a DIFFERENT valid filter (device 00).
        # Refuse rather than answer the wrong question.
        if ($list[$k] -is [double] -or $list[$k] -is [decimal]) {
            Fail ("value '$($list[$k])' was converted to a number by the PowerShell prompt before " +
                  "this script saw it; quote it (-s '.0') or use the lspci launcher") 64
        }
        $tok = "$($list[$k])"
        if ($tok -match '^-\S+:$' -and $k + 1 -lt $list.Count -and -not "$($list[$k + 1])".StartsWith('-')) {
            $fixed += "$tok$($list[$k + 1])"
            $k++
        } else {
            $fixed += $tok
        }
    }
    return $fixed
}

$argv = @(Get-RawArguments $args)
$i = 0
while ($i -lt $argv.Count) {
    $arg = "$($argv[$i])"
    $i++

    if ($arg -eq '--help' -or $arg -eq '-h' -or $arg -eq '-?' -or $arg -eq '/?') { Write-Usage; exit 0 }
    if ($arg -eq '--version') { $opt.Version = $true; continue }

    if (-not $arg.StartsWith('-') -or $arg -eq '-') {
        Fail "unexpected argument '$arg' (lspci takes switches only; use -s or -d to select devices)" 64
    }

    $body = $arg.TrimStart('-')
    $inlineValue = $null
    $sep = $body.IndexOfAny(@(':', '='))
    # A long option may carry its value inline (-Match:foo, --match=foo), but a
    # short -s value legitimately contains ':' (-s01:00.0), so only split when
    # the head is not a short flag.
    if ($sep -gt 0 -and $shortWithValue.IndexOf($body[0]) -lt 0) {
        $inlineValue = $body.Substring($sep + 1)
        $body = $body.Substring(0, $sep)
    }
    if ($body -eq '') { Fail "unexpected argument '$arg'" 64 }

    # 1. Config-space requests: impossible here, say so.
    if ($body -match '^x+$') {
        Fail ("cannot dump configuration space ($arg). Windows exposes no userland path to PCI " +
              "config space; that needs a signed kernel-mode driver. Everything this tool " +
              "reports comes from the PnP database the PCI bus driver populates.") 2
    }

    # 2. lspci flags we know and do not implement.
    if ($notImplemented.ContainsKey($body) -and $arg.StartsWith('--') -eq $false) {
        Fail "$arg is not implemented: $($notImplemented[$body])" 2
    }

    # 3. A run of short flags: every character must be a known short flag,
    #    compared case-sensitively. -s/-d take the rest of the token or the
    #    next argument as their value, as lspci does.
    #
    #    A multi-character token that names a long option (exactly, or as a
    #    prefix -- `-device`, `-slot`, `-delimited`, `-do`) is a long option
    #    first: otherwise `-device 8086:` would be read as `-d evice`. A
    #    single character is always a short flag (`-v` is not `-Version`).
    $looksLong = $false
    if ($body.Length -ge 2) {
        $looksLong = @($longOptions.Keys | Where-Object { $_.StartsWith($body, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    }
    $allShort = -not $looksLong
    if ($allShort) {
        foreach ($ch in $body.ToCharArray()) {
            if ($shortWithValue.IndexOf($ch) -ge 0) { break }          # rest of token is its value
            if ($shortSwitches.IndexOf($ch) -lt 0) { $allShort = $false; break }
        }
    }
    if ($allShort -and -not $arg.StartsWith('--')) {
        $chars = $body.ToCharArray()
        for ($c = 0; $c -lt $chars.Length; $c++) {
            $ch = $chars[$c]
            if ($shortWithValue.IndexOf($ch) -ge 0) {
                $value = $null
                if ($c + 1 -lt $chars.Length) {
                    $value = $body.Substring($c + 1)
                } elseif ($i -lt $argv.Count) {
                    $value = "$($argv[$i])"; $i++
                } else {
                    Fail "-$ch requires a value" 64
                }
                if ("$ch" -ceq 's') { $opt.Slot = $value }
                elseif ("$ch" -ceq 'i') { $opt.IdsFile = $value }
                else { $opt.Device = $value }
                break
            }
            Set-ShortSwitch $ch
        }
        continue
    }

    # 4. Long option, exact or unique prefix, case-insensitive.
    $candidates = @($longOptions.Keys | Where-Object { $_ -eq $body })
    if ($candidates.Count -eq 0) {
        $candidates = @($longOptions.Keys | Where-Object { $_.StartsWith($body, [StringComparison]::OrdinalIgnoreCase) })
    }
    if ($candidates.Count -eq 0) {
        Fail "unknown option '$arg' (try --help)" 64
    }
    if ($candidates.Count -gt 1) {
        Fail "ambiguous option '$arg': could be -$($candidates -join ', -')" 64
    }
    $name = $candidates[0]
    $value = $null
    if ($longOptions[$name]) {
        if ($null -ne $inlineValue) {
            $value = $inlineValue
        } elseif ($i -lt $argv.Count) {
            $value = "$($argv[$i])"; $i++
        } else {
            Fail "-$name requires a value" 64
        }
    } elseif ($null -ne $inlineValue) {
        Fail "-$name does not take a value" 64
    }
    Set-LongOption $name $value
}

# ----------------------------------------------------------------- actions

Import-Module (Join-Path $PSScriptRoot '..\winlspci.psd1') -Force

if ($env:WINLSPCI_FIXTURE) {
    # Once per process, on STDERR so -Json / -m / -Delimited stay parseable.
    [Console]::Error.WriteLine("lspci: WARNING: enumerating from fixture '$env:WINLSPCI_FIXTURE' (WINLSPCI_FIXTURE is set). This is NOT this machine's hardware.")
}

if ($opt.Version) {
    $m = Get-Module winlspci
    Write-Output "winlspci $($m.Version)"
    $ids = Join-Path $PSScriptRoot '..\data\pci.ids'
    if (Test-Path $ids) {
        $stamp = (Select-String -Path $ids -Pattern '^#\s+Version:' -List).Line
        Write-Output "pci.ids  $($stamp -replace '^#\s+Version:\s*', '')"
    }
    exit 0
}

# Answered from the module's static shape; no enumeration needed, so it comes
# before the (expensive) device query.
if ($opt.ListAttributes) {
    Get-PciAttributeName
    exit 0
}

if ($opt.Delimiter -eq '') { Fail '-Delimiter must not be empty' 64 }
$formats = @(@('Json', 'Csv', 'Delimited') | Where-Object { $opt[$_] })
if ($opt.Machine -gt 0) { $formats += 'm' }
if ($formats.Count -gt 1) { Fail "choose one output format, not -$($formats -join ' and -')" 64 }

if ($opt.IdsFile) {
    try { Import-PciIds -Path $opt.IdsFile } catch { Fail $_.Exception.Message 64 }
}

foreach ($numeric in @(@('Watch', $opt.Watch), @('Iterations', $opt.Iterations))) {
    $n = 0
    if (-not [int]::TryParse("$($numeric[1])", [ref]$n) -or $n -lt 0) { Fail "-$($numeric[0]) takes a non-negative whole number, got '$($numeric[1])'" 64 }
    $opt[$numeric[0]] = $n
}
if ($argv -contains '-Watch' -and $opt.Watch -eq 0) { Fail '-Watch needs an interval of at least 1 second' 64 }

# Sorted by slot, as lspci does. Windows enumerates in an order that looks
# arbitrary to a reader scanning for a bus number. With several computers,
# by computer first.
$enumArgs = @{ Device = $opt.Device; Slot = $opt.Slot }
$multiNode = ($opt.ComputerName.Count -gt 1)
if ($opt.ComputerName.Count -gt 0) {
    $enumArgs['ComputerName'] = $opt.ComputerName
    if ($opt.Credential) {
        # Interactive by design: a password on the command line would land in
        # shell history. Get-Credential prompts for it. Under -NonInteractive,
        # a redirected stdin, or a cancelled prompt it returns nothing or
        # throws; either way we must NOT connect without the credential the
        # user asked for and then report "unreachable". Scripts should use
        # the module's -Credential with a PSCredential they already hold.
        $cred = $null
        try { $cred = Get-Credential -UserName $opt.Credential -Message "Credential for $($opt.ComputerName -join ', ')" } catch { $cred = $null }
        if ($null -eq $cred) { Fail '-Credential needs an interactive prompt for the password (none available, or cancelled); from a script, use Get-PciDevice -Credential <PSCredential>' 64 }
        $enumArgs['Credential'] = $cred
    }
}
try {
    $devices = @(Get-PciDevice @enumArgs | Sort-Object ComputerName, Slot)
} catch {
    # Selector validation errors (bad hex in -s / -d) are usage errors (64);
    # a WMI/CIM failure during enumeration is not the user's doing (70), and
    # must never be confused with "no devices".
    if ($_.Exception.Message -like 'PCI enumeration failed*') { Fail $_.Exception.Message 70 }
    Fail $_.Exception.Message 64
}

if ($opt.Downtrained) {
    # The question people actually open lspci to answer.
    $devices = @($devices | Where-Object { $_.Downtrained })
}

if ($opt.Domain) {
    # lspci -D prints the domain on every line. A non-zero domain (Hyper-V /
    # Azure SR-IOV functions) is already in the Slot; everything else is 0000.
    $devices = @($devices | ForEach-Object {
        if ($_.Slot -match '^[0-9a-f]{4}:') { $_ }
        else { $_ | Add-Member -NotePropertyName Slot -NotePropertyValue "0000:$($_.Slot)" -Force -PassThru }
    })
}

# -d, -s and -Downtrained are all filters: a filter that matches nothing must
# not look like success -- that is the difference between "the card is not
# there" (or "nothing is downtrained") and "the command worked".
$filtered = [bool]($opt.Device -or $opt.Slot -or $opt.Downtrained)
$exitCode = 0
if ($filtered -and $devices.Count -eq 0) { $exitCode = 1 }

# ----------------------------------------------------------- lab workflows

if ($opt.Baseline) {
    Export-PciBaseline -Path $opt.Baseline -Device $devices
    if ($opt.Json) { ConvertTo-Json -InputObject ([pscustomobject]@{ written = $devices.Count; path = $opt.Baseline }) }
    else { Write-Output "baseline: $($devices.Count) devices written to $($opt.Baseline)" }
    exit $exitCode
}

function Write-DiffRecords {
    param($Records, [string]$Stamp)
    foreach ($r in $Records) {
        $prefix = ''
        if ($Stamp) { $prefix = "$Stamp  " }
        switch ($r.Change) {
            'Added'   { Write-Output "$prefix+ $($r.Slot)  appeared: $($r.Now)" }
            'Removed' { Write-Output "$prefix- $($r.Slot)  gone: $($r.Was)" }
            'Changed' { Write-Output "$prefix~ $($r.Slot)  $($r.Attribute): $($r.Was) -> $($r.Now)" }
        }
    }
}

if ($opt.Diff) {
    # "Did the reboot / firmware / driver update change anything?" Exit 0 when
    # identical, 3 when there are differences -- a third answer, distinct from
    # "a filter matched nothing" (1).
    # A -d/-s filter applies to BOTH sides (the baseline is filtered the same
    # way), so "diff just the NVMe" works and a filter matching nothing is
    # still exit 1, not "everything disappeared".
    if ($filtered -and $devices.Count -eq 0) { Write-Output 'no matching PCI device'; exit 1 }
    try {
        $records = @(Compare-PciBaseline -Path $opt.Diff -Device $devices -IgnoreAttribute $opt.IgnoreAttribute `
            -IncludeVolatile:$opt.IncludeVolatile -DeviceFilter $opt.Device -SlotFilter $opt.Slot)
    } catch { Fail $_.Exception.Message 64 }
    if ($opt.Json) { if ($records.Count -eq 0) { Write-Output '[]' } else { ConvertTo-Json -InputObject $records -Depth 4 } }
    elseif ($opt.Csv) { $records | ConvertTo-Csv -NoTypeInformation }
    elseif ($opt.Delimited) { $records | Format-PciDelimited -Field Change, Slot, Attribute, Was, Now -Delimiter $opt.Delimiter -Header:$opt.Header }
    else {
        if ($records.Count -eq 0) { Write-Output "no differences against $($opt.Diff) ($($devices.Count) devices)" }
        else { Write-DiffRecords $records }
    }
    if ($records.Count -gt 0) { exit 3 }
    exit 0
}

if ($opt.Watch -gt 0) {
    # Re-enumerate every N seconds and print only what changed, timestamped.
    # Hot-plug, retimer bring-up, link flaps. Each pass is a full enumeration
    # (~2s), so the floor is about that; Ctrl-C stops it. -Iterations <n>
    # stops after n passes (tests use it), 0 = forever.
    $prev = $devices
    Write-Output ("{0}  watching {1} devices every {2}s (Ctrl-C to stop)" -f (Get-Date -Format 'HH:mm:ss'), $prev.Count, $opt.Watch)
    $passes = 0
    $changes = 0
    $failures = 0
    while ($true) {
        Start-Sleep -Seconds $opt.Watch
        $passes++
        try {
            $now = @(Get-PciDevice -Device $opt.Device -Slot $opt.Slot | Sort-Object Slot)
            $failures = 0
        } catch {
            # A failed pass still counts toward -Iterations, and three in a
            # row means WMI is down, not flapping: give up with exit 70.
            $failures++
            Write-Output ("{0}  enumeration failed: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)
            if ($failures -ge 3) { Fail 'enumeration failed three times in a row; stopping the watch' 70 }
            if ($opt.Iterations -gt 0 -and $passes -ge $opt.Iterations) { break }
            continue
        }
        if ($opt.Downtrained) { $now = @($now | Where-Object { $_.Downtrained }) }
        $records = @(Compare-PciDeviceSet -Before $prev -After $now -IgnoreAttribute $opt.IgnoreAttribute -IncludeVolatile:$opt.IncludeVolatile)
        if ($records.Count -gt 0) { Write-DiffRecords $records (Get-Date -Format 'HH:mm:ss'); $changes += $records.Count }
        $prev = $now
        if ($opt.Iterations -gt 0 -and $passes -ge $opt.Iterations) { break }
    }
    if ($changes -gt 0) { exit 3 }
    exit 0
}

if ($opt.Attribute.Count -gt 0 -or $opt.Match -or $opt.PresentOnly) {
    $args2 = @{}
    if ($opt.Attribute.Count -gt 0) { $args2['Attribute'] = $opt.Attribute }
    if ($opt.Match)                 { $args2['Match'] = $opt.Match }
    if ($opt.PresentOnly)           { $args2['PresentOnly'] = $true }
    $records = @($devices | ConvertTo-PciAttributeRecord @args2)

    if ($opt.Json) {
        # -InputObject, not the pipeline: piped, a single record serialises as
        # a bare object and zero records as nothing at all, so a consumer
        # written against an array breaks on exactly the small results.
        if ($records.Count -eq 0) { Write-Output '[]' }
        else { ConvertTo-Json -InputObject $records -Depth 5 }
    } elseif ($opt.Csv) {
        $records | ConvertTo-Csv -NoTypeInformation
    } elseif ($opt.Delimited) {
        $records | Format-PciDelimited -Delimiter $opt.Delimiter -Header:$opt.Header
    } else {
        $records | Format-Table -AutoSize
    }
    # An attribute query that matches nothing is a real answer, but it must not
    # be mistaken for success by a script.
    if ($records.Count -eq 0) { exit 1 }
    exit 0
}

$dataSource = Get-PciDataSource
if ($opt.Tree) {
    # Human output: carries its provenance on stdout like the plain listing.
    if ($dataSource -ne 'windows-pnp') { Write-Output "# source: $dataSource -- a recording, NOT this machine's hardware" }
    if ($multiNode) {
        # One tree per machine, labelled; parent ids do not cross machines.
        foreach ($group in ($devices | Group-Object ComputerName | Sort-Object Name)) {
            Write-Output "=== $($group.Name) ==="
            Format-PciTree -Devices @($group.Group) -Numeric $opt.Numeric
        }
    } else {
        Format-PciTree -Devices $devices -Numeric $opt.Numeric
    }
    exit $exitCode
}

if ($opt.Machine -gt 0) {
    $devices | Format-PciMachine -Mode $opt.Machine -Numeric $opt.Numeric
    exit $exitCode
}

if ($opt.Delimited) {
    if ($multiNode) {
        $fields = @('ComputerName', 'Slot', 'VendorId', 'DeviceId', 'ClassCode', 'ClassName', 'VendorName', 'DeviceName',
                    'Revision', 'LinkSpeed', 'LinkWidth', 'MaxLinkSpeed', 'MaxLinkWidth', 'Driver', 'Status')
        $devices | Format-PciDelimited -Field $fields -Delimiter $opt.Delimiter -Header:$opt.Header
    } else {
        $devices | Format-PciDelimited -Delimiter $opt.Delimiter -Header:$opt.Header
    }
    exit $exitCode
}

if ($opt.Csv) {
    $devices | ConvertTo-Csv -NoTypeInformation
    exit $exitCode
}

if ($opt.Json) {
    # schemaVersion is a promise: additive changes keep it, a rename or a
    # change of meaning in an existing field bumps it. Scripts should check
    # it. (SubsystemId changed meaning once, in 0.4.0, before this existed.)
    [pscustomobject]@{
        schemaVersion   = 1
        winlspciVersion = "$((Get-Module winlspci).Version)"
        generatedAt     = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        computerName    = $env:COMPUTERNAME
        source          = Get-PciDataSource
        note            = ('Windows PnP/PCI enumeration. No configuration-space access: ' +
                           'no hex dumps, no capability walks, no ASPM or AER detail.')
        filter          = @{ device = $opt.Device; slot = $opt.Slot; downtrained = [bool]$opt.Downtrained }
        count           = $devices.Count
        devices         = $devices
    } | ConvertTo-Json -Depth 6
    exit $exitCode
}

if ($devices.Count -eq 0) {
    if ($filtered) {
        Write-Output 'no matching PCI device'
    } else {
        Write-Output 'no PCI devices enumerated'
    }
}
# The human listing carries its provenance on STDOUT too: the stderr banner
# can be (legitimately) silenced, and this text is what gets pasted into a
# ticket. The machine formats already carry `source`.
if ($dataSource -ne 'windows-pnp') { Write-Output "# source: $dataSource -- a recording, NOT this machine's hardware" }
$devices | Format-Lspci -Verbosity $opt.Verbosity -Numeric $opt.Numeric -ShowComputer:$multiNode
exit $exitCode
