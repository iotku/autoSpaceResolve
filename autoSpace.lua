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
-- - Add support for multiple video/audio tracks
-- - Add support for selecting video/audio tracks
-- Known issues:
-- - The script currently only works for timelines with 1 Video and one 1 Audio Track
-- - If you have multiple audio tracks in the source material, it will only produce the first audio track
--   onto the new audio track

-- !! IMPORTANT !! You must set the ffmpegPath below to the path on YOUR system
-- FULL Path to the FFmpeg executable (We use ffmpeg for audio analysis)
local ffmpegPath = "/opt/homebrew/bin/ffmpeg"

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


-- Get the MediaPool
ResolveMediaPool = ResolveProject:GetMediaPool()

-- Get the current timeline
Timeline = ResolveProject:GetCurrentTimeline()

-- Get TL framerate
TimelineFrameRate = Timeline:GetSetting("timelineFrameRate")

-- We consider any audio below -20dB to be silence
AudioThresholdStart = -20

-- A bit lower to account for trailing off
AudioThresholdEnd = -30

-- Amount of time to process audio to space in seconds
-- NOTE: This effects both how much audio is processed at the beginning/end of the clips
-- as well as the amount of time we move the start/end points in each step of the process
-- too large of values will increasingly slow down the script and increase the occurance of large gaps
AnalysisSeekTime = 0.2

--- Converts a timecode string (e.g. "00:05:59:12") into a frame count.
-- The calculation is based on a global TimelineFrameRate.
-- @param timecode (string) Timecode in the format "HH:MM:SS:FF".
-- @return (number) Total number of frames relative to TimelineFrameRate.
function TimecodeToFrames(timecode)
    -- Split the timecode into hours, minutes, seconds, and frames
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

-- Function to get the file path of a clip
function GetClipFilePath(clip)
    local mediaPoolItem = clip:GetMediaPoolItem()
    if mediaPoolItem then
        local clipProperties = mediaPoolItem:GetClipProperty()
        return clipProperties["File Path"]
    end
    return nil
end

--- Return max_volume from ffmpeg for short section of audio
-- @param filePath (string) the filesystem path of the source media
-- @param startTime (int) where in the file to start the analysis in SECONDS
-- @return (float) the max_volume returned by ffmpeg or nil
function AnalyzeAudio(filePath, startTime)
    local duration = AnalysisSeekTime -- Analyze the first AnalysisSeekTime seconds
    -- TODO: Does input redirection work as expected on windows? is it even necessiary?
    local command = string.format(
        ffmpegPath .. " -ss %.2f -t %.2f -i \"%s\" -filter:a volumedetect -f null /dev/null 2>&1",
        startTime, duration, filePath
    )
    print("Running command: " .. command) -- Debug: Print the command
    local handle = io.popen(command)
    local result                          -- ffmpeg command output to parse
    if handle then
        result = handle:read("*a")
        handle:close()
    else
        print("Error: AnalyzeAudio failed to close ffmpeg command.")
        return nil
    end

    -- Extract max volume from FFmpeg output
    for line in result:gmatch("[^\r\n]+") do
        if line:find("max_volume") then
            local maxVolume = tonumber(line:match("max_volume:%s*(-?[%d%.]+)"))
            return maxVolume
        end
    end
    return nil
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
        -- TODO: this is dependent on the playhead which can be moved during processing
        -- is it possible to prevent that, or can we make this relative to the last clip rather than the playhead?
        local recordFrame = TimecodeToFrames(Timeline:GetCurrentTimecode())


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
            ["recordFrame"] = recordFrame -- Place the clip after the last one
        }

        local success = ResolveMediaPool:AppendToTimeline({ clipInfo })
        return success
    else
        print("Could not retrieve file path for clip " .. clip:GetName())
        return false
    end
end

--- Main autoSpace function to run against active timeline
function Main()
    if Timeline then
        print("Connected to timeline: " .. Timeline:GetName())
    else
        print("No timeline is currently open.")
        return
    end

    -- Get the current number of video and audio tracks
    local initialVideoTrackCount = Timeline:GetTrackCount("video")
    local initialAudioTrackCount = Timeline:GetTrackCount("audio")

    local initialAudioTrackSubType
    if initialAudioTrackCount > 0 then
        initialAudioTrackSubType = Timeline:GetTrackSubType("audio", 1) -- TODO: Select which audio track to process
    else
        print("No audio track found in the timeline.")
        return
    end
    -- Create a new video and audio track
    local videoTrackCreated = Timeline:AddTrack("video")
    local audioTrackCreated = Timeline:AddTrack("audio", initialAudioTrackSubType)
    

    if not videoTrackCreated or not audioTrackCreated then
        print("Failed to create new video/audio track. Aborting.")
        return
    end

    -- TODO: Ensure we can handle timelines with multiple A/V tracks correctly
    -- Determine the indices of the new tracks
    local newVideoTrackIndex = initialVideoTrackCount + 1
    local newAudioTrackIndex = initialAudioTrackCount + 1

    -- Get all clips in the original video track
    local clips = Timeline:GetItemListInTrack("video", 1) -- TODO: Break out variable for the video track to process

    local lastClipEnd = 0

    -- Set the current timecode to the beginning of the timeline
    Timeline:SetCurrentTimecode('01:00:00:00')

    -- Loop through each clip and extract its file path
    for i, clip in ipairs(clips) do
        local filePath = GetClipFilePath(clip)
        if filePath then
            print("Clip " .. i .. " file path: " .. filePath)
            -- Pass this file path to FFmpeg for audio analysis
            local clipStartTime = clip:GetSourceStartTime()
            local maxVolume = AnalyzeAudio(filePath, clipStartTime)

            -- Locate Start Point if audio is too loud at beginning of clip
            if maxVolume and maxVolume > AudioThresholdStart then -- Adjust threshold as needed
                print(string.format("Clip %d: Audio too loud at start (%.2f dB). Attempting to adjust start point.", i,
                    maxVolume))
                -- Move AnalyzeAudio start time back until maxVolume is below threshold or clip start is the same (or lower) as the previous clip
                while maxVolume > AudioThresholdStart and clipStartTime > lastClipEnd do
                    clipStartTime = clipStartTime - AnalysisSeekTime
                    maxVolume = AnalyzeAudio(filePath, clipStartTime)
                end
                print(string.format("Adjusted start time to %.2f seconds, max volume: %.2f dB", clipStartTime, maxVolume))
                -- if the clip start is the same or lower as the previous clip (or the beginning of the source file), we can stop
            else
                print(string.format("Clip %d: Audio level acceptable at start (%.2f dB).", i, maxVolume or -999))
            end

            -- Locate end point if audio is too loud at end of clip (e.g. we haven't finished talking yet maybe)
            local clipEndTime = clip:GetSourceEndTime()
            maxVolume = AnalyzeAudio(filePath, clipEndTime)

            -- Check if the next clip exists and get its start time
            local nextClipStart = nil
            local nextClipEnd = nil
            if clips[i + 1] then
                nextClipStart = clips[i + 1]:GetSourceStartTime()
                nextClipEnd = clips[i + 1]:GetSourceEndTime()
            end

            -- If the next clip doesn't exist, set nextClipStart to a large value
            if not nextClipStart then
                nextClipStart = math.huge
            end

            if maxVolume and maxVolume > AudioThresholdEnd then
                print(string.format("Clip %d: Audio too loud at end (%.2f dB). Attempting to adjust end point.", i,
                    maxVolume))
                -- Move AnalyzeAudio start time forward until maxVolume is below threshold or clip start is the same as the following clip
                while maxVolume > AudioThresholdEnd and clipEndTime < nextClipStart do
                    clipEndTime = clipEndTime +
                    AnalysisSeekTime                             -- TODO, what happens when we hit the end of the source file? I expect this breaks
                    maxVolume = AnalyzeAudio(filePath, clipEndTime)
                end

                -- ensure clipEndTime is not greater than the start of the next clip
                if clipEndTime > nextClipStart then
                    clipEndTime = nextClipStart
                end

                -- Adjust the next clip's start time if it overlaps with the current clip's end time
                if nextClipStart and nextClipStart < clipEndTime then
                    if nextClipEnd and nextClipStart > nextClipEnd then
                        nextClipStart = nextClipEnd -- Ensure the next clip's start doesn't exceed its end
                    end
                    print(string.format("Adjusted next clip's start time to %.2f seconds to avoid overlap.",
                        nextClipStart))
                end

                print(string.format("Adjusted end time to %.2f seconds, max volume: %.2f dB", clipEndTime, maxVolume))
            else
                print(string.format("Clip %d: Audio level acceptable at end (%.2f dB).", i, maxVolume or -999))
            end

            local appendClip = AppendClipToTimeline(clip, newVideoTrackIndex, clipStartTime, clipEndTime)
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

Main() -- Burn baby burn
