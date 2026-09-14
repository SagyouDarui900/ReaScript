-- @description Split Item by CUE File
-- @version 1.0
-- @about 選択したメディアアイテムをCUEファイルの情報に基づいて分割し、新しいトラックに配置する。

local reaper = reaper

local function parse_cue(file_path)
    local tracks = {}
    local current_track = nil
    
    local f = io.open(file_path, "r")
    if not f then return nil, "ファイルの読み込みに失敗しました" end
    
    for line in f:lines() do
        local track_num = line:match("TRACK%s+(%d+)%s+AUDIO")
        if track_num then
            if current_track and current_track.start_time then
                table.insert(tracks, current_track)
            end
            current_track = { index = tonumber(track_num), title = "", performer = "", start_time = nil }
        end
        
        if current_track then
            local title = line:match('TITLE%s+"([^"]+)"')
            if title then current_track.title = title end
            
            local performer = line:match('PERFORMER%s+"([^"]+)"')
            if performer then current_track.performer = performer end
            
            local m, s, fr = line:match("INDEX%s+01%s+(%d+):(%d+):(%d+)")
            if m and s and fr then
                current_track.start_time = tonumber(m) * 60 + tonumber(s) + tonumber(fr) / 75
            end
        end
    end
    if current_track and current_track.start_time then
        table.insert(tracks, current_track)
    end
    f:close()
    
    for i = 1, #tracks - 1 do
        tracks[i].end_time = tracks[i+1].start_time
    end
    
    return tracks
end

local function copy_and_trim(item, s_time, e_time, target_track)
    if not item or not target_track then return nil, nil end
    local orig_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local offset = s_time - orig_pos
    local length = e_time - s_time
    
    local new_item = reaper.AddMediaItemToTrack(target_track)
    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", s_time)
    reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", length)
    
    local take = reaper.GetActiveTake(item)
    if not take then return nil, nil end
    
    local src = reaper.GetMediaItemTake_Source(take)
    local new_take = reaper.AddTakeToMediaItem(new_item)
    reaper.SetMediaItemTake_Source(new_take, src)
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", offset)
    reaper.SetActiveTake(new_take)
    
    return new_item, new_take
end

local function main()
    local selected_count = reaper.CountSelectedMediaItems(0)
    if selected_count ~= 1 then
        reaper.MB("アイテムを1つだけ選択してください", "Error", 0)
        return
    end

    local item = reaper.GetSelectedMediaItem(0, 0)
    local track = reaper.GetMediaItem_Track(item)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_start + item_length

    local proj_path = reaper.GetProjectPath("").."\\"
    local retval, cue_path = reaper.GetUserFileNameForRead(proj_path, "CUEファイルを選択", ".cue")
    if not retval then return end

    local tracks, err = parse_cue(cue_path)
    if not tracks or #tracks == 0 then
        reaper.MB("CUEファイルの読み込みに失敗したか、トラック情報が見つかりません\n" .. (err or ""), "Error", 0)
        return
    end
    
    tracks[#tracks].end_time = item_length

    reaper.Undo_BeginBlock()

    local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    reaper.InsertTrackAtIndex(track_idx, true)
    local dest_track = reaper.GetTrack(0, track_idx)
    reaper.GetSetMediaTrackInfo_String(dest_track, "P_NAME", "CUE Split", true)

    for _, t in ipairs(tracks) do
        local start_time = item_start + t.start_time
        local end_time = item_start + t.end_time
        
        if end_time > item_end then end_time = item_end end
        
        if start_time < item_end then
            local new_item, new_take = copy_and_trim(item, start_time, end_time, dest_track)
            if new_take then
                local take_name = string.format("%02d. %s - %s", t.index, t.title, t.performer)
                reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", take_name, true)
            end
        end
    end

    reaper.Undo_EndBlock("CUEファイルによるアイテム分割", -1)
    reaper.UpdateArrange()
end

main()
