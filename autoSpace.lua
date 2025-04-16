-- Get the Resolve application instance
resolve = app:GetResolve()

-- Get the MediaPool
media_pool = project:GetMediaPool()

-- Get the project manager
projectManager = resolve:GetProjectManager()

-- Get the current project
project = projectManager:GetCurrentProject()

-- Get the current timeline
timeline = project:GetCurrentTimeline()

-- Get TL framerate
timelineFrameRate = timeline:GetSetting("timelineFrameRate")

if project then
    print("Connected to project2: " .. project:GetName())
else
    print("No project is currently open, please open a project.")
    -- abort script
    return
end

-- We consider any audio below -20dB to be silence
audioThreshold = -20

-- Define the path to the FFmpeg executable
local ffmpegPath = "/opt/homebrew/bin/ffmpeg"


function timecodeToFrames(timecode)
    -- Split the timecode into hours, minutes, seconds, and frames
    local hours, minutes, seconds, frames = timecode:match("(%d+):(%d+):(%d+):(%d+)")
    hours = tonumber(hours)
    minutes = tonumber(minutes)
    seconds = tonumber(seconds)
    frames = tonumber(frames)

    -- Convert the timecode to total frames
    local totalFrames = (hours * 3600 * timelineFrameRate) + (minutes * 60 * timelineFrameRate) + (seconds * timelineFrameRate) + frames
    return totalFrames
end


-- Function to get the file path of a clip
function getClipFilePath(clip)
    local mediaPoolItem = clip:GetMediaPoolItem()
    if mediaPoolItem then
        local clipProperties = mediaPoolItem:GetClipProperty()
        return clipProperties["File Path"]
    end
    return nil
end

function getClipStartTime(clip) -- TODO: Does this need to be adjusted for frame rate?
    local sourceStartTime = clip:GetSourceStartTime()
    print("Clip source start time: " .. sourceStartTime) -- Debug: Print the source start time
    return sourceStartTime
end

function getClipEndTime(clip) -- TODO: Does this need to be adjusted for frame rate?
    local sourceEndTime = clip:GetSourceEndTime()
    print("Clip source end time: " .. sourceEndTime) -- Debug: Print the source end time
    return sourceEndTime
end

function analyzeAudio(filePath, startTime)
    local duration = 0.1 -- Analyze the first 0.1 seconds
    local command = string.format(
        ffmpegPath .. " -ss %.2f -t %.2f -i \"%s\" -filter:a volumedetect -f null /dev/null 2>&1",
        startTime, duration, filePath
    )
    print("Running command: " .. command) -- Debug: Print the command
    local handle = io.popen(command)
    local result = handle:read("*a")
    handle:close()

    -- Extract max volume from FFmpeg output
    for line in result:gmatch("[^\r\n]+") do
        if line:find("max_volume") then
            local maxVolume = tonumber(line:match("max_volume:%s*(-?[%d%.]+)"))
            return maxVolume
        end
    end
    return nil
end

-- Modify the autoSpace function to process only the first 5 clips
function autoSpace()
    if timeline then
        print("Connected to timeline: " .. timeline:GetName())
    else
        print("No timeline is currently open.")
        return
    end

    -- Get the current number of video and audio tracks
    local initialVideoTrackCount = timeline:GetTrackCount("video")
    local initialAudioTrackCount = timeline:GetTrackCount("audio")

    -- Create a new video and audio track
    local videoTrackCreated = timeline:AddTrack("video")
    local audioTrackCreated = timeline:AddTrack("audio")

    -- Determine the indices of the new tracks
    local newVideoTrackIndex = initialVideoTrackCount + 1
    local newAudioTrackIndex = initialAudioTrackCount + 1
    -- if not newVideoTrackIndex or not newAudioTrackIndex then
    --     print("Failed to create new tracks.")
    --     return
    -- end
    print("Created new video track at index: " .. newVideoTrackIndex)
    print("Created new audio track at index: " .. newAudioTrackIndex)

    -- Get all clips in the original video track
    local clips = timeline:GetItemListInTrack("video", 1)

    local lastClip = nil
    local lastClipEnd = 0

    -- Loop through each clip and extract its file path (limit to first 5 clips)
    for i, clip in ipairs(clips) do
        -- if i > 500 then break end -- Stop after processing 10 clips

        local filePath = getClipFilePath(clip)
        if filePath then
            print("Clip " .. i .. " file path: " .. filePath)
            -- Pass this file path to FFmpeg for audio analysis
            local clipStartTime = getClipStartTime(clip)
            local maxVolume = analyzeAudio(filePath, clipStartTime)

            -- Locate Start Point if audio is too loud at beginning of clip
            if maxVolume and maxVolume > audioThreshold then -- Adjust threshold as needed
                print(string.format("Clip %d: Audio too loud at start (%.2f dB). Attempting to adjust start point.", i, maxVolume))
                -- Move ffmpeg start time back by 0.1 seconds until maxVolume is below threshold or clip start is the same (or lower) as the previous clip
                while maxVolume > audioThreshold and clipStartTime > lastClipEnd do
                    clipStartTime = clipStartTime - 0.1
                    maxVolume = analyzeAudio(filePath, clipStartTime)
                end
                print(string.format("Adjusted start time to %.2f seconds, max volume: %.2f dB", clipStartTime, maxVolume))
                -- if the clip start is the same or lower as the previous clip (or the beginning of the source file), we can stop
            else
                print(string.format("Clip %d: Audio level acceptable at start (%.2f dB).", i, maxVolume or -999))
            end

            -- Locate end point if audio is too loud at end of clip (e.g. we haven't finished talking yet maybe)
            local clipEndTime = getClipEndTime(clip)
            maxVolume =  analyzeAudio(filePath, clipEndTime)

            -- Check if the next clip exists and get its start time
            local nextClipStart = nil
            if clips[i + 1] then
                nextClipStart = getClipStartTime(clips[i + 1])
            end
            -- If the next clip doesn't exist, set nextClipStart to a large value
            if not nextClipStart then
                nextClipStart = math.huge
            end
            if maxVolume and maxVolume > audioThreshold then -- Adjust threshold as needed
                print(string.format("Clip %d: Audio too loud at end (%.2f dB). Attempting to adjust end point.", i, maxVolume))
                -- Move ffmpeg start time back by 0.1 seconds until maxVolume is below threshold or clip start is the same (or lower) as the previous clip
                while maxVolume > audioThreshold and clipEndTime < nextClipStart do
                    clipEndTime = clipEndTime + 0.1 -- TODO, what happens when we hit the end of the source file? I expect this breaks
                    maxVolume = analyzeAudio(filePath, clipEndTime)
                end
                print(string.format("Adjusted end time to %.2f seconds, max volume: %.2f dB", clipEndTime, maxVolume))
            else
                print(string.format("Clip %d: Audio level acceptable at end (%.2f dB).", i, maxVolume or -999))
            end

            local startFrame = math.floor(clipStartTime * timelineFrameRate)
            local endFrame = math.floor(clipEndTime * timelineFrameRate)

            -- Append the adjusted clip to the new tracks
            local mediaPoolItem = clip:GetMediaPoolItem()
            if mediaPoolItem then
                -- Convert clipStartTime and clipEndTime to frames

                local recordFrame = timecodeToFrames(timeline:GetCurrentTimecode())
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

                local success = media_pool:AppendToTimeline({clipInfo})
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

autoSpace()
