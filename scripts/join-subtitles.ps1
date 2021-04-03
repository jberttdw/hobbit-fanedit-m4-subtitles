# Picks up all srt files in the current directory and joins them to create a new srt file in the parent directory.
# This new file will by default be called test-all-<date>.srt

[CmdletBinding()]
param (
    # Path to which to write the final result. Defaults to "..\output-{lang}-{date}.srt"
    [parameter()]
    [string] $outputFile,
    # Path to the index file, used to build "debug" SRT files
    [parameter()]
    [string] $indexFile,
    # If true, the sequence identifiers will be of the format xxx0yy where 'x' stands for the run number and y for the original sequence id (starting from 1).
    # The default filename will also be changed to start with "debug".
    [parameter()]
    [switch]
    [bool] $debugId,
    # Whether the end user needs to confirm that the outputfile can be overwritten. Defaults to true.
    [switch] $Confirm = $true
)

Import-Module (Join-Path $PSScriptRoot "subtitle-helpers.psm1")

$subtitleFiles = Get-ChildItem "*.srt" | Sort-Object -Property Name

$currentDateTime = Get-Date -Format "yyyy-MM-dd HH-mm"
$currentLangFolder = Split-Path -Leaf "."

$index = @()

if ($debugId) {
    if (-not $indexFile -or -not (Test-Path $indexFile)) {
        throw "Index file [$indexFile] not found"
    }
    $indexFile = Resolve-Path $indexFile
    $index = Read-Index $indexFile
}

if (-not ($outputFile) -and $debugId) {
    $outputFile = Join-Path (Resolve-Path "..") ("debug-{0}-{1}.srt" -f $currentLangFolder, $currentDateTime)
} elseif (-not ($outputFile)) {
    $outputFile = Join-Path (Resolve-Path "..") ("output-{0}-{1}.srt" -f $currentLangFolder, $currentDateTime)
}

if ((Test-Path $outputFile) -and $Confirm) {
    Remove-Item -Confirm $outputFile
    if (Test-Path $outputFile) {
        throw "$outputFile already exists, need confirmation to continue"
    }
}

function Process-SubRipFile {
    param (
        $fileId,
        $inputFile,
        $outputStream,
        $debugId,
        $lastNumber
    )
    $lines = Get-Content -Encoding UTF8 $inputFile

    if ($debugId) {
        $number = 0
        $sequenceFormat = "{1}{0:000}"
    } else {
        $number = $lastNumber
        $sequenceFormat = "{0}"
    }

    $nextRealLineIsNumber = $true
    foreach ($line in $lines)
    {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $nextRealLineIsNumber = $true
        } elseif ($nextRealLineIsNumber) {
            $outputStream.WriteLine()
            $number++
            $sequenceId = $sequenceFormat -f $number, $fileId
            $outputStream.WriteLine($sequenceId)
            $nextRealLineIsNumber = $false
        } else {
            $outputStream.WriteLine($line)
        }
    }
    # Return highest number till now so next invocation of this function can continue
    $number
}

try {
    $outputStream = [System.IO.StreamWriter] $outputFile

    $fileId = 1
    $highestNumber = 0
    
    foreach ($subtitleFile in $subtitleFiles) {
        if ($debugId) {
            $baseName = (Get-Item $subtitleFile).BaseName
            $runInfo = $index | Where-Object { $baseName -eq $_.Run }
            if ($null -eq $runInfo) {
                throw "Run $baseName not found in index"
            } elseif ($runInfo.Count -gt 1) {
                throw "Run $baseName found $($runInfo.Count) times?!?"
            }
            $fileId = $runInfo.Id
        }
        $highestNumber = Process-SubRipFile $fileId $subtitleFile $outputStream $debugId $highestNumber
        Write-Host "Processed run '$fileId' from file $subtitleFile"
    }
} finally {
    if ($null -ne $outputStream) {
        $outputStream.Close()
    }
}

Write-Host "Wrote $outputFile"
