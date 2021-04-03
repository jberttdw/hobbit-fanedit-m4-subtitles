
Add-Type -TypeDefinition @"
using System;
using System.Globalization;
public struct RunInfo {
    private int _id;
    private string _run;
    private int _film;
    private bool _extended;
    private bool _canBeEmpty;
    private DateTime _start;
    private DateTime _end;
    private TimeSpan _offset;
    private string _sourceFile;

    public RunInfo(int id, string run, int film, bool extended, string canBeEmpty, string start, string end, string offset) {
        _id = id; _run = run; _film = film; _extended = extended;
         _canBeEmpty = Boolean.Parse(canBeEmpty);
        _start = DateTime.ParseExact(start, "hh:mm:ss,fff", CultureInfo.InvariantCulture);
        _end = DateTime.ParseExact(end, "hh:mm:ss,fff", CultureInfo.InvariantCulture);

        bool negativeOffset = offset.StartsWith("-");
        if (negativeOffset) {
            offset = offset.Substring(1);
        }
        _offset = TimeSpan.ParseExact(offset, "hh\\:mm\\:ss\\,fff", CultureInfo.InvariantCulture);
        if (negativeOffset) {
            _offset = _offset.Negate();
        }
        _sourceFile = null;
    }

    /// <summary>Copy constructor</summary>
    private RunInfo(int id, string run, int film, bool extended, bool canBeEmpty, DateTime start, DateTime end, TimeSpan offset, string sourceFile) {
        _id = id; _run = run; _film = film; _extended = extended; _canBeEmpty = canBeEmpty; _start = start; _end = end; _offset = offset;
        _sourceFile = sourceFile;
    }

    public int Id { get { return _id; } }
    public string Run { get { return _run; } }
    public int Film { get { return _film; } }
    public bool Extended { get { return _extended; } }
    public bool CanBeEmpty { get { return _canBeEmpty; } }
    public DateTime Start { get { return _start; } }
    public DateTime End { get { return _end; } }
    public TimeSpan Offset { get { return _offset; } }
    public string SourceFile { get { return _sourceFile; } }

    public void PickSourceFile(string srtFilm1Normal, string srtFilm1Extended, string srtFilm2Normal,
                                string srtFilm2Extended, string srtFilm3Normal, string srtFilm3Extended)
    {
        if (Film == 1 && Extended) {
            _sourceFile = srtFilm1Extended;
        } else if (Film == 1) {
            _sourceFile = srtFilm1Normal;
        } else if (Film == 2 && Extended) {
            _sourceFile = srtFilm2Extended;
        } else if (Film == 2) {
            _sourceFile = srtFilm2Normal;
        } else if (Film == 3 && Extended) {
            _sourceFile = srtFilm3Extended;
        } else if (Film == 3) {
            _sourceFile = srtFilm3Normal;
        } else {
            throw new Exception("Film: " + Film + ", Ext: " + Extended + " did not match anything");
        }
    }

    public RunInfo ChangeInterval(DateTime start, DateTime end) {
        return new RunInfo(_id, _run, _film, _extended, _canBeEmpty, start, end, _offset, _sourceFile);
    }

    public override string ToString() {
        return Run;
    }
}
"@

function Read-Index {
    param(
        $indexFile
    )
    $index = Get-Content -Encoding UTF8 $indexFile -Raw | ConvertFrom-Csv -Delimiter `t

    $indexItems = $index | ForEach-Object {
        New-Object -TypeName RunInfo -ArgumentList @([int]$_.Id, $_.Run, [int]$_.Film, ($_.Type -eq "EXT"),
                $_.CanBeEmpty, $_.Start, $_.End, $_.Diff)
    }
    $indexItems
}

# Reads the time offsets in an srt file and stores them in a subtitle PSObject
function Read-TimeOffsets {
    param(
        $line,
        $subtitle
    )
    $parts = $line -split " "
    $startOffset = [datetime]::ParseExact($parts[0], 'HH:mm:ss,fff', $null)
    $endOffset = [datetime]::ParseExact($parts[2], 'HH:mm:ss,fff', $null)
    $subtitle | Add-Member -NotePropertyMembers @{ Start = $startOffset; End = $endOffset } > $null
}

function Get-NextSubtitle ([System.IO.TextReader] $reader) {
    $nextRealLineIsNumber = $true
    $nextSubtitle = $null
    $line = $reader.ReadLine()
    while ($null -ne $line)
    {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($nextSubtitle) {
                return $nextSubtitle
            }
            $nextRealLineIsNumber = $true
        } elseif ($nextRealLineIsNumber) {
            $nextRealLineIsNumber = $false
            $nextSubtitle = New-Object PSObject -Property @{ Number = [int]$line }
            $nextSubtitle | Add-Member -Name "Text" -Value "" -MemberType NoteProperty > $null
        } elseif ($line -ilike "* --> *") {
            Read-TimeOffsets $line $nextSubtitle
        } else {
            # We read a line before - add newlines in between
            if ($nextSubtitle.Text) {
                $nextSubtitle.Text += "`r`n" + $line
            } else {
                $nextSubtitle.Text = $line
            }
        }
        $line = $reader.ReadLine()
    }
}

function Write-Subtitles ($subtitles, $fileName) {
    if ($subtitles.Count -le 0) {
        return
    }
    try {
        $encoding = [System.Text.Encoding]::UTF8
        $outputStream = New-Object -TypeName "System.IO.StreamWriter" -ArgumentList ($fileName, $false, $encoding)

        $subtitle = $subtitles[0]
        $outputStream.WriteLine($subtitle.Number)
        $outputStream.Write(($subtitle.Start | Get-Date -Format "HH:mm:ss,fff"))
        $outputStream.Write(" --> ")
        $outputStream.WriteLine(($subtitle.End | Get-Date -Format "HH:mm:ss,fff"))
        $outputStream.WriteLine($subtitle.Text)
        for ($i = 1; $i -lt $subtitles.Count; $i++) {
            $subtitle = $subtitles[$i]
            $outputStream.WriteLine()
            $outputStream.WriteLine($subtitle.Number)
            $outputStream.Write(($subtitle.Start | Get-Date -Format "HH:mm:ss,fff"))
            $outputStream.Write(" --> ")
            $outputStream.WriteLine(($subtitle.End | Get-Date -Format "HH:mm:ss,fff"))
            $outputStream.WriteLine($subtitle.Text)
        }
    } finally {
        if ($null -ne $outputStream) {
            $outputStream.Close()
        }
    }
}

Export-ModuleMember -Function Read-Index, Get-NextSubtitle, Write-Subtitles