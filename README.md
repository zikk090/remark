# Remark

A menu-bar reviewer for macOS. Hit a shortcut, drag over any part of the screen, then type or talk a note. Every note (screenshot + text) lands in a local **review session** that becomes a clean report you can send to anyone. It doesn't need Google Docs, edit access, or the other person's tool.

Use it for app/onboarding walkthroughs, bug bounty evidence, design feedback, doc review, or anything else you're looking at on screen.

## Shortcuts

| Keys | Action |
|---|---|
| **⌃⌥R** | Capture & note: drag to select, click (or ↩) for the whole screen, Esc to cancel |
| **⌃⌥N** | New review session |
| **⌃⌥B** | Toggle the cursor buddy |

In the note panel: **⌘↩** save · **⌘D** talk/stop · **Esc** discard. Pick a tag: Note / Bug / UX / Question / Idea.

## How it works

- **Cursor buddy**: while a session is active, a small orange dot follows your cursor and shows the session name and note count. It turns red while you're dictating.
- **Talk or type**: dictation runs on Apple's Speech framework, and on-device when your Mac supports it, so client screens and notes stay on your machine. If you'd rather talk first, turn on *Start Talking Automatically*.
- **Sessions** live in `~/Documents/Remark/<date>-<name>/`:
  - `shots/*.png`: the captures
  - `session.json`: the raw data
  - `report.html`: a styled report (dark-mode aware, prints cleanly to PDF)
  - `report.md`: Markdown for GitHub/HackerOne/Jira
- **Export Shareable HTML** writes one self-contained file with the images embedded, ready to email or upload.
- If you capture with no session active, an "untitled" session starts automatically.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.

```bash
./build.sh install    # builds, copies to ~/Applications, launches
```

First launch asks for **Screen Recording** permission. Grant it, then quit and reopen Remark (macOS requires the relaunch). Mic and Speech Recognition are requested the first time you press Talk.

> Rebuilding with ad-hoc signing changes the app's signature, so macOS may ask for Screen Recording again. If you have an Apple Development certificate, `build.sh` picks it up automatically and the permission survives rebuilds.

## Roadmap ideas

- Screen recording clips per note (ScreenCaptureKit `SCRecordingOutput`)
- Arrows/boxes/redaction on the screenshot before saving (redaction matters for bug bounty PII)
- Edit/reorder/delete notes in a session viewer window
- Report templates: HackerOne/Bugcrowd style, client UX audit
- Configurable hotkeys
