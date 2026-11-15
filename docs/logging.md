# Logging

Harf writes a small log file so a problem leaves something to read after the fact.

## Where

`~/Library/Logs/Harf/harf.log` (Console.app lists it under Log Reports). Every line is also written to stderr as `harf: <message>`, so `macos/.build/Harf.app/Contents/MacOS/Harf` in a terminal still prints them.

```
2026-11-15T10:49:50Z WARN  previous run did not quit cleanly; look for Harf-*.ips in ~/Library/Logs/DiagnosticReports
2026-11-15T10:49:50Z INFO  launch 0.0.1, Version 15.6.1 (Build 24G90)
```

Format: UTC time, level (`INFO`, `WARN`, `ERROR`), message.

## What is logged

- `launch <version>, <macOS version>` at start and `quit` on a normal quit.
- `previous run did not quit cleanly`: the last line of the old file was not `quit`. The app crashed or was killed. A crash leaves a report, `Harf-<date>.ips`, in `~/Library/Logs/DiagnosticReports`; the top of its crashed thread names the cause.
- Config warnings (`config: line 8: expected 'key = value'`).
- Editor failures (Cmd-click on a path): the editor failed to open, or its command exited non-zero.
- Notifications that were not shown: not authorized, or the system refused them.
- `pane exited, status N`, one line per shell or program that ends.

## What is never logged

What a program printed, what the user typed, file paths clicked, notification titles and bodies. The log is for what Harf did, and a user may attach it to a bug report.

## Rotation

Checked at launch: a file over 1 MiB becomes `harf.log.1` (the previous `.1` is replaced), and a new `harf.log` starts. No setting, no timer.

## Adding a line

`Log.info`, `Log.warn` or `Log.error` from `macos/Sources/Harf/Log.swift`. They are safe from any thread (a lock guards the file) and never throw. Nothing reaches the file before `Log.start()` runs in `applicationWillFinishLaunching`, so `--selftest` and `--conformance` runs do not touch the real log.

## Callbacks from system APIs

A closure written inside `@MainActor` code is main-actor isolated. If a system API calls it on a background queue (UserNotifications, `NSWorkspace.open(_:withApplicationAt:)`, `Process.terminationHandler`), Swift 6 traps with `EXC_BREAKPOINT` in `swift_task_isCurrentExecutor`, and the compiler says nothing. Mark such closures `@Sendable`, and hop to the main actor with `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` if they need main-actor state. This is what crashed Harf on 2026-11-15 (`Notifier.post`) and, in an earlier form, `titleOnMain`.
