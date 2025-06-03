-- autoSpace by iotku for Davinchi Resolve
-- /Expected/ USAGE (Subject to change)
-- -------------
-- Create a timeline with a SINGLE video track and a SINGLE audio track (dialog)
-- Transcribe audio and remove silence
--
-- The script will determine if the beginning of the clip is too loud and if so
-- move the start point backwards until the AudioThreshold is not exceeded.
--
-- Then, the script will determine if the ending of the clip is too loud,
-- and move forward until the AudioThreshold is not exceeded.
--
-- The clips will then be added to a new video track with adjusted In/Out points
--
-- This currently only works for timelines with 1 Video and one 1 Audio Track


-- TODO/Wishlist
-- -------------
-- - Add support selecting specific audio track to process
-- - Add support for selecting video/audio tracks
-- Known issues:
-- - The script currently only works relevently for timelines with 1 Video track with no gaps

-- !! IMPORTANT !! You must set the ffmpegPath below to the path on YOUR system
-- FULL Path to the FFmpeg executable (We use ffmpeg for audio analysis)
-- MACOS <-- Install with homebrew `brew install ffmpeg`
local ffmpegPath = "/opt/homebrew/bin/ffmpeg" -- MACOS Homebrew ffmpeg path
-- WINDOWS <-- Install with winget `winget install --id=Gyan.FFmpeg  -e` --> (Get-Command ffmpeg).Source -replace '\\', '/'
-- local ffmpegPath = "C:/Users/user/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe/ffmpeg-7.1-full_build/bin/ffmpeg.exe"

-- If You want to use the GUI you must have the Studio version of Resolve, unfortunately since version 19.1
USE_GUI = true -- Set to false to disable GUI and run in headless mode (e.g. for Free version of Resolve)

-- Determine the null device based on the operating system
NullDevice = package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null"

if NullDevice == "NUL" then -- Windows ffi nonsense (requres asWinAPI.lua in the same directory)
    -- Add the current directory to Lua's module search path
    package.path = package.path .. ";C:/ProgramData/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/?.lua"
    AsWinAPI = require("asWinAPI")
end

-- Get the Resolve application instance
ResolveObj = app:GetResolve()

-- Get the project manager
ResolveProjectManager = ResolveObj:GetProjectManager()

-- Get the current project
ResolveProject = ResolveProjectManager:GetCurrentProject()

if ResolveProject then
    print("Connected to project: " .. ResolveProject:GetName())
else
    print("No project is currently open, please open a project.")
    -- abort script early
    return
end

-- DEFAULT VALUES
AudioThresholdStart = -20 -- We consider any audio below -20dB to be silence
AudioThresholdEnd = -30 -- A bit lower to account for trailing off
-- Amount of time to process audio to space in seconds
-- NOTE: This effects both how much audio is processed at the beginning/end of the clips
-- as well as the amount of time we move the start/end points in each step of the process
-- too large of values will increasingly slow down the script and increase the occurance of large gaps
AnalysisSeekTime = 0.2

-- Keep track of total frames added to new timeline
TotalFrames = 0


-- Escape hatch
ProcessingCancelled = false

--- Converts a timecode string (e.g. "00:05:59:12") into a frame count.
-- The calculation is based on a global TimelineFrameRate.
-- @param timecode (string) Timecode in the format "HH:MM:SS:FF".
-- @return (number) Total number of frames relative to TimelineFrameRate.
function TimecodeToFrames(timecode)
    local hours, minutes, seconds, frames = timecode:match("(%d+):(%d+):(%d+):(%d+)")
    hours = tonumber(hours)
    minutes = tonumber(minutes)
    seconds = tonumber(seconds)
    frames = tonumber(frames)

    -- Convert the timecode to total frames
    local totalFrames = (hours * 3600 * TimelineFrameRate) +
        (minutes * 60 * TimelineFrameRate) +
        (seconds * TimelineFrameRate) +
        frames
    return totalFrames
end


--- Converts a timecode string (e.g. "00:05:59:12") into seconds.
--- @param timecode (string) Timecode in the format "HH:MM:SS:FF".
--- @param framerate (number) The frame rate of the media.
--- @return (number) Total number of seconds.
function TimecodeToSeconds(timecode, framerate) -- e.g. for clip:GetMediaPoolItem():GetClipProperty("Duration")
    local hours, minutes, seconds, frames = timecode:match("^(%d%d):(%d%d):(%d%d):(%d%d)$")
    hours = tonumber(hours)
    minutes = tonumber(minutes)
    seconds = tonumber(seconds)
    frames = tonumber(frames)

    -- Convert the timecode to total seconds
    local totalSeconds = (hours * 3600) + (minutes * 60) + seconds + (frames / framerate)
    return totalSeconds
end

-- Function to get the file path of a clip
function GetClipFilePath(clip)
    local mediaPoolItem = clip:GetMediaPoolItem()
    if mediaPoolItem then
        local clipProperties = mediaPoolItem:GetClipProperty()
        return clipProperties["File Path"]
    end
    return nil
end

-- Process Clip audio to find section below target volume or cutoff
-- @param filePath (string) the filesystem path of the source media
-- @param target (float) the target volume to find
-- @param startTime (int) where in the file to start the analysis in SECONDS
-- @param duration (int) how long to analyze the audio in SECONDS, negative values move backwards
-- @param cutoff (int) terminating condition to stop searching when reaching !IMPORTANT!
function AnalyzeAudio(filePath, target, startTime, duration, cutoff)
    local length = math.abs(duration) -- Ensure duration is positive for ffmpeg processing
    local offset = startTime

    local maxVolume = GetMaxVolume(filePath, startTime, length)
    while maxVolume > target do
        print("Current max volume too loud!: " .. maxVolume .. " at offset: " .. offset)

        offset = offset + duration -- negative duration moves backwards in time
        if duration < 0 and offset <= cutoff then return cutoff end
        if duration > 0 and offset >= cutoff then return cutoff end

        maxVolume = GetMaxVolume(filePath, offset, length)
        if maxVolume <= target then
            print("Found max volume: " .. maxVolume .. " at offset: " .. offset)
            return offset
        end
    end
    return startTime -- Return the original start time if no adjustment is needed
end

--- Return max_volume from ffmpeg for short section of audio
-- @param filePath (string) the filesystem path of the source media
-- @param startTime (int) where in the file to start the analysis in SECONDS
-- @param duration ()
-- @return (float) the max_volume returned by ffmpeg or nil
function GetMaxVolume(filePath, startTime, duration)
    local command = string.format(
        ffmpegPath .. " -hide_banner -ss %.2f -t %.2f -i \"%s\" -filter:a volumedetect -f null %s",
        startTime, duration, filePath, NullDevice
    )

    local result = RunCommandAndReturnOutput(command) -- Run the command and capture output
    if not result then
        print("FFmpeg output was nil")
        return -999
    end
    -- Extract max volume from FFmpeg output
    for line in result:gmatch("[^\r\n]+") do
        if line:find("max_volume") then
            local maxVolume = tonumber(line:match("max_volume:%s*(-?[%d%.]+)"))
            return maxVolume
        end
    end
    print("FFmpeg Output:\n" .. result) -- Debug: Print the FFmpeg output
    print("Error: Could not find max_volume in ffmpeg output.")
    -- FIXME: For now we just return a large negative value when ffmpeg parsing fails
    --        Generally this means we're at the end of the file, so this should be harmless...
    return -999
end

function RunCommandAndReturnOutput(command)
    if NullDevice == "NUL" then
        -- Windows: Use the asWinAPI module to run the command
        return AsWinAPI.run_command_capture_output(command)
    end

    command = command .. " 2>&1"
    -- MacOS: Use io.popen to run the command
    print("Running command: " .. command) -- Debug: Print the command
    local handle = io.popen(command)
    local result                          -- ffmpeg command output to parse
    if handle then
        result = handle:read("*a")
        handle:close()
        return result
    else
        print("Error: AnalyzeAudio failed to close ffmpeg command.")
        return nil
    end
end

--- Append the adjusted clip to the new tracks
-- @param clip (Clip) The clip to append
-- @param newVideoTrackIndex (int) The index of the new video track
-- @param clipStartTime (float) The adjusted start time of the clip
-- @param clipEndTime (float) The adjusted end time of the clip
-- @return (boolean) True if the clip was successfully appended, false otherwise
function AppendClipToTimeline(clip, newVideoTrackIndex, clipStartTime, clipEndTime)
    -- Append the adjusted clip to the new tracks
    local mediaPoolItem = clip:GetMediaPoolItem()
    if mediaPoolItem then
        -- Convert clipStartTime and clipEndTime to adding to the new tracks
        local startFrame = math.floor(clipStartTime * TimelineFrameRate)
        local endFrame = math.floor(clipEndTime * TimelineFrameRate)

        -- Ensure startFrame and endFrame are within valid bounds
        if startFrame < 0 then startFrame = 0 end
        if endFrame <= startFrame then
            print("Invalid clip range: startFrame >= endFrame")
            return
        end

        local clipInfo = {
            ["mediaPoolItem"] = mediaPoolItem,
            ["startFrame"] = startFrame,  -- Start from the adjusted clipStartTime
            ["endFrame"] = endFrame,      -- End at the adjusted clipEndTime
            ["trackIndex"] = newVideoTrackIndex,
            ["recordFrame"] = TotalFrames -- Place the clip after the last one
        }

        local success = ResolveMediaPool:AppendToTimeline({ clipInfo })
        if success then
            TotalFrames = TotalFrames + (startFrame - endFrame)
        end
        return success
    else
        print("Could not retrieve file path for clip " .. clip:GetName())
        return false
    end
end

--- Main autoSpace function to run against active timeline
function Main(AudioThresholdStart, AudioThresholdEnd, AnalysisSeekTime, progressSlider)
    -- Get the MediaPool
    ResolveMediaPool = ResolveProject:GetMediaPool()

    -- Get the current timeline
    Timeline = ResolveProject:GetCurrentTimeline()

    -- Get TL framerate
    TimelineFrameRate = Timeline:GetSetting("timelineFrameRate")

    if Timeline then
        print("Connected to timeline: " .. Timeline:GetName())
    else
        print("No timeline is currently open.")
        return
    end

    -- Get the current number of audio tracks
    local initialAudioTrackCount = Timeline:GetTrackCount("audio")

    local audioSubTypes = {}
    if initialAudioTrackCount > 0 then
        for i = 1, initialAudioTrackCount do
            table.insert(audioSubTypes, Timeline:GetTrackSubType("audio", i))
        end
    else
        print("No audio track found in the timeline.")
        return
    end

    -- Get all clips in the original video track
    local clips = Timeline:GetItemListInTrack("video", 1) -- TODO: Break out variable for the video track to process

    local lastClipEnd = 0

    -- Set the current timecode to the beginning of the timeline
    Timeline:SetCurrentTimecode('01:00:00:00')

    -- Create a new timeline
    local newTimelineName = Timeline:GetName() .. " - Autospaced"
    Timeline = ResolveMediaPool:CreateEmptyTimeline(newTimelineName)

    -- FIXME: There doesn't seem to be a way to modify the default audio track type for the new timeline
    --        So we're just skipping the first audio track and assuming it is the default 2.0 stereo track
    --        Alternatively, we could add our clips with an offset (e.g. TrackIndex + 1) which would work
    --        but this would leave both default tracks empty in the timeline
    for i = 2, initialAudioTrackCount do
        local audioTrackCreated = Timeline:AddTrack("audio", audioSubTypes[i])
        if not audioTrackCreated then
            print("Failed to create new audio track. Aborting.")
            return
        end
    end

    -- Loop through each clip from the original timeline
    for i, clip in ipairs(clips) do
        if USE_GUI and progressSlider then
            progressSlider.Value = math.floor((i / #clips) * 100)
        end
        if Timeline:GetName() ~= newTimelineName or ProcessingCancelled then -- if timeline was changed abort
            print("Processing cancelled by user.")
            return
        end

        local filePath = GetClipFilePath(clip)
        if filePath then
            local clipStartTime = clip:GetSourceStartTime()
            local clipEndTime = clip:GetSourceEndTime()

            local nextClipStart = nil
            if clips[i + 1] then
                nextClipStart = clips[i + 1]:GetSourceStartTime()
            end

            -- If the next clip doesn't exist, set nextClipStart to a large value
            if not nextClipStart then
                nextClipStart = math.huge
            end

            -- Analyze Audio to find the start and end points
            clipStartTime = AnalyzeAudio(filePath, AudioThresholdStart, clipStartTime, -AnalysisSeekTime, lastClipEnd)
            clipEndTime = AnalyzeAudio(filePath, AudioThresholdEnd, clipEndTime, AnalysisSeekTime, nextClipStart)

            -- Add the clip to the new timeline from the media pool with adjusted in/out points
            local appendClip = AppendClipToTimeline(clip, 1, clipStartTime, clipEndTime)
            if appendClip then
                print(string.format("Clip %d appended successfully to new video track.", i))
            else
                print(string.format("Failed to append clip %d to new video track.", i))
            end
            lastClipEnd = clipEndTime
        end
    end

    print("Auto spacing completed.")
end

if USE_GUI then
    Fui = fu.UIManager
    Disp = bmd.UIDispatcher(Fui)

    Window = Disp:AddWindow({
        ID = "AutoSpaceWin",
        WindowTitle = "AutoSpace Settings",
        Geometry = {100, 100, 400, 220},
        Fui:VGroup{
            ID = "root",
            Fui:HGroup{
                Fui:Label{Text = "Audio Threshold Start (dB):"},
                Fui:LineEdit{ID = "thresholdStart", Text = tostring(AudioThresholdStart)}
            },
            Fui:HGroup{
                Fui:Label{Text = "Audio Threshold End (dB):"},
                Fui:LineEdit{ID = "thresholdEnd", Text = tostring(AudioThresholdEnd)}
            },
            Fui:HGroup{
                Fui:Label{Text = "Analysis Seek Time (s):"},
                Fui:LineEdit{ID = "seekTime", Text = tostring(AnalysisSeekTime)}
            },
            Fui:HGroup{
                Fui:Button{ID = "runBtn", Text = "Run AutoSpace"},
            },
            Fui.Slider{ID = "progressSlider", Value = 0, Minimum = 0, Maximum = 100, Enabled = false}
        }
    })

    function Window.On.runBtn.Clicked(ev)
        local items = Window:GetItems()
        AudioThresholdStart = tonumber(items.thresholdStart.Text)
        AudioThresholdEnd = tonumber(items.thresholdEnd.Text)
        AnalysisSeekTime = tonumber(items.seekTime.Text)
        items.progressSlider.Value = 0
        coroutine.wrap(function() -- Run Main in a coroutine so UI can update
            Main(AudioThresholdStart, AudioThresholdEnd, AnalysisSeekTime, items.progressSlider)
            items.progressSlider.Value = 100
        end)()
    end

    -- Handle the window close event
    function Window.On.AutoSpaceWin.Close(ev)
        Disp:ExitLoop()
        ProcessingCancelled = true
        print("AutoSpace window closed. Processing cancelled.")
    end

    Window:Show()
    Disp:RunLoop()
    Window:Hide()
else
    -- If not using GUI, run the main function directly
    Main(AudioThresholdStart, AudioThresholdEnd, AnalysisSeekTime)
end