# MeetingNoteTaker

Turn conversations into a personal notebook. MeetingNoteTaker lives in your Mac’s menu bar, records meetings, and saves transcripts and analysis as Markdown files you can keep, edit and use with other tools.

**Requires macOS 26 or later and an Apple Silicon Mac.**

## Key features

- Record microphone and computer audio separately, with pause/resume, audio meters and optional capture of a selected app.
- Transcribe locally with Whisper, Parakeet or Apple Speech, or use a configured transcription server.
- Generate summaries, key points, decisions, action items and open questions using a local or configured server model.
- Choose English, French or Spanish analysis output, and customize the prompts for each analysis type.
- Save reusable profiles such as Technical review, Client call or Personal journal, with analysis preferences and tags.
- Review formatted Markdown or its raw text, follow evidence links to transcript turns, and play back retained audio.
- Search meeting filenames and contents locally, and move a meeting and its related files to macOS Trash.
- Choose where notes are saved and how long audio is kept. Regenerate analysis even after audio is deleted.
- Start recordings with keyboard shortcuts and recover interrupted work.


## Demo

![MeetingNoteTaker demo: real app screens showing meeting notes, transcript evidence, Markdown, and local or remote model choices](Docs/assets/meetingnotetaker-demo.gif)


## How to use

1. Open **MeetingNoteTaker.app** and click its menu bar icon. Open **Settings** to get started.
2. In **Models**, select and activate a transcription model. Choose an analysis model too if you want summaries and other analyses. Local models may need downloading; server providers send the relevant audio or transcript to the server you configure.
3. Choose your microphone, output folder and audio-retention preferences. Grant microphone and computer-audio permissions when prompted.
4. Choose **Start meeting**, or **Start meeting with profile** for a specific profile. Pause as needed, then choose **Stop and transcribe**.
5. Open **Meetings & transcripts…** to review the result, switch between **Preview / Raw**, play audio or run analysis. Use **Open Markdown** to edit the file in your preferred editor.

Notes and matching audio are saved to `~/Documents/MeetingNoteTaker` by default. Choose **Keyboard Shortcuts** from the menu to see the current bindings.

## Documentation

See [Docs](Docs/README.md) for the [architecture](Docs/Architecture.md), [component map](Docs/Components.md), and [build, test and release guide](Docs/Development.md).
