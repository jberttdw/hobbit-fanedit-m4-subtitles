# Picks up all srt files in the current directory, opens each one and rnumbers all
# subtitles so the numbering in each file starts from 1
[CmdletBinding()]
param (
    # Patterns of files to look for - can be used to give just a handful of filenames
    [parameter()]
    [string[]] $patterns = "*.srt",
    # Whether we should use incrementing numbers, otherwise everything is reset to number 1 for easier diffing
    [parameter()]
    [switch]
    [bool] $unique
)

function Convert-SubRipFile {
    param (
        $file,
        $uniqueNumber
    )
    $lines = Get-Content -Encoding UTF8 $file
    $number = 1
    $nextRealLineIsNumber = $true
    foreach ($line in $lines)
    {
        if ([string]::IsNullOrWhiteSpace($line)) {
            Write-Output $line
            $nextRealLineIsNumber = $true
        } elseif ($nextRealLineIsNumber) {
            if ($uniqueNumber) {
                Write-Output $number
                $number++
            } else {
                Write-Output 1
            }
            $nextRealLineIsNumber = $false
        } else {
            Write-Output $line
        }
    }
}

$subtitleFiles = Get-ChildItem $patterns

$subtitleFiles | % { Convert-SubRipFile $_ $unique | Set-Content -Encoding UTF8 $_ ; Write-Host "Updated file $_" }
