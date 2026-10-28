<h1 align="center">WorkLog <img src="Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" height="40" align="top" alt=""></h1>

<p align="center">
  A macOS menu bar app that counts the days you work outside your contract, using your git commits and file edits as proof.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-D6943D?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5-D6943D?logo=swift&logoColor=white" alt="Swift 5">
  <img src="https://img.shields.io/badge/SwiftUI-menu%20bar-D6943D" alt="SwiftUI menu bar app">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/preview-dark.png">
    <img src="docs/preview-light.png" width="340" alt="WorkLog's menu bar panel showing four extra days in October">
  </picture>
</p>

## What it does

- Scans your repos and notes folder every 10 minutes for commits and edited files
- Marks each extra day on a month calendar and totals the gross pay
- Writes a one-line note for each day with Claude Code, or you type your own
- Copies the month as plain text, ready to paste into Slack
- Locks past months so they can't change by accident

## Setup

1. Open `WorkLog.xcodeproj` in Xcode.
2. Set these at the top of `WorkLog.swift`:

   | Setting | What it is |
   | --- | --- |
   | `root` | Folder with your repo clones and notes |
   | `myAuthors` | Your git author name or email |
   | `contractStart` | Date to start counting from |
   | `contractedWeekdays` | Your normal working days (Sunday = 1) |
   | `dayRates` | Your gross day rate, from a given date |

3. Run. WorkLog copies itself into Applications, opens from there and starts at login.

## AI notes

Optional. If [Claude Code](https://claude.com/claude-code) is installed and signed in, WorkLog asks Haiku for a one-line note per day. It only sends commit messages, file names and note titles, never code. No API key needed.

## Self-test

```sh
/Applications/WorkLog.app/Contents/MacOS/WorkLog --selftest
```

History is saved to `history.json` in `root/WorkLog/`.
