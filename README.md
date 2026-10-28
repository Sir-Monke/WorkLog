# WorkLog

A macOS menu bar app that tracks the days you work outside your contracted weekdays, using your git commits and file edits as proof. It totals the gross pay for the month and copies a summary you can paste into Slack.

## Setup

1. Open `WorkLog.xcodeproj` in Xcode (macOS 13+).
2. Edit the settings at the top of `WorkLog.swift`:
   - `root`: the folder holding your repo clones and notes
   - `myAuthors`: your git author name or email
   - `contractStart`: the date to start counting from
   - `contractedWeekdays`: your normal working days (Sunday = 1)
   - `dayRates`: your gross day rate
3. Run it. It copies itself into Applications, opens from there and adds itself to login items.

## AI notes (optional)

If [Claude Code](https://claude.com/claude-code) is installed and signed in, WorkLog writes a one-line note for each extra day using Haiku. It only sends commit messages, file names and note titles, never code. You don't need an API key.

## Self-test

```
WorkLog.app/Contents/MacOS/WorkLog --selftest
```

History is saved to `history.json` inside `root/WorkLog/`.
