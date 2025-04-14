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

-- Function to get the file path of a clip
function getClipFilePath(clip)
    local mediaPoolItem = clip:GetMediaPoolItem()
    if mediaPoolItem then
        local clipProperties = mediaPoolItem:GetClipProperty()
        return clipProperties["File Path"]
    end
    return nil
end

-- Function to auto-space clips
function autoSpace()
    if timeline then
        print("Connected to timeline: " .. timeline:GetName())
    else
        print("No timeline is currently open.")
        return
    end

    -- Get all clips in the timeline
    clips = timeline:GetItemListInTrack("video", 1)

    -- Loop through each clip and extract its file path
    for i, clip in ipairs(clips) do
        local filePath = getClipFilePath(clip)
        if filePath then
            print("Clip " .. i .. " file path: " .. filePath)
            -- Pass this file path to FFmpeg for audio analysis
        else
            print("Could not retrieve file path for clip " .. i)
        end
    end

    print("Auto spacing completed.")
end

autoSpace()