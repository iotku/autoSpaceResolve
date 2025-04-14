-- Get the Resolve application instance
resolve = app:GetResolve()

-- Get the project manager
projectManager = resolve:GetProjectManager()

-- Get the current project
project = projectManager:GetCurrentProject()

-- Get the current timeline
timeline = project:GetCurrentTimeline()

if project then
    print("Connected to project2: " .. project:GetName())
else
    print("No project is currently open.")
end

-- We consider any audio below -20dB to be silence
audioThreshold = -20

-- Define the path to the FFmpeg executable
local ffmpegPath = "/opt/homebrew/bin/ffmpeg"

-- Function to get the file path of a clip
function getClipFilePath(clip)
    local mediaPoolItem = clip:GetMediaPoolItem()
    if mediaPoolItem then
        local clipProperties = mediaPoolItem:GetClipProperty()
        return clipProperties["File Path"]
    end
    return nil
end


function getClipStartTime(clip)
    local sourceStartTime = clip:GetSourceStartTime()
    print("Clip source start time: " .. sourceStartTime) -- Debug: Print the source start time
    return sourceStartTime
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

    -- Debug: Print the FFmpeg output
    print("FFmpeg output: " .. result)

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

    -- Get all clips in the timeline
    clips = timeline:GetItemListInTrack("video", 1)

    lastClip = nil

    -- Loop through each clip and extract its file path (limit to first 5 clips)
    for i, clip in ipairs(clips) do
        if i > 1 then break end -- Stop after processing 5 clips

        local filePath = getClipFilePath(clip)
        if filePath then
            print("Clip " .. i .. " file path: " .. filePath)
            -- Pass this file path to FFmpeg for audio analysis
            maxVolume = analyzeAudio(filePath, getClipStartTime(clip, timeline:GetSetting("timelineFrameRate")))

            if maxVolume and maxVolume > audioThreshold then -- Adjust threshold as needed
                print(string.format("Clip %d: Audio too loud at start (%.2f dB). Consider adjusting start point.", i, maxVolume))
                -- Logic to adjust the clip's start point can go here
            else
                print(string.format("Clip %d: Audio level acceptable at start (%.2f dB).", i, maxVolume or -999))
            end
        else
            print("Could not retrieve file path for clip " .. i)
        end

        lastClip = clip -- Store last clip in case we need to expand past its outpoint
    end

    print("Auto spacing completed.")
end

autoSpace()