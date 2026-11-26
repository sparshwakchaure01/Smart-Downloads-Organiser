# Smart Downloads Organiser

**Made by Sparsh**

![Made by](https://img.shields.io/badge/made%20by-Sparsh-orange)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Install](https://img.shields.io/badge/install-none-brightgreen)
![License](https://img.shields.io/badge/license-MIT-green)

Turn a messy Downloads folder into tidy, sensible folders. **Double-click, preview, confirm.**
No installation, no accounts, no rules to write. And you can undo it.

> **Early release:** not yet verified on a real Windows machine. Try it on the sample files first
> (see [Testing](docs/TESTING.md)).

## Contents
[What it does](#what-it-does) · [Quick start](#quick-start-3-steps) · [Buttons](#the-buttons) ·
[Features](#features) · [Folders](#folders-it-creates) · [Safety](#safety-guarantees) ·
[Preview, Organise, Undo](#preview-organise-and-undo) · [Reports](#reading-the-reports) ·
[Running again](#running-it-again-weeks-or-months-later) · [Custom rules](#optional-custom-rules) ·
[Troubleshooting](#troubleshooting) · [FAQ](#faq) · [Limitations](#limitations) ·
[Contributing](#contributing) · [License](#license)

## What it does
It looks at what is sitting in your Downloads folder, works out what each thing is, shows you a plan,
and, only if you say **Yes**, moves things into folders. Useful whether you are a student, developer,
designer or office worker.

## Screenshots
| Main window | Preview | Confirmation |
|---|---|---|
| *screenshot placeholder* | *screenshot placeholder* | *screenshot placeholder* |

## Quick start (3 steps)
1. **Download** the ZIP.
2. **Extract** it: right-click the ZIP, choose **Extract All**. (Do not run it from inside the ZIP.)
3. **Double-click `Organiser.bat`**, press **Preview**, and when you are happy press **Organise**.

Your Downloads folder is found automatically, even if you moved it.

## The buttons
| Button | What it does | Moves files? |
|---|---|---|
| Scan | Short summary: how many items go where | No |
| Preview | Full list of every item and its proposed place | No |
| Organise | Shows the plan, asks Yes/No (default **No**), then moves | Only after Yes |
| Undo | Pick a log and put everything back | Yes, after you confirm |
| View Reports | Opens the reports folder | No |
| Open Downloads | Opens the folder being organised | No |

A black console window stays open behind the program. That is normal.

### For testing (command line)
```
Organiser.bat -PreviewOnly
Organiser.bat -PreviewOnly -Folder "C:\path\to\folder"
```

## Features
- Sorts by file type with no setup
- Recognises code projects and moves each **as one whole folder**
- Groups versions (`app`, `App (1)`, `app-main`, `app copy`) without mixing them
- Detects course material, resumes, certificates, invoices, screenshots and wallpapers
- Reads a little text from txt, md, csv, docx and pptx for better guesses
- Splits installers into Dev tools, Apps and Drivers
- Reports duplicates (size, then SHA256) without touching them
- Leaves anything it is unsure about where it is
- Live operation log and one-click Undo
- Optional custom rules
- Plain, readable PowerShell. Nothing hidden or encoded

## Folders it creates
Only the folders that are needed are created.
```
Downloads\
  Documents\  (Course Material, Resumes, Certificates, Invoices and Receipts)
  Images\     (Screenshots, Wallpapers)
  Videos\
  Audio\
  Archives\
  Code\
  Installers\ (Dev tools, Apps, Drivers)
  Design Files\
  Spreadsheets\
  Presentations\
  Books\
  Misc\
  Projects\
    my-site\
    app (versions)\
      app\
      app-main\
  My Folders\   (only if you use rules.json)
```
Spreadsheets and Presentations can also get topic sub-folders, such as `Spreadsheets\Invoices and Receipts`.

## Safety guarantees
- **Never deletes** files or folders
- **Never overwrites**: a clash becomes `name (2).ext`
- **Never edits** file contents
- **Never removes duplicates** for you
- Skips unfinished downloads (`.crdownload .part .tmp .partial .opdownload` and similar), `desktop.ini`,
  `thumbs.db`, hidden items, links and junctions
- Skips itself, its reports and the folders it already made
- A locked or protected file is logged as failed and the rest carry on

Details and how to verify them: [docs/SAFETY.md](docs/SAFETY.md).

## Preview, Organise and Undo
**Preview** moves nothing. It writes three reports and shows the tree, every move, duplicates, related
folders and the NOT SURE list.

**Organise** scans again, shows the plan and asks you to confirm. Close programs that are using
downloaded files first.

**Undo** (button, or double-click `Undo.bat`) lets you choose an `OperationLog`. Items go back to their
original place. If something new now has that name, the restored item becomes `name (2)` and the log says
`RESTORED_RENAMED`. Empty folders left behind are harmless; delete them yourself if you like.

## Reading the reports
Reports are in the `Reports` folder next to the program (or `Documents\SmartDownloadsOrganiser\Reports`
if that is read-only). CSV files open in Excel. **Close a log in Excel before organising or undoing.**

| File | Contents |
|---|---|
| `Preview_*.csv` | Status (MOVE, NOT SURE, SKIPPED), original path, proposed path, reason |
| `Duplicates_*.csv` | Rows with the same Group number are identical files |
| `Summary_*.txt` | The whole preview in plain text |
| `OperationLog_*.csv` | Time, Result, Type, Size, Root, OriginalPath, NewPath, Error |
| `UndoLog_*.csv` | The same columns; here OriginalPath is where the item was before undoing |

Each move has a `PENDING` row followed by `MOVED`, `FAILED`, `RESTORED` or `RESTORED_RENAMED`.
`SKIPPED` appears in undo logs with the reason.

## Running it again weeks or months later
Just double-click and Preview again. Only new loose items are considered. Folders the tool made are not
re-sorted, so nothing nests or moves twice. Keep your `Reports` folder if you may want to undo.

## Optional custom rules
1. Copy `rules.sample.json` and rename the copy to `rules.json`.
2. Edit it in Notepad:
```jsonc
// Comments are shown here for explanation only. Do not put // comments in rules.json.
{
  "rules": [
    { "folder": "Work",          // goes to Downloads\My Folders\Work
      "keywords": ["acme"] }     // any file or folder whose NAME contains "acme"
  ]
}
```
Rules win over automatic sorting. The first match wins. If the file has a mistake, it is ignored with a
message.

## Troubleshooting
**"Windows protected your PC" (SmartScreen).** Windows warns about scripts downloaded from the internet.
Read the two scripts first if you wish (they are plain text). If you trust them: **More info**, then
**Run anyway**. Do not turn off Defender or SmartScreen.

**Execution policy.** `Organiser.bat` starts PowerShell with `-ExecutionPolicy Bypass`. To be honest
about what that means: it lets this script run **in that one process only**. It does not change your
computer's setting, and it is not a security scan. Policies set by your school or company may still
block it; ask your IT team rather than working around them.

**Window does not open.** Make sure you extracted the ZIP. The console shows the error.

**A file says FAILED.** It is probably open in another program, protected, or the path is too long
(over about 260 characters). Close the program or shorten the name, then run again.

**OneDrive.** Online-only files may be skipped as cloud placeholders.

## FAQ
See [docs/FAQ.md](docs/FAQ.md).

## Limitations
- English keywords and file names for topic detection
- PDF, old `.doc` and image text is not read
- Guesses from names can be wrong; check the Preview
- Version grouping ignores trailing numbers, so unrelated `lab 1` and `lab 2` are grouped (not merged)
- Non-project folders are never moved unless a rule matches
- Files that point to each other by path (for example images used by a loose web page) may be separated
- The window cannot be closed while a task is running
- Very long paths may fail (safely)
- Large folders take a while, mostly for duplicate checking, and the window may respond slowly
- Windows only

## Contributing
Issues and pull requests are welcome. Please keep it dependency-free, PowerShell 5.1 compatible, ASCII
only in scripts, and never add code that deletes or overwrites. Run [the tests](docs/TESTING.md).

## Author
Created by **Sparsh**.

## License
[MIT](LICENSE) (c) 2026 Sparsh
