# This script takes a full subtitle for the fanedit and splits it into smaller files
# based on chapter and run number mentioned in the index. The split files are stored in the current folder.
#
# NOTE: This script assumes that subtitle files are using the UTF-8 encoding.
# Please convert them before running this script or accents might turn into mojibake.
#
[CmdletBinding()]
param (
    [parameter(Mandatory=$true)]
    $indexFile,
    [parameter(Mandatory=$true)]
    $subtitleFile
)

Import-Module (Join-Path $PSScriptRoot "subtitle-helpers.psm1")

$indexFile = Resolve-Path $indexFile
$outputDir = Get-Location
if (-not (Test-Path $indexFile)) {
    throw "Index.tsv file not found"
}

if (-not (Test-Path $subtitleFile)) {
    throw "Subtitle file could not be found"
}
$subtitleFile = Resolve-Path $subtitleFile

$index = Read-Index $indexFile

# Calculate intervals in fan-edit timebase. The index stores it in source film timebase and the edit might put things closer together,
# so we need to avoid overlapping intervals. It's preferable to make an overly long interval shorter at the end while we keep the start times

$lastRunStart = [datetime]::Parse("05:00:00")

# Go backwards so that we only need to remember last interval's start time rather than looking ahead all the time.
for ($i = $index.Count - 1; $i -ge 0; $i--) {
    $indexItem = $index[$i]
    #Write-Host "Got index item $($indexItem) $i"
    # Calculate offsets in actual film edit. The index contains offsets for the original films + the difference with the edit
    $startInEdit = $indexItem.Start.Add($indexItem.Offset)
    $endInEdit = $indexItem.End.Add($indexItem.Offset)
    # If intervals overlap then we simply fix the current one
    if ($endInEdit -ge $lastRunStart) {
        $endInEdit = $lastRunStart
    }
    $index[$i] = $indexItem.ChangeInterval($startInEdit, $endInEdit)

    $lastRunStart = $startInEdit
}

#$index | ForEach-Object {
#    Write-Host "Index $($_.Run) - $($_.Start.ToString("hh:mm:ss,fff")) - $($_.End.ToString("hh:mm:ss,fff"))"
#}

$reader = $null
$currentSubtitle = $null
$errors = New-Object System.Collections.ArrayList
$subtitles = New-Object System.Collections.ArrayList
$lastRunEnd = [datetime]::Parse("00:00:00")

try {
    $reader = New-Object System.IO.StreamReader -ArgumentList @($subtitleFile, [System.Text.Encoding]::UTF8)

    $currentSubtitle = Get-NextSubtitle $reader

    for ($i = 0; $i -lt $index.Count ; $i++) {
        $indexItem = $index[$i]
        # These subtitles do not seem to fall into any interval
        $errors.Clear()
        while ($null -ne $currentSubtitle -and $indexItem.Start -gt $currentSubtitle.End) {
            $errors.Add($currentSubtitle) > $null
            $currentSubtitle = Get-NextSubtitle $reader
        }
        if ($errors.Count -gt 0) {
            $numbers = $errors | ForEach-Object { $_.Number }
            Write-Error ("Found $($errors.Count) lines between $(Get-Date -Format "HH:mm:ss,fff" $lastRunEnd) "`
                + "and $(Get-Date -Format "HH:mm:ss,fff" $indexItem.Start) before run $indexItem. Sub number(s): $numbers")
        }
        # Now we are at the point where we might find subtitles for this run
        $subtitles.Clear()
        while ($null -ne $currentSubtitle -and $indexItem.End -gt $currentSubtitle.End) {
            $subtitles.Add($currentSubtitle) > $null
            $currentSubtitle = Get-NextSubtitle $reader
        }
        # Check if there's a subtitle which hangs over the end
        if ($null -ne $currentSubtitle -and $indexItem.End -gt $currentSubtitle.Start) {
            # It does hang over. If more than half falls in the current run then we'll take it, otherwise it's left undecided
            $timeInRun = $indexItem.End - $currentSubtitle.Start
            $timePastRun = $currentSubtitle.End - $indexItem.End
            if ($timeInRun -gt $timePastRun) {
                $subtitles.Add($currentSubtitle) > $null
                $currentSubtitle = Get-NextSubtitle $reader
            }
        }
        $currentRunOutput = Join-Path $outputDir ("{0}.srt" -f $indexItem.Run)
        Write-Subtitles $subtitles $currentRunOutput
        Write-Host "Wrote $($subtitles.Count) subtitles to $currentRunOutput"

        $lastRunEnd = $indexItem.End
    }
    # These subtitles do not seem to fall into any interval and just went through all intervals
    $errors.Clear()
    while ($null -ne $currentSubtitle) {
        $errors.Add($currentSubtitle) > $null
        $currentSubtitle = Get-NextSubtitle $reader
    }
    if ($errors.Count -gt 0) {
        $numbers = $errors | ForEach-Object { $_.Number }
        Write-Error ("Found $($errors.Count) lines after $(Get-Date -Format "HH:mm:ss,fff" $lastRunEnd). Sub number(s): $numbers")
    }
} finally {
    if ($null -ne $reader) {
        $reader.Close()
    }
}

