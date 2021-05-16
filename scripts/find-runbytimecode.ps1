[CmdletBinding()]
param (
    # Path to TSV file which contains a file id + offset
    [parameter(Mandatory=$true, Position = 0)]
    [string] $IndexFile,
    # Time code which needs to be looked up in index
    [parameter(Mandatory=$true, Position = 1)]
    [string] $Time,
    # This switch will look up the given time code in one of the source films. Note that the Film parameter is then required
    [switch] $Source,
    # Which source film we're checking. Should be of the form "2E"
    [string] $Film
)

Import-Module (Join-Path $PSScriptRoot "subtitle-helpers.psm1")

$indexFile = Resolve-Path $indexFile

if (-not (Test-Path $indexFile -PathType Leaf)) {
    throw "Index file not found"
}

if (! $Source -and $Film) {
    throw "Film parameter should only be used when looking in source films"
}
if ($Source -and ! $Film) {
    throw "Film parameter should be passed when looking in source films"
}
if ($Film -and -not $Film -match "^[0-9][TE]$") {
    throw "Film parameter [$Film] uses unexpected format. Use e.g. 2E or 2T instead"
}

if (-not $Time -match "^[0-9]+:[0-9]+:[0-9]+") {
    throw "Time parameter [$Time] uses unexpected format. Use H:M:S or H:M:S,fff."
}

#######################################################################################################################
#######################################################################################################################
####  Helper functions
#######################################################################################################################
#######################################################################################################################

# Writes run information to the result
function Join-RunInfo ([System.Text.StringBuilder] $result, $run) {
    $runInfoOrg = $index[$run]
    $runInfoFanedit = $faneditIndex[$run]
    $result.Append("Run id: ").Append($runInfoOrg.Id).Append(", Name: ").Append($runInfoOrg.Run) > $null
    $result.Append(", Offset: ").AppendLine($runInfo.Offset.ToString("c")) > $null
    $result.Append("Source  ").AppendLine($runInfoOrg.TimeInfo) > $null
    $result.Append("Fanedit ").Append($runInfoFanedit.TimeInfo) > $null

    $result
}

#######################################################################################################################
#######################################################################################################################
####  Script logic
#######################################################################################################################
#######################################################################################################################

if ($Time -ilike "*,*") {
    $needle = [datetime]::ParseExact($Time, 'H:m:s,fff', $null)
} else {
    $needle = [datetime]::ParseExact($Time, 'H:m:s', $null)
}
if (! $needle) {
    throw "Time input could not be parsed."
}

$index = Read-Index $indexFile
$faneditIndex = Convert-IndexToFaneditTime $index

if ($Source) {
    throw "Not yet implemented"
} else {
    $run = 0
    while ($run -lt $faneditIndex.Count) {
        $runInfo = $faneditIndex[$run]
        if ($runInfo.Start -gt $needle) {
            break;
        }
        if ($runInfo.End -gt $needle) {
            break;
        }
        $run++
    }

    if ($run -ge $faneditIndex.Count) {
        throw "Time $Time appears to be past end of film"
    }

    $result = New-Object System.Text.StringBuilder

    $runInfo = $faneditIndex[$run]
    if ($runInfo.Start -gt $needle -and $run -eq 0) {
        $result.Append("Time ").Append($Time).AppendLine(" is before first run:") > $null
        Join-RunInfo $result $run > $null
        Write-Warning  $result.ToString()
    } elseif ($runInfo.Start -gt $needle) {
        $result.Append("Time ").Append($Time).AppendLine(" is between two runs:") > $null
        Join-RunInfo $result ($run - 1) > $null
        $result.AppendLine().AppendLine("and") > $null
        Join-RunInfo $result $run > $null
        Write-Warning  $result.ToString()
    } else {
        Write-Output (Join-RunInfo $result $run).ToString()
    }
}