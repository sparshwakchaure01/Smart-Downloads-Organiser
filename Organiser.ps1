<#
    Smart Downloads Organiser  (Windows 10/11, Windows PowerShell 5.1)
    Made by Sparsh

    SAFETY DESIGN (please keep these true if you change the code):
      * This script contains no command that deletes anything.
      * Files move only with [System.IO.File]::Move and folders with
        [System.IO.Directory]::Move. Both refuse to overwrite.
      * Only items sitting directly in the chosen folder are ever moved.
        Nothing is taken out of a sub-folder.
      * Every move is written to the log BEFORE and AFTER it happens.
      * Links, junctions, hidden/system files and unfinished downloads are skipped.

    Usage:
      Organiser.ps1                                 opens the window
      Organiser.ps1 -PreviewOnly                    preview in the console, moves nothing
      Organiser.ps1 -PreviewOnly -Folder "C:\Test"  preview another folder
      Organiser.ps1 -Undo                           choose a log and undo it
#>
[CmdletBinding()]
param(
    [switch]$PreviewOnly,
    [string]$Folder,
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
$script:AppDir = $PSScriptRoot.TrimEnd('\')
$script:LogBox = $null    # set when the window is open

# Top-level folders this tool creates. They are never scanned for moving again.
$script:OrganisedFolders = @('Documents','Images','Videos','Audio','Archives','Code','Installers',
    'Design Files','Spreadsheets','Presentations','Books','Misc','Projects','My Folders')

# The tool's own files (protected if someone copies them straight into Downloads)
$script:OwnNames = @('Organiser.bat','Organiser.ps1','Undo.bat','rules.json','rules.sample.json',
    'LICENSE','README.md','.gitignore','.gitattributes','docs','tests','Reports')

$script:IncompleteExt = @('.crdownload','.part','.tmp','.partial','.opdownload','.download','.aria2','.!ut')
$script:SystemNames   = @('desktop.ini','thumbs.db','.ds_store')

$script:ExtensionMap = @{}
function Add-Types([string]$Category, [string]$List) {
    foreach ($e in $List.Split(' ')) { $script:ExtensionMap[".$e"] = $Category }
}
Add-Types 'Documents'     'pdf doc docx odt rtf txt md tex pages'
Add-Types 'Images'        'jpg jpeg png gif bmp webp tif tiff heic heif svg ico avif raw cr2 nef'
Add-Types 'Videos'        'mp4 mkv avi mov wmv flv webm m4v mpg mpeg 3gp srt vtt'
Add-Types 'Audio'         'mp3 wav flac aac ogg m4a wma opus mid midi'
Add-Types 'Archives'      'zip rar 7z tar gz bz2 xz tgz iso'
Add-Types 'Code'          'py js ts jsx tsx java c cpp h hpp cs go rs rb php html htm css scss json xml yml yaml sql sh ps1 bat cmd ipynb kt swift r dart vue'
Add-Types 'Installers'    'exe msi msix msixbundle appx appxbundle apk dmg deb rpm pkg'
Add-Types 'Design Files'  'psd ai xd fig sketch indd cdr afdesign afphoto xcf blend dwg dxf stl obj fbx'
Add-Types 'Spreadsheets'  'xls xlsx xlsm xlsb ods csv tsv'
Add-Types 'Presentations' 'ppt pptx pps ppsx odp key'
Add-Types 'Books'         'epub mobi azw azw3 fb2 cbz cbr djvu'
Add-Types 'Misc'          'torrent ics vcf log ttf otf woff woff2'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Write-Status([string]$Text) {
    if ($script:LogBox) {
        $script:LogBox.AppendText($Text + [Environment]::NewLine)
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        Write-Host $Text
    }
}

function Test-ReparsePoint($Item) {
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-HiddenOrSystem($Item) {
    $mask = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    return (($Item.Attributes -band $mask) -ne 0)
}

# True when $Path is $Parent or lies inside it
function Test-IsInside([string]$Path, [string]$Parent) {
    $a = $Path.TrimEnd('\') + '\'
    $b = $Parent.TrimEnd('\') + '\'
    return $a.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-DownloadsPath {
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $value = (Get-ItemProperty -LiteralPath $key).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($value) {
            $path = [Environment]::ExpandEnvironmentVariables($value)
            if (Test-Path -LiteralPath $path -PathType Container) { return $path }
        }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# Validate the folder to organise. Throws a friendly message if it is unsafe.
function Resolve-TargetFolder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    if ($full.Length -le 2 -or $full -eq [System.IO.Path]::GetPathRoot($full + '\').TrimEnd('\')) {
        throw "Refusing to organise a whole drive: $Path"
    }
    foreach ($bad in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($bad -and (Test-IsInside $full $bad)) { throw "Refusing to organise a Windows system folder: $full" }
    }
    if ($env:USERPROFILE -and (Test-IsInside $env:USERPROFILE $full)) {
        throw "Refusing to organise your whole user profile. Choose Downloads or a folder inside it."
    }
    if (Test-Path -LiteralPath (Join-Path $full '.git')) {
        throw "This folder is a Git repository. Organising it would break the project."
    }
    return $full
}

# Reports live next to the program; if that is read-only, use Documents instead.
function Get-ReportDir {
    $dir = Join-Path $script:AppDir 'Reports'
    try {
        [void][System.IO.Directory]::CreateDirectory($dir)
        $probe = Join-Path $dir 'write-test.txt'
        [System.IO.File]::WriteAllText($probe, 'This file only checks that reports can be saved here.')
        return $dir
    } catch {
        $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SmartDownloadsOrganiser\Reports'
        [void][System.IO.Directory]::CreateDirectory($dir)
        return $dir
    }
}

function ConvertTo-CsvLine([object[]]$Values) {
    $cells = foreach ($v in $Values) { '"' + ([string]$v).Replace('"', '""') + '"' }
    return ($cells -join ',')
}

# A path that does not exist yet: "name.ext", "name (2).ext", "name (3).ext" ...
function Get-FreePath([string]$Directory, [string]$Name, [bool]$IsFolder, $Reserved) {
    if ($IsFolder) { $base = $Name; $ext = '' }
    else {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
        $ext  = [System.IO.Path]::GetExtension($Name)
        if (-not $base) { $base = $Name; $ext = '' }
    }
    $candidate = Join-Path $Directory $Name
    $n = 2
    while ([System.IO.File]::Exists($candidate) -or [System.IO.Directory]::Exists($candidate) -or
           ($null -ne $Reserved -and $Reserved.Contains($candidate))) {
        $candidate = Join-Path $Directory ("{0} ({1}){2}" -f $base, $n, $ext)
        $n++
        if ($n -gt 9999) { throw "Too many files named $Name" }
    }
    if ($null -ne $Reserved) { [void]$Reserved.Add($candidate) }
    return $candidate
}

# ---------------------------------------------------------------------------
# Optional user rules
# ---------------------------------------------------------------------------
function Get-UserRules {
    $file = Join-Path $script:AppDir 'rules.json'
    $rules = @()
    if (-not (Test-Path -LiteralPath $file)) { return $rules }
    try {
        $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in $json.rules) {
            # one safe folder name only: no paths, no "..", no reserved characters
            $name = ([string]$r.folder).Trim()
            if (-not $name -or $name -match '[\\/:*?"<>|]' -or $name.EndsWith('.')) {
                Write-Status "rules.json: ignored unsafe folder name '$name'"
                continue
            }
            $words = @($r.keywords | Where-Object { ([string]$_).Trim().Length -ge 2 })
            if ($words.Count -gt 0) { $rules += New-Object PSObject -Property @{ Folder = $name; Keywords = $words } }
        }
    } catch {
        Write-Status "rules.json could not be read and was ignored: $($_.Exception.Message)"
    }
    return $rules
}

# Returns the rule folder when a keyword appears in the name, otherwise $null
function Find-UserRule([string]$Name, $Rules) {
    foreach ($r in $Rules) {
        foreach ($word in $r.Keywords) {
            if ($Name.IndexOf([string]$word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $r.Folder }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Smart detection
# ---------------------------------------------------------------------------
# Read a little text from a document, read-only. Any problem returns ''.
function Get-TextPeek($File) {
    $limit = 20000
    $ext = $File.Extension.ToLowerInvariant()
    # do not trigger a download of cloud-only (offline) files
    if (($File.Attributes -band [System.IO.FileAttributes]::Offline) -ne 0) { return '' }
    $stream = $null; $zip = $null
    try {
        if (@('.txt','.md','.csv','.docx','.pptx') -notcontains $ext) { return '' }
        $stream = New-Object System.IO.FileStream($File.FullName, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $buffer = New-Object char[] $limit
        if (@('.txt','.md','.csv') -contains $ext) {
            $reader = New-Object System.IO.StreamReader($stream)
            $count = $reader.ReadBlock($buffer, 0, $limit)
            return (New-Object string($buffer, 0, $count))
        }
        $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read)
        $text = ''
        $parts = @($zip.Entries | Where-Object { $_.FullName -match '^(word/document|ppt/slides/slide\d+)\.xml$' } | Select-Object -First 5)
        foreach ($part in $parts) {
            $reader = New-Object System.IO.StreamReader($part.Open())
            $count = $reader.ReadBlock($buffer, 0, $limit)
            $reader.Dispose()
            $xml = New-Object string($buffer, 0, $count)
            # paragraph ends become spaces; other tags vanish so split words rejoin
            $text += ' ' + (($xml -replace '</(w|a):p>', ' ') -replace '<[^>]+>', '')
        }
        return $text
    } catch {
        return ''
    } finally {
        if ($zip) { $zip.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Measure-Hits([string]$Text, [string[]]$Patterns) {
    $n = 0
    foreach ($p in $Patterns) { if ($Text -match $p) { $n++ } }
    return $n
}

# Returns a topic (Resumes, Certificates, ...) or $null. Name first, then content.
# Content needs several different clues, so one stray word is never enough.
function Get-Topic($File) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $name = ($name -creplace '([a-z])([A-Z])', '$1 $2').ToLowerInvariant()
    $name = ($name -replace '[_\-\.\+\(\)\[\]]+', ' ')

    if ($name -match '\b(resume|curriculum vitae|cv)\b') { return 'Resumes' }
    if ($name -match '\b(certificate|certification|marksheet|mark sheet)\b') { return 'Certificates' }
    if ($name -match '\b(invoice|receipt)\b') { return 'Invoices and Receipts' }
    if ($name -match '\b(assignment|syllabus|lecture|semester|sem ?\d|homework|lab manual|question paper|coursework|hall ticket)\b') { return 'Course Material' }

    $text = Get-TextPeek $File
    if (-not $text) { return $null }
    if ((Measure-Hits $text @('curriculum vitae','work experience','\beducation\b','\bskills\b','career objective','linkedin')) -ge 3) { return 'Resumes' }
    if ($text -match 'this is to certify|certificate of (completion|achievement|participation|appreciation)') { return 'Certificates' }
    if ((Measure-Hits $text @('invoice (no|number|date)','amount (due|paid)','bill(ed)? to','\bgstin\b','\bsubtotal\b','tax invoice')) -ge 2) { return 'Invoices and Receipts' }
    if ((Measure-Hits $text @('\bassignment\b','\bsemester\b','\bsyllabus\b','submitted (by|to)','course code','\blecture\b')) -ge 2) { return 'Course Material' }
    return $null
}

function Get-InstallerKind([string]$Name) {
    if ($Name -match '(?i)(driver|nvidia|geforce|radeon|realtek|chipset|intel[\-_ ]|bluetooth|wlan|synaptics)') { return 'Drivers' }
    if ($Name -match '(?i)(^git[\-_ ]|python|node-|nodejs|jdk|jre|vscode|vscodesetup|visualstudio|vs_|docker|postman|mysql|postgres|mongodb|android-studio|intellij|pycharm|cmake|mingw|rustup|golang|^go\d|dotnet|putty|winscp|wireshark|xampp|anaconda|miniconda)') { return 'Dev tools' }
    return 'Apps'
}

# Decide where one file goes. Returns a path relative to the root, or $null (NOT SURE).
function Get-FileDestination($File, $Context) {
    $ext = $File.Extension.ToLowerInvariant()
    $rule = Find-UserRule $File.Name $Context.Rules
    if ($rule) { return @{ Folder = "My Folders\$rule"; Reason = 'Your rules.json' } }

    $category = $script:ExtensionMap[$ext]
    if (-not $category) { return @{ Folder = $null; Reason = 'Unknown file type' } }

    # Files that belong together: moving only some of them would break them
    if ($Context.HasLooseSite -and @('.html','.htm','.css','.js') -contains $ext) {
        return @{ Folder = $null; Reason = 'Looks like part of a loose website (index.html is here)' }
    }
    if (@('.html','.htm') -contains $ext) {
        $companion = Join-Path $Context.Root ([System.IO.Path]::GetFileNameWithoutExtension($File.Name) + '_files')
        if ([System.IO.Directory]::Exists($companion)) { return @{ Folder = $null; Reason = 'Saved web page with a _files folder' } }
    }
    if ($ext -eq '.exe' -and $Context.HasDll) {
        return @{ Folder = $null; Reason = 'Program may need the .dll files beside it' }
    }
    if ($ext -eq '.zip' -and [System.IO.File]::Exists([System.IO.Path]::ChangeExtension($File.FullName, '.z01'))) {
        return @{ Folder = $null; Reason = 'Part of a split archive' }
    }

    if ($category -eq 'Installers') {
        return @{ Folder = "Installers\$(Get-InstallerKind $File.Name)"; Reason = 'Installer' }
    }
    if ($category -eq 'Images') {
        if ($File.Name -match '(?i)^(screenshot|screen shot|screen_shot|screen-shot|snip)') {
            return @{ Folder = 'Images\Screenshots'; Reason = 'Screenshot name' }
        }
        if ($File.Name -match '(?i)(wallpaper|wallhaven)') { return @{ Folder = 'Images\Wallpapers'; Reason = 'Wallpaper name' } }
    }
    if (@('Documents','Images','Spreadsheets','Presentations') -contains $category) {
        $topic = Get-Topic $File
        if ($topic) {
            # scanned certificates and receipts saved as pictures count as documents
            $parent = $category
            if ($category -eq 'Images') {
                if (@('Certificates','Invoices and Receipts') -notcontains $topic) { return @{ Folder = 'Images'; Reason = 'Image' } }
                $parent = 'Documents'
            }
            return @{ Folder = "$parent\$topic"; Reason = "Detected: $topic" }
        }
    }
    return @{ Folder = $category; Reason = "File type $ext" }
}

# Is this folder a code project? Returns the marker found, or $null.
# Also looks through single wrapper folders (app-main\app-main\package.json).
function Get-ProjectMarker([string]$Path) {
    $current = $Path
    for ($depth = 0; $depth -le 2; $depth++) {
        $items = @((New-Object System.IO.DirectoryInfo($current)).GetFileSystemInfos())
        foreach ($i in $items) {
            if ($i.Name -match '^(package\.json|index\.html|requirements\.txt|\.git|pom\.xml|main\.py|pyproject\.toml|Cargo\.toml|go\.mod|build\.gradle|.+\.sln|.+\.csproj)$') {
                return $i.Name
            }
        }
        if ($items.Count -ne 1 -or -not ($items[0] -is [System.IO.DirectoryInfo]) -or (Test-ReparsePoint $items[0])) { break }
        $current = $items[0].FullName
    }
    return $null
}

# "App (1)", "app-main", "app-final", "app copy" all give the key "app"
function Get-VersionKey([string]$Name) {
    $key = $Name.ToLowerInvariant().Trim()
    do {
        $before = $key
        $key = $key -replace '\s*\(\d+\)$', ''
        $key = $key -replace '[\s_\-\.]+(main|master|final|copy|old|new|latest|backup|bak|updated|fixed|v\d+(\.\d+)*|\d+)$', ''
        $key = $key.Trim(' ', '-', '_', '.')
    } while ($key -ne $before -and $key)
    if (-not $key) { return $Name.ToLowerInvariant() }
    return ($key -replace '[\s_\-]+', '-')
}

# ---------------------------------------------------------------------------
# Scan (moves nothing)
# ---------------------------------------------------------------------------
function Get-Plan([string]$Root) {
    Add-Type -AssemblyName System.IO.Compression
    $rules = @(Get-UserRules)
    $items = @((New-Object System.IO.DirectoryInfo($Root)).GetFileSystemInfos() | Sort-Object Name)

    $context = @{
        Root         = $Root
        Rules        = $rules
        HasLooseSite = [System.IO.File]::Exists((Join-Path $Root 'index.html'))
        HasDll       = @($items | Where-Object { $_.Extension -eq '.dll' }).Count -gt 0
    }
    $reserved = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $moves = New-Object System.Collections.ArrayList
    $unsure = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    $projects = New-Object System.Collections.ArrayList
    $folderKeys = @{}   # version key -> folder names (for the "related" report)

    $number = 0
    foreach ($item in $items) {
        $number++
        if ($number % 25 -eq 0) { Write-Status "  scanned $number of $($items.Count)..." }
        $isFolder = $item -is [System.IO.DirectoryInfo]
        try {
            $skip = $null
            if ($item.Name.EndsWith('.') -or $item.Name.EndsWith(' ')) { $skip = 'Unusual name ending in dot or space' }
            elseif (Test-ReparsePoint $item) { $skip = 'Link, junction or cloud placeholder' }
            elseif (Test-IsInside $script:AppDir $item.FullName) { $skip = 'The organiser itself' }
            elseif ($script:AppDir -eq $Root -and $script:OwnNames -contains $item.Name) { $skip = 'Organiser file' }
            elseif ($isFolder -and $script:OrganisedFolders -contains $item.Name) { $skip = 'Already-organised folder' }
            elseif ($script:SystemNames -contains $item.Name -or (Test-HiddenOrSystem $item)) { $skip = 'Hidden or system item' }
            elseif (-not $isFolder) {
                if ($script:IncompleteExt -contains $item.Extension.ToLowerInvariant()) { $skip = 'Unfinished or temporary download' }
                elseif ([System.IO.File]::Exists($item.FullName + '.part')) { $skip = 'Still downloading' }
                elseif ($item.Name.StartsWith('~$')) { $skip = 'Office lock file' }
                elseif ($item.Name -like 'Smart-Downloads-Organiser*.zip') { $skip = 'The organiser download' }
            }
            if ($skip) {
                [void]$skipped.Add((New-Object PSObject -Property @{ Path = $item.FullName; Reason = $skip }))
                continue
            }

            if ($isFolder) {
                $key = Get-VersionKey $item.Name
                if (-not $folderKeys.ContainsKey($key)) { $folderKeys[$key] = @() }
                $folderKeys[$key] += $item.Name

                $unfinished = @($item.GetFiles() | Where-Object { $script:IncompleteExt -contains $_.Extension.ToLowerInvariant() -and $_.Extension -ne '.tmp' })
                if ($unfinished.Count -gt 0) {
                    [void]$unsure.Add((New-Object PSObject -Property @{ Path = $item.FullName; Reason = 'Folder contains an unfinished download' }))
                    continue
                }
                $rule = Find-UserRule $item.Name $rules
                $marker = $null
                if (-not $rule) { $marker = Get-ProjectMarker $item.FullName }
                if ($rule) {
                    $dest = Get-FreePath (Join-Path $Root "My Folders\$rule") $item.Name $true $reserved
                    [void]$moves.Add((New-Object PSObject -Property @{ Source = $item.FullName; Target = $dest; Type = 'Folder'; Size = 0; Reason = 'Your rules.json' }))
                } elseif ($marker) {
                    [void]$projects.Add((New-Object PSObject -Property @{ Item = $item; Key = $key; Marker = $marker }))
                } else {
                    [void]$unsure.Add((New-Object PSObject -Property @{ Path = $item.FullName; Reason = 'Folder with no project markers' }))
                }
            } else {
                $d = Get-FileDestination $item $context
                if ($d.Folder) {
                    $dest = Get-FreePath (Join-Path $Root $d.Folder) $item.Name $false $reserved
                    [void]$moves.Add((New-Object PSObject -Property @{ Source = $item.FullName; Target = $dest; Type = 'File'; Size = $item.Length; Reason = $d.Reason }))
                } else {
                    [void]$unsure.Add((New-Object PSObject -Property @{ Path = $item.FullName; Reason = $d.Reason }))
                }
            }
        } catch {
            [void]$unsure.Add((New-Object PSObject -Property @{ Path = (Join-Path $Root $item.Name); Reason = "Could not read: $($_.Exception.Message)" }))
        }
    }

    # Projects: versions of the same project share a "(versions)" folder, each kept separate
    foreach ($p in $projects) {
        $same = @($projects | Where-Object { $_.Key -eq $p.Key }).Count
        $groupName = "$($p.Key) (versions)"
        $projectRoot = Join-Path $Root 'Projects'
        $hasGroup = [System.IO.Directory]::Exists((Join-Path $projectRoot $groupName))
        $hasEarlier = $false
        if ([System.IO.Directory]::Exists($projectRoot)) {
            $hasEarlier = @([System.IO.Directory]::GetDirectories($projectRoot) | Where-Object { (Get-VersionKey ([System.IO.Path]::GetFileName($_))) -eq $p.Key }).Count -gt 0
        }
        $parent = $projectRoot
        if ($same -gt 1 -or $hasGroup -or $hasEarlier) { $parent = Join-Path $projectRoot $groupName }
        $dest = Get-FreePath $parent $p.Item.Name $true $reserved
        [void]$moves.Add((New-Object PSObject -Property @{ Source = $p.Item.FullName; Target = $dest; Type = 'Folder'; Size = 0; Reason = "Code project ($($p.Marker))" }))
    }

    $related = @()
    foreach ($key in $folderKeys.Keys) {
        if ($folderKeys[$key].Count -gt 1) { $related += "$key : $($folderKeys[$key] -join ' | ')" }
    }

    return New-Object PSObject -Property @{
        Root = $Root; Moves = $moves; Unsure = $unsure; Skipped = $skipped; Related = $related
    }
}

# Duplicates: group by size first, then confirm with SHA256. Report only.
function Find-Duplicates($Plan) {
    $files = New-Object System.Collections.ArrayList
    foreach ($m in $Plan.Moves) { if ($m.Type -eq 'File') { [void]$files.Add((New-Object System.IO.FileInfo($m.Source))) } }
    foreach ($u in $Plan.Unsure) { if ([System.IO.File]::Exists($u.Path)) { [void]$files.Add((New-Object System.IO.FileInfo($u.Path))) } }

    # also compare with files organised on earlier runs (Projects are left out)
    $queue = New-Object System.Collections.Queue
    foreach ($name in $script:OrganisedFolders) {
        $dir = Join-Path $Plan.Root $name
        if ($name -ne 'Projects' -and [System.IO.Directory]::Exists($dir)) { $queue.Enqueue((New-Object System.IO.DirectoryInfo($dir))) }
    }
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        if (Test-ReparsePoint $dir) { continue }
        # folders moved whole by rules.json may be projects; links are never followed
        try {
            foreach ($child in $dir.GetFileSystemInfos()) {
                if (Test-ReparsePoint $child) { continue }
                if ($child -is [System.IO.DirectoryInfo]) { $queue.Enqueue($child) }
                elseif (-not (Test-HiddenOrSystem $child)) { [void]$files.Add($child) }
            }
        } catch { }
    }

    $rows = @(); $group = 0
    $sameSize = @($files | Where-Object { $_.Length -gt 0 } | Group-Object Length | Where-Object { $_.Count -gt 1 })
    foreach ($s in $sameSize) {
        $hashed = foreach ($f in $s.Group) {
            try { New-Object PSObject -Property @{ Path = $f.FullName; Size = $f.Length; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } } catch { }
            if ($script:LogBox) { [System.Windows.Forms.Application]::DoEvents() }
        }
        foreach ($h in @($hashed | Group-Object Hash | Where-Object { $_.Count -gt 1 })) {
            $group++
            foreach ($f in $h.Group) { $rows += New-Object PSObject -Property @{ Group = $group; Size = $f.Size; SHA256 = $f.Hash; Path = $f.Path } }
        }
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Preview reports
# ---------------------------------------------------------------------------
function Get-PlanSummary($Plan, $Duplicates, [bool]$Full) {
    $lines = @('Smart Downloads Organiser - made by Sparsh',
        "Folder: $($Plan.Root)",
        "To move: $($Plan.Moves.Count)   NOT SURE (stay): $($Plan.Unsure.Count)   Skipped: $($Plan.Skipped.Count)   Duplicate files: $(@($Duplicates).Count)",
        '', 'PROPOSED FOLDERS')
    $prefix = $Plan.Root.Length + 1
    $groups = @($Plan.Moves | Group-Object { [System.IO.Path]::GetDirectoryName($_.Target).Substring($prefix) } | Sort-Object Name)
    foreach ($g in $groups) { $lines += "  $($g.Name)\  ($($g.Count) item(s))" }
    if (-not $Full) { return $lines }

    $lines += '', 'MOVES (original -> proposed)'
    foreach ($m in $Plan.Moves) { $lines += "  $($m.Source.Substring($prefix))  ->  $($m.Target.Substring($prefix))   [$($m.Reason)]" }
    $lines += '', 'NOT SURE (these stay where they are)'
    foreach ($u in $Plan.Unsure) { $lines += "  $($u.Path.Substring($prefix))   [$($u.Reason)]" }
    $lines += '', 'RELATED / REPEATED FOLDERS'
    foreach ($r in $Plan.Related) { $lines += "  $r" }
    $lines += '', 'DUPLICATES (reported only, nothing is removed)'
    foreach ($d in @($Duplicates)) { $lines += "  group $($d.Group): $($d.Path.Substring($prefix))" }
    $lines += '', 'SKIPPED'
    foreach ($s in $Plan.Skipped) { $lines += "  $($s.Path.Substring($prefix))   [$($s.Reason)]" }
    return $lines
}

function Invoke-Scan([string]$Root, [bool]$Full) {
    Write-Status "Scanning $Root (nothing will be moved)..."
    $plan = Get-Plan $Root
    Write-Status 'Checking for duplicates...'
    $duplicates = @(Find-Duplicates $plan)

    $dir = Get-ReportDir
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $utf8 = New-Object System.Text.UTF8Encoding($true)

    $preview = @(ConvertTo-CsvLine @('Status','Type','OriginalPath','ProposedPath','Reason'))
    foreach ($m in $plan.Moves)   { $preview += ConvertTo-CsvLine @('MOVE', $m.Type, $m.Source, $m.Target, $m.Reason) }
    foreach ($u in $plan.Unsure)  { $preview += ConvertTo-CsvLine @('NOT SURE', '', $u.Path, '', $u.Reason) }
    foreach ($s in $plan.Skipped) { $preview += ConvertTo-CsvLine @('SKIPPED', '', $s.Path, '', $s.Reason) }
    [System.IO.File]::WriteAllLines((Join-Path $dir "Preview_$stamp.csv"), [string[]]$preview, $utf8)

    $dupLines = @(ConvertTo-CsvLine @('Group','SizeBytes','SHA256','Path'))
    foreach ($d in $duplicates) { $dupLines += ConvertTo-CsvLine @($d.Group, $d.Size, $d.SHA256, $d.Path) }
    [System.IO.File]::WriteAllLines((Join-Path $dir "Duplicates_$stamp.csv"), [string[]]$dupLines, $utf8)

    [System.IO.File]::WriteAllLines((Join-Path $dir "Summary_$stamp.txt"), [string[]](Get-PlanSummary $plan $duplicates $true), $utf8)

    foreach ($line in (Get-PlanSummary $plan $duplicates $Full)) { Write-Status $line }
    Write-Status "Reports saved in: $dir"
    return $plan
}

# ---------------------------------------------------------------------------
# Moving (used by Organise and Undo)
# ---------------------------------------------------------------------------
# Refuse to move through a link/junction anywhere between the root and the target
function Assert-NoLinks([string]$Directory, [string]$Root) {
    $current = $Directory
    while ($current -and $current.Length -gt $Root.Length) {
        if ([System.IO.Directory]::Exists($current) -and (Test-ReparsePoint (New-Object System.IO.DirectoryInfo($current)))) {
            throw "Folder is a link or junction: $current"
        }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
}

# Move one item and verify the result. Throws on any problem.
function Move-Safely([string]$Source, [string]$Target, [string]$Type, [string]$Root) {
    if (-not (Test-IsInside $Source $Root) -or -not (Test-IsInside $Target $Root)) { throw 'Path is outside the chosen folder' }
    if ($Type -eq 'Folder' -and (Test-IsInside $Target $Source)) { throw 'A folder cannot be moved into itself' }
    $parent = [System.IO.Path]::GetDirectoryName($Target)
    Assert-NoLinks $parent $Root
    [void][System.IO.Directory]::CreateDirectory($parent)

    if ($Type -eq 'Folder') {
        [System.IO.Directory]::Move($Source, $Target)
        if (-not [System.IO.Directory]::Exists($Target) -or [System.IO.Directory]::Exists($Source)) { throw 'Verification failed' }
    } else {
        $size = (New-Object System.IO.FileInfo($Source)).Length
        [System.IO.File]::Move($Source, $Target)
        if (-not [System.IO.File]::Exists($Target) -or [System.IO.File]::Exists($Source)) { throw 'Verification failed' }
        if ((New-Object System.IO.FileInfo($Target)).Length -ne $size) { throw 'Verification failed: size changed' }
    }
}

function Add-LogRow([string]$LogFile, [string]$Result, $Move, [string]$Target, [string]$Message) {
    $line = ConvertTo-CsvLine @((Get-Date -Format 's'), $Result, $Move.Type, $Move.Size, $Move.Root, $Move.Source, $Target, $Message)
    [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

function New-Log([string]$Prefix) {
    $file = Join-Path (Get-ReportDir) ("{0}_{1}.csv" -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $header = ConvertTo-CsvLine @('Time','Result','Type','Size','Root','OriginalPath','NewPath','Error')
    [System.IO.File]::WriteAllText($file, $header + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    return $file
}

# Carry out a plan. The caller must already have asked the user for confirmation.
function Invoke-Organise($Plan) {
    $log = New-Log 'OperationLog'
    $done = 0; $failed = 0
    foreach ($m in $Plan.Moves) {
        $move = New-Object PSObject -Property @{ Type = $m.Type; Size = $m.Size; Root = $Plan.Root; Source = $m.Source }
        $target = $m.Target
        try {
            # pick the name again now, in case something appeared since the preview
            $target = Get-FreePath ([System.IO.Path]::GetDirectoryName($m.Target)) ([System.IO.Path]::GetFileName($m.Target)) ($m.Type -eq 'Folder') $null
        } catch { }
        # If the log cannot be written, this throws and NOTHING more is moved
        Add-LogRow $log 'PENDING' $move $target ''
        $result = 'MOVED'; $message = ''
        try { Move-Safely $m.Source $target $m.Type $Plan.Root; $done++ }
        catch { $result = 'FAILED'; $message = $_.Exception.Message; $failed++; Write-Status "  FAILED: $($m.Source) - $message" }
        Add-LogRow $log $result $move $target $message
        if (($done + $failed) % 25 -eq 0) { Write-Status "  processed $($done + $failed) of $($Plan.Moves.Count)..." }
    }
    Write-Status "Finished. Moved: $done   Failed: $failed"
    Write-Status "Log (needed for Undo): $log"
}

# Move everything listed in an OperationLog back. Never overwrites.
function Invoke-Undo([string]$LogFile) {
    $rows = @(Import-Csv -LiteralPath $LogFile -Encoding UTF8)
    # one entry per move: the last row wins; a lone PENDING means the run was interrupted
    $latest = [ordered]@{}
    foreach ($r in $rows) { $latest["$($r.OriginalPath)|$($r.NewPath)"] = $r }
    $entries = @($latest.Values | Where-Object { $_.Result -eq 'MOVED' -or $_.Result -eq 'PENDING' -or
        ($_.Result -eq 'FAILED' -and $_.Error -like '*Verification failed*') })
    [array]::Reverse($entries)

    $undoLog = New-Log 'UndoLog'
    $restored = 0; $problems = 0
    foreach ($e in $entries) {
        $move = New-Object PSObject -Property @{ Type = $e.Type; Size = $e.Size; Root = $e.Root; Source = $e.NewPath }
        $target = $e.OriginalPath
        $result = 'RESTORED'; $message = ''
        try {
            if (-not $e.Root -or -not $e.NewPath -or -not $e.OriginalPath -or $e.NewPath.Contains('..') -or $e.OriginalPath.Contains('..')) { throw 'Invalid log row' }
            $isFolder = $e.Type -eq 'Folder'
            if ($isFolder) { $exists = [System.IO.Directory]::Exists($e.NewPath) } else { $exists = [System.IO.File]::Exists($e.NewPath) }
            if (-not $exists) { throw 'Item is no longer at its organised location (moved, renamed or already undone)' }
            if (-not $isFolder -and (New-Object System.IO.FileInfo($e.NewPath)).Length -ne [long]$e.Size) {
                throw 'File size differs from the log, so it was left alone'
            }
            $target = Get-FreePath ([System.IO.Path]::GetDirectoryName($e.OriginalPath)) ([System.IO.Path]::GetFileName($e.OriginalPath)) $isFolder $null
            if ($target -ne $e.OriginalPath) { $result = 'RESTORED_RENAMED'; $message = 'Original name was occupied' }
        } catch { $result = 'SKIPPED'; $message = $_.Exception.Message }

        if ($result -ne 'SKIPPED') {
            Add-LogRow $undoLog 'PENDING' $move $target ''
            try { Move-Safely $e.NewPath $target $e.Type $e.Root; $restored++ }
            catch { $result = 'FAILED'; $message = $_.Exception.Message }
        }
        Add-LogRow $undoLog $result $move $target $message
        if ($result -ne 'RESTORED') { Write-Status "  $result : $($e.NewPath) - $message"; if ($result -ne 'RESTORED_RENAMED') { $problems++ } }
    }
    Write-Status "Undo finished. Restored: $restored   Not restored: $problems"
    Write-Status "Empty folders are left in place. Undo log: $undoLog"
}

# ---------------------------------------------------------------------------
# Dialogs and window
# ---------------------------------------------------------------------------
function Confirm-Action([string]$Text) {
    # Default button is "No"
    $answer = [System.Windows.Forms.MessageBox]::Show($Text, 'Smart Downloads Organiser - by Sparsh',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Select-AndUndo {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose the OperationLog to undo (newest first)'
    $dialog.InitialDirectory = Get-ReportDir
    $dialog.Filter = 'Operation logs|OperationLog_*.csv'
    $newest = Get-ChildItem -LiteralPath $dialog.InitialDirectory -Filter 'OperationLog_*.csv' | Sort-Object Name -Descending | Select-Object -First 1
    if ($newest) { $dialog.FileName = $newest.Name }
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Write-Status 'Undo cancelled.'; return }
    if (Confirm-Action "Move the files listed in this log back to where they were?`n`n$($dialog.FileName)") { Invoke-Undo $dialog.FileName }
    else { Write-Status 'Undo cancelled.' }
}

# Run a button action: block double-clicks and show errors instead of crashing
function Invoke-Action([scriptblock]$Action) {
    $script:Busy = $true
    foreach ($b in $script:Buttons) { $b.Enabled = $false }
    try { $script:LogBox.Clear(); & $Action }
    catch { Write-Status "ERROR: $($_.Exception.Message)" }
    finally { $script:Busy = $false; foreach ($b in $script:Buttons) { $b.Enabled = $true } }
}

function Show-Window([string]$Root) {
    $script:TargetRoot = $Root
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Smart Downloads Organiser - by Sparsh'
    $form.Size = New-Object System.Drawing.Size(840, 560)
    $form.StartPosition = 'CenterScreen'

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Both'; $box.WordWrap = $false
    $box.MaxLength = 0
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    $box.Dock = 'Fill'

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Top'; $panel.Height = 48; $panel.Padding = New-Object System.Windows.Forms.Padding(6)

    $actions = [ordered]@{
        'Scan'           = { Invoke-Action { [void](Invoke-Scan $script:TargetRoot $false) } }
        'Preview'        = { Invoke-Action { [void](Invoke-Scan $script:TargetRoot $true) } }
        'Organise'       = { Invoke-Action {
                $plan = Invoke-Scan $script:TargetRoot $true
                if ($plan.Moves.Count -eq 0) { Write-Status 'Nothing to organise.'; return }
                if (Confirm-Action "Move $($plan.Moves.Count) item(s) inside`n$($plan.Root)?`n`nThe list is shown in the main window. You can Undo afterwards.") { Invoke-Organise $plan }
                else { Write-Status 'Cancelled. Nothing was moved.' }
            } }
        'Undo'           = { Invoke-Action { Select-AndUndo } }
        'View Reports'   = { Invoke-Action { Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Get-ReportDir)) } }
        'Open Downloads' = { Invoke-Action { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:TargetRoot) } }
    }
    $script:Buttons = @()
    foreach ($label in $actions.Keys) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $label; $button.Width = 125; $button.Height = 32
        $button.Add_Click($actions[$label])
        $panel.Controls.Add($button)
        $script:Buttons += $button
    }

    # do not let the window close in the middle of moving files
    $script:Busy = $false
    $form.Add_FormClosing({ param($sender, $e) if ($script:Busy) { $e.Cancel = $true } })

    $form.Controls.Add($box)
    $form.Controls.Add($panel)
    $script:LogBox = $box
    Write-Status 'Smart Downloads Organiser - made by Sparsh'
    Write-Status "Folder: $Root"
    Write-Status 'Start with Preview. It moves nothing.'
    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
try {
    if ($Folder) { $chosen = $Folder } else { $chosen = Get-DownloadsPath }

    if ($PreviewOnly) {
        [void](Invoke-Scan (Resolve-TargetFolder $chosen) $true)
        exit 0
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if ($Undo) { Select-AndUndo; Read-Host 'Press Enter to close'; exit 0 }
    Show-Window (Resolve-TargetFolder $chosen)
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
