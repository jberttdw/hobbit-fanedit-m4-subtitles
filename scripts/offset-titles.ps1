[CmdletBinding(PositionalBinding = $false, SupportsShouldProcess=$true, ConfirmImpact = 'high')]
param (
    # Path to TSV file which contains a file id + offset
    [parameter(Mandatory=$true, Position = 0)]
    [string] $indexFile,
    # Optional identifiers of the runs which should be modified. If not specified, all runs will be offset
    [parameter(Position = 1)]
    [array] $runs,
    # This switch will negate the offsets, i.e. instead of shifting something forward it will shift it backward.
    # Handy to convert fanedit subtitles back to original timing of the source movies, then shift those to different edition timing.
    [switch] $Reverse,
    # Path where offset files should be written. Can remain blank for in-place editing.
    [string] $outputDir
)

Import-Module (Join-Path $PSScriptRoot "subtitle-helpers.psm1")

$indexFile = Resolve-Path $indexFile

if (-not (Test-Path $indexFile -PathType Leaf)) {
    throw "Index file not found"
}

if ($outputDir -and ! (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Write-Host
}
if ($outputDir) {
    $outputDir = Resolve-Path $outputDir
}

#######################################################################################################################
#######################################################################################################################
####  Helper functions
#######################################################################################################################
#######################################################################################################################

# Retrieves the first and last line of dialog from an SRT file. Note that just the timestamps are real, the rest is dummy data.
function Read-FirstAndLastSubtitle ([string] $file) {
    $file = Resolve-Path $file
    $reader = $null
    $first = $null
    $last = $null
    try {
        $reader = New-Object System.IO.StreamReader -ArgumentList @($file, [System.Text.Encoding]::UTF8)
        $line = $reader.ReadLine()
        while ($null -ne $line -and $null -eq $first)
        {
            if ($line -ilike "* --> *") {
                $first = New-Object PSObject -Property @{ Number = 0 }
                $first | Add-Member -Name "Text" -Value "Dummy" -MemberType NoteProperty > $null
                Read-TimeOffsets $line $first
                $last = $first
            }
            $line = $reader.ReadLine()
        }
        # Read until EOF, always keeping last encountered timestamps
        while ($null -ne $line)
        {
            if ($line -ilike "* --> *") {
                $last = New-Object PSObject -Property @{ Number = 0 }
                $last | Add-Member -Name "Text" -Value "Dummy" -MemberType NoteProperty > $null
                Read-TimeOffsets $line $last
            }
            $line = $reader.ReadLine()
        }
    } finally {
        if ($null -ne $reader) {
            $reader.Close()
        }
    }
    $first
    $last
}


# Verifies if the first and last subtitles in a file are inside of the expected index interval.
# If not then we might already have shifted their timestamps (or the filename is incorrect)
function Test-SubtitlesWithinRun ($first, $last, $runInfo) {
    # The intervals don't overlap at all - no further checks needed
    if ($first.Start -gt $runInfo.End -or $last.End -lt $runInfo.Start) {
        return $false
    }
    # Subtitle file is fully within bounds of expected run interval
    if ($first.Start -gt $runInfo.Start -and $last.End -lt $runInfo.End) {
        return $true
    }
    # Sometimes subtitles hang across the edges.
    # Check how much of the subtitle file hangs across the edge (or maybe even both edges) of the run.

    $overhangTicks = [math]::Max(0L, ($runinfo.Start.Ticks - $first.Start.Ticks)) + [math]::Max(0L, ($last.End.Ticks - $runInfo.End.Ticks))

    # No more than 5% of the subtitle file should hang over the edges of a regular run
    $maxOverhang = ($runInfo.Length.Ticks) * 5L / 100L
    if ($overhangTicks -le $maxOverhang) {
        return $true
    }

    #$percentOverhang = [math]::Round($overhangTicks * 100L / $runInfo.Length.Ticks)
    #Write-Host "Overhang is $(([timespan] $overhangTicks).ToString("c")), which is $percentOverhang % of $($runInfo.TimeInfo)"

    # Sometimes a run lasts only a short while.
    # An original subtitle might have padded things up to 5 seconds, so be more lenient.
    if ([timespan]::FromSeconds(2) -gt $runInfo.Length -and $overhangTicks -lt [timespan]::FromSeconds(3).Ticks) {
        return $true
    }
    if ([timespan]::FromSeconds(10) -gt $runInfo.Length -and $overhangTicks -lt [timespan]::FromSeconds(5).Ticks) {
        return $true
    }

    # Final attempt to salvage things: reasonably short run and the overlap is less than 25% of the offset value
    $halfOfOffset = [math]::Abs($runInfo.Offset.Ticks) / 4L
    if ([timespan]::FromSeconds(30) -gt $runInfo.Length -and $overhangTicks -lt $halfOfOffset) {
        return $true
    }

    return $false
}


# Reads a subtitle file and immediately offsets the timestamps. The file's new content is returned as a string.
function Read-OffsetSubtitles([string] $file, [timespan] $offset) {
    $file = Resolve-Path $file
    $result = New-Object System.Text.StringBuilder
    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader -ArgumentList @($file, [System.Text.Encoding]::UTF8)
        $line = $reader.ReadLine()
        while ($null -ne $line)
        {
            if ($line -ilike "* --> *") {
                $parts = $line -split " "
                $startOffset = [datetime]::ParseExact($parts[0], 'HH:mm:ss,fff', $null)
                $endOffset = [datetime]::ParseExact($parts[2], 'HH:mm:ss,fff', $null)
                $line = ($startOffset.Add($offset).ToString("HH:mm:ss,fff")) + " --> " +
                    ($endOffset.Add($offset).ToString("HH:mm:ss,fff"))
            }
            $result.AppendLine($line) > $null
            $line = $reader.ReadLine()
        }
    } finally {
        if ($null -ne $reader) {
            $reader.Close()
        }
    }
    # Chop off last line break character(s)
    $lineBreakLength = [environment]::NewLine.Length
    if ($result.Length -gt $lineBreakLength) {
        $result.Length -= $lineBreakLength
    }
    $result.ToString()
}

#######################################################################################################################
#######################################################################################################################
####  Script logic
#######################################################################################################################
#######################################################################################################################

$index = Read-Index $indexFile

if ($Reverse) {
    $index = Convert-IndexToFaneditTime $index
}
#$index | ForEach-Object {
#    Write-Host "Index $_ - $($_.TimeInfo)"
#}

if ($runs) {
    #$runs = $runs | Foreach-Object { [int]$_ }
    # Filter index intervals to just those which we need to operate on
    $index = $index | Where-Object { $_.Run -in $runs }
}


# Check how many files have subtitles which are not in the expected range
$numberOfFilesOutsideRun = 0
# Number of non-empty files
$numberOfFiles = 0
foreach ($runInfo in $index) {
    $runFileName = "{0}.srt" -f $runInfo.Run
    $runFile = Join-Path "." -ChildPath $runFileName
    if (! (Test-Path -PathType Leaf -Path $runFile)) {
        Write-Warning "Subtitle run '$runFile' file not found"
        continue;
    }
    $first, $last = Read-FirstAndLastSubtitle $runFile
    if (! $last) {
        Write-Warning "Subtitle run '$runFile' is empty, nothing to offset"
        continue;
    }
    $numberOfFiles++
    # Check to see if offsetting subtitle file would make things fall outside the expected interval from the index.
    # This stops us from accidentally offsetting a file twice when using an in-place transform or using reverse mode incorrectly.
    if (! (Test-SubtitlesWithinRun $first $last $runInfo)) {
        Write-Warning "File '$runFile' has timestamps outside expected $($runInfo.TimeInfo)"
        $numberOfFilesOutsideRun++
    }
}

if ($numberOfFilesOutsideRun -gt 0) {
    if ( -not ($PSCmdlet.ShouldProcess("$numberOfFilesOutsideRun files which appear to be already processed"))) {
        exit
    }
}

foreach ($runInfo in $index) {
    $runFileName = "{0}.srt" -f $runInfo.Run
    $runFile = Join-Path "." -ChildPath $runFileName
    if (! (Test-Path -PathType Leaf -Path $runFile)) {
        continue;
    }

    # Offset the file by tweaking its timestamps, either writing to a new file or in-place
    $destinationFile = $runFile
    if ($outputDir) {
        $destinationFile = Join-Path $outputDir -ChildPath $runFileName
    }
    $offset = $runInfo.Offset
    if ($Reverse) {
        $offset = $offset.Negate()
    }
    $updatedFile = Read-OffsetSubtitles $runFile $offset
    Set-Content -Encoding UTF8 $destinationFile -Value $updatedFile

    Write-Host "Wrote subtitles to $destinationFile shifted by $offset"
}
