# autoSpace by iotku for DaVinci Resolve

A DaVinci Resolve script that  adjusts clip in-points to ensure cleaner starts by analyzing audio levels. Ideal for resolving issues from transcription-based edits where clips may start mid-word and be jarring.

---

## Features

* Processes timelines with a single video track
* Fixes clips that start too deep into audio (e.g., in the middle of words) after transcription editing and silence removal
* Automatically adjusts clip start and end points when audio exceeds thresholds based on FFmpeg processing
* Places trimmed clips onto a newly created timeline called `<OriginalName>- Autospaced`

---

## Requirements

* DaVinci Resolve with scripting API access
* FFmpeg (for audio volume analysis) installed on your system

  * The script’s `ffmpegPath` variable is preconfigured for macOS with FFmpeg installed via Homebrew (`/opt/homebrew/bin/ffmpeg`).
* Lua interpreter (bundled with Resolve scripting environment)

---

## Installation

**macOS:**

1. Copy the `autoSpace.lua` script into:

   ```
   /Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility
   ```

   * In Finder, press **Shift + Command + G**, then paste the path above to quickly navigate to the folder.

**Windows:**

1. Copy the `autoSpace.lua` script into:

   ```
   %ProgramData%\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Utility
   ```

   * NOTE: You will need to update `ffmpegPath` to a relevent windows build of ffmpeg

---

## Configuration

1. Open the script file and locate the `ffmpegPath` variable near the top.

2. Set `ffmpegPath` to the full path of the FFmpeg executable on your system. For example:

   ```lua
   local ffmpegPath = "/opt/homebrew/bin/ffmpeg"
   ```

3. Adjust audio thresholds or analysis window durations if desired:

   * `AudioThresholdStart` (-20 dB by default)
   * `AudioThresholdEnd` (-30 dB by default)
   * `AnalysisSeekTime` (0.2 seconds by default)

---

## Usage

1. Create a timeline containing **exactly one video track**.
2. Ensure that you have the timeline you wish to process open.
3. Run the `autoSpace.lua` script via **Workspace > Scripts > autoSpace.lua**. Avoid adjusting the playback head while the script is running, as this may interfere with clip placement.

The script:

1. Checks for an open project and timeline.
2. Creates a new empty timeline named `<CurrentTimelineName>- Autospaced`.
3. Iterates through each video clip, analyzes leading/trailing audio levels, and adjusts start/end accordingly.
4. Appends trimmed clips onto new video and audio tracks on the new timeline.

---

## How It Works

1. **Audio Analysis**: Uses FFmpeg’s `volumedetect` filter to obtain `max_volume` over a short segment at the clip’s start/end.
2. **Start Adjustment**: If `max_volume > AudioThresholdStart`, the script steps backward by `AnalysisSeekTime` until the volume falls below the threshold or reaches previous clip end.
3. **End Adjustment**: If `max_volume > AudioThresholdEnd`, the script steps forward similarly, ensuring clips do not overlap.
4. **Clip Assembly**: Inserts the media from the media pool with adjusted in/out points, and appends each trimmed clip onto the new timeline.

---

## Known Issues

* There isn't a way to stop the script gracefully before it's finished. (In a pinch you can delete the `- Autospaced` timeline
* If you switch windows/workspaces during processing clips may get posted without the relevent audio tracks
