# This script expects 6 subtitle files meant for the original films and splits
# them into short pieces which can then be synced to match up with the fanedit
# using the offset-titles script. Run this script inside the runs/<lang>-cut
# folder.
#
# Simply put there are 3 films which each have 2 editions:
# - the theatrical or "normal" cut
# - the extended edition which got released on home media
# Each subtitle is slightly different.
#
# NOTE: This script assumes these subtitle files are using the UTF-8 encoding.
# Please convert them before running this script or accents might turn into mojibake.
#
[CmdletBinding()]
param (
    [parameter(Mandatory=$true)]
    $indexFile,
    [parameter(Mandatory=$true)]
    $srtFilm1Normal,
    [parameter(Mandatory=$true)]
    $srtFilm1Extended,
    [parameter(Mandatory=$true)]
    $srtFilm2Normal,
    [parameter(Mandatory=$true)]
    $srtFilm2Extended,
    [parameter(Mandatory=$true)]
    $srtFilm3Normal,
    [parameter(Mandatory=$true)]
    $srtFilm3Extended
)
$indexFile = Resolve-Path $indexFile
$outputDir = Get-Location
if (-not (Test-Path $indexFile)) {
    throw "Index-automated-cut.tsv file not found"
}

if (-not (Test-Path $srtFilm1Normal) -or -not (Test-Path $srtFilm1Extended) `
        -or -not (Test-Path $srtFilm2Normal) -or -not (Test-Path $srtFilm2Extended) `
        -or -not (Test-Path $srtFilm3Normal) -or -not (Test-Path $srtFilm3Extended)) {
    throw "One or more of the subtitle files could not be found"
}
$srtFilm1Normal   = Resolve-Path $srtFilm1Normal
$srtFilm1Extended = Resolve-Path $srtFilm1Extended
$srtFilm2Normal   = Resolve-Path $srtFilm2Normal
$srtFilm2Extended = Resolve-Path $srtFilm2Extended
$srtFilm3Normal   = Resolve-Path $srtFilm3Normal
$srtFilm3Extended = Resolve-Path $srtFilm3Extended

Import-Module (Join-Path $PSScriptRoot "subtitle-helpers.psm1")

# ################################################################################
#
# Main logic
#
# ################################################################################

$index = Read-Index $indexFile

$sortedRuns = $index | Sort-Object -Property Film, Type, Start | ForEach-Object {
    $_.PickSourceFile($srtFilm1Normal, $srtFilm1Extended, $srtFilm2Normal, $srtFilm2Extended, $srtFilm3Normal, $srtFilm3Extended)
    $_
}

$currentFile = $null
$currentReader = $null
$currentSubtitle = $null
try {
    foreach ($run in $sortedRuns) {
        if ($run.SourceFile -ne $currentFile) {
            Write-Output "Reading $($run.SourceFile)"
            if ($null -ne $currentReader) {
                $currentReader.Close()
            }
            $currentSubtitle = $null
            $currentFile = $run.SourceFile
            $currentReader = New-Object System.IO.StreamReader -ArgumentList @($currentFile, [System.Text.Encoding]::UTF8)
        }
        Write-Output "Handling run $($run.Run)"
        $subtitles = New-Object System.Collections.ArrayList

        if ($null -eq $currentSubtitle) {
            $currentSubtitle = Get-NextSubtitle $currentReader
        }
        # Discard subtitles when run is later in the file than current subtitle
        while ($currentSubtitle -and $run.Start -gt $currentSubtitle.End) {
            $currentSubtitle = Get-NextSubtitle $currentReader
        }

        # Subtitle starts slightly before run and ends inside run, include it anyway with a warning
        if ($currentSubtitle -and $currentSubtitle.Start -lt $run.Start) {
            Write-Warning "First subtitle in run $($run.Run) hangs over start"
            $subtitles.Add($currentSubtitle) > $null
            $currentSubtitle = Get-NextSubtitle $currentReader
        }
        # Start collecting run's subtitles
        while ($currentSubtitle -and $run.End -gt $currentSubtitle.End) {
            $subtitles.Add($currentSubtitle) > $null
            $currentSubtitle = Get-NextSubtitle $currentReader
        }
        # Last subtitle hangs over end of run, include it anyway with a warning
        if ($currentSubtitle -and $currentSubtitle.Start -lt $run.End) {
            Write-Warning "Last subtitle in run $($run.Run) hangs over end"
            $subtitles.Add($currentSubtitle) > $null
            $currentSubtitle = Get-NextSubtitle $currentReader
        }
        # Write subtitles
        if ($subtitles.Count -gt 0) {
            $currentRunOutput = Join-Path $outputDir ("{0}.srt" -f $run.Run)
            Write-Subtitles $subtitles $currentRunOutput
        } elseif (-not $run.CanBeEmpty) {
            Write-Error "Run $($run.Run) did not find any subtitles in file $($run.SourceFile). Check the output"
        } else {
            Write-Output "Run $($run.Run) is empty"
        }
    }
} finally {
    if ($null -ne $currentReader) {
        $currentReader.Close()
    }
}
