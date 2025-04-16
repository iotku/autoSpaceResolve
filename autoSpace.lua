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
    -- abort script
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

-- time to add to each in extra in seconds -- TODO: This doesn't seem effective
ClipBufferTime = 1.2

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

function GetClipStartTime(clip)
    local sourceStartTime = clip:GetSourceStartTime()
    print("Clip source start time: " .. sourceStartTime) -- Debug: Print the source start time
    return sourceStartTime
end

function GetClipEndTime(clip)
    local sourceEndTime = clip:GetSourceEndTime()
    print("Clip source end time: " .. sourceEndTime) -- Debug: Print the source end time
    return sourceEndTime
end

-- Return max_volume from ffmpeg for short section of audio
-- @param filePath (string) the filesystem path of the source media
-- @param startTime (int) where in the file to start the analysis in SECONDS
-- @return (float) the max_volume returned by ffmpeg or nil
function AnalyzeAudio(filePath, startTime)
    local duration = 0.1 -- Analyze the first 0.1 seconds
    -- TODO: Does input redirection work as expected on windows? is it even necessiary?
    local command = string.format(
        ffmpegPath .. " -ss %.2f -t %.2f -i \"%s\" -filter:a volumedetect -f null /dev/null 2>&1",
        startTime, duration, filePath
    )
    print("Running command: " .. command) -- Debug: Print the command
    local handle = io.popen(command)
    local result -- ffmpeg command output to parse
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

-- Main autoSpace function to run against active timeline
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

    -- Create a new video and audio track
    local videoTrackCreated = Timeline:AddTrack("video")
    local audioTrackCreated = Timeline:AddTrack("audio")

    if not videoTrackCreated or not audioTrackCreated then
        print("Failed to create new video/audio track. Aborting.")
        return
    end

    -- TODO: Ensure we can handle timelines with multiple A/V tracks correctly
    -- Determine the indices of the new tracks
    local newVideoTrackIndex = initialVideoTrackCount + 1
    local newAudioTrackIndex = initialAudioTrackCount + 1

    -- Get all clips in the original video track
    local clips = Timeline:GetItemListInTrack("video", 1)

    local lastClipEnd = 0

    -- Set the current timecode to the beginning of the timeline
    Timeline:SetCurrentTimecode('01:00:00:00')

    -- Loop through each clip and extract its file path (limit to first 5 clips)
    for i, clip in ipairs(clips) do
        -- if i > 500 then break end -- Stop after processing 10 clips

        local filePath = GetClipFilePath(clip)
        if filePath then
            print("Clip " .. i .. " file path: " .. filePath)
            -- Pass this file path to FFmpeg for audio analysis
            local clipStartTime = GetClipStartTime(clip)
            local maxVolume = AnalyzeAudio(filePath, clipStartTime)

            -- Locate Start Point if audio is too loud at beginning of clip
            if maxVolume and maxVolume > AudioThresholdStart then -- Adjust threshold as needed
                print(string.format("Clip %d: Audio too loud at start (%.2f dB). Attempting to adjust start point.", i, maxVolume))
                -- Move ffmpeg start time back by 0.1 seconds until maxVolume is below threshold or clip start is the same (or lower) as the previous clip
                while maxVolume > AudioThresholdStart and clipStartTime > lastClipEnd do
                    clipStartTime = clipStartTime - 0.1
                    maxVolume = AnalyzeAudio(filePath, clipStartTime)
                end
                local bufferedTime = clipStartTime - ClipBufferTime -- add additional buffer for saftey
                if bufferedTime > lastClipEnd then
                    clipStartTime = bufferedTime
                end
                print(string.format("Adjusted start time to %.2f seconds, max volume: %.2f dB", clipStartTime, maxVolume))
                -- if the clip start is the same or lower as the previous clip (or the beginning of the source file), we can stop
            else
                print(string.format("Clip %d: Audio level acceptable at start (%.2f dB).", i, maxVolume or -999))
            end

            -- Locate end point if audio is too loud at end of clip (e.g. we haven't finished talking yet maybe)
            local clipEndTime = GetClipEndTime(clip)
            maxVolume =  AnalyzeAudio(filePath, clipEndTime)

            -- Check if the next clip exists and get its start time
            local nextClipStart = nil
            if clips[i + 1] then
                nextClipStart = GetClipStartTime(clips[i + 1])
            end

            -- If the next clip doesn't exist, set nextClipStart to a large value
            if not nextClipStart then
                nextClipStart = math.huge
            end

            if maxVolume and maxVolume > AudioThresholdEnd then -- Adjust threshold as needed
                print(string.format("Clip %d: Audio too loud at end (%.2f dB). Attempting to adjust end point.", i, maxVolume))
                -- Move ffmpeg start time back by 0.1 seconds until maxVolume is below threshold or clip start is the same (or lower) as the previous clip
                while maxVolume > AudioThresholdEnd and clipEndTime < nextClipStart do
                    clipEndTime = clipEndTime + 0.1 -- TODO, what happens when we hit the end of the source file? I expect this breaks
                    maxVolume = AnalyzeAudio(filePath, clipEndTime)
                end

                local bufferedTime = clipEndTime + ClipBufferTime -- add additional buffer for saftey
                if bufferedTime < nextClipStart then
                    clipEndTime = bufferedTime
                end

                print(string.format("Adjusted end time to %.2f seconds, max volume: %.2f dB", clipEndTime, maxVolume))
            else
                print(string.format("Clip %d: Audio level acceptable at end (%.2f dB).", i, maxVolume or -999))
            end

            local startFrame = math.floor(clipStartTime * TimelineFrameRate)
            local endFrame = math.floor(clipEndTime * TimelineFrameRate)

            -- Append the adjusted clip to the new tracks
            local mediaPoolItem = clip:GetMediaPoolItem()
            if mediaPoolItem then
                -- Convert clipStartTime and clipEndTime to frames

                local recordFrame = TimecodeToFrames(Timeline:GetCurrentTimecode())
                -- Ensure startFrame and endFrame are within valid bounds
                if startFrame < 0 then startFrame = 0 end
                if endFrame <= startFrame then
                    print("Invalid clip range: startFrame >= endFrame")
                    return
                end

                -- Create the clipInfo table
                local clipInfo = {
                    ["mediaPoolItem"] = mediaPoolItem,
                    ["startFrame"] = startFrame, -- Start from the adjusted clipStartTime
                    ["endFrame"] = endFrame, -- End at the original clipEndTime
                    ["trackIndex"] = newVideoTrackIndex,
                    ["recordFrame"] = recordFrame -- Place the clip after the last one
                }

                local success = ResolveMediaPool:AppendToTimeline({clipInfo})
                if success then
                    print("Clip added to new video track successfully.")
                else
                    print("Failed to add clip to new video track.")
                end
            else
                print("Could not retrieve file path for clip " .. i)
            end

            lastClipEnd = endFrame
        end
    end

    print("Auto spacing completed.")
end

Main()
