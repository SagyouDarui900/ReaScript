-- @description BMS/BME Importer for OtoMAD/DTM
-- @version 2.5
-- @author Reaper
-- @about
--   BMS/BMEファイルを読み込み、REAPERのトラックにWAV定義ごとのステムとして配置する。

local reaper = reaper

local function get_file_dir(filepath)
    return filepath:match("(.*[\\/])")
end

local function find_audio_file(base_dir, filename)
    if not filename or filename == "" then return nil end
    
    local path = base_dir .. filename
    if reaper.file_exists(path) then return path end
    if reaper.file_exists(base_dir .. filename:lower()) then return base_dir .. filename:lower() end
    
    local base_name = filename:match("(.+)%.%w+$") or filename
    local exts = {".ogg", ".flac", ".wav"}
    
    for _, ext in ipairs(exts) do
        local test_path = base_dir .. base_name .. ext
        if reaper.file_exists(test_path) then return test_path end
        local test_path_lower = base_dir .. base_name:lower() .. ext
        if reaper.file_exists(test_path_lower) then return test_path_lower end
    end

    return path
end

local function parse_bms(filepath)
    local headers = { wav = {}, bpm = {}, stop = {}, volwav = 100 }
    local main_data = {}
    local initial_bpm = 130
    local measure_lengths = {}
    
    local file = io.open(filepath, "r")
    if not file then return nil end
    
    for line in file:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        
        if line:match("^#BPM%s+(%d+%.?%d*)") then
            initial_bpm = tonumber(line:match("^#BPM%s+(%d+%.?%d*)"))
        elseif line:match("^#BPM(%w%w)%s+(%d+%.?%d*)") then
            local id, val = line:match("^#BPM(%w%w)%s+(%d+%.?%d*)")
            headers.bpm[id:upper()] = tonumber(val)
        elseif line:match("^#STOP(%w%w)%s+(%d+)") then
            local id, val = line:match("^#STOP(%w%w)%s+(%d+)")
            headers.stop[id:upper()] = tonumber(val)
        elseif line:match("^#VOLWAV%s+(%d+)") then
            headers.volwav = tonumber(line:match("^#VOLWAV%s+(%d+)"))
        elseif line:match("^#WAV(%w%w)%s+(.+)") then
            local id, filename = line:match("^#WAV(%w%w)%s+(.+)")
            headers.wav[id:upper()] = filename
        elseif line:match("^#(%d%d%d)(%w%w):(.*)") then
            local measure_str, ch, data = line:match("^#(%d%d%d)(%w%w):(.*)")
            local measure = tonumber(measure_str)
            ch = ch:upper()
            
            if ch == "02" then
                measure_lengths[measure] = tonumber(data) or 1.0
            else
                local len = string.len(data)
                local obj_count = math.floor(len / 2)
                for i = 0, obj_count - 1 do
                    local obj_val = string.sub(data, i * 2 + 1, i * 2 + 2):upper()
                    if obj_val ~= "00" then
                        local pos = i / obj_count
                        table.insert(main_data, {
                            measure = measure,
                            pos = pos,
                            ch = ch,
                            val = obj_val
                        })
                    end
                end
            end
        end
    end
    file:close()
    
    -- 各小節の開始拍（絶対位置）を計算
    local measure_start_beats = {}
    local current_measure_beat = 0.0
    for m = 0, 999 do
        measure_start_beats[m] = current_measure_beat
        local m_len = measure_lengths[m] or 1.0
        current_measure_beat = current_measure_beat + (m_len * 4.0)
    end
    
    local timeline_events = {}
    for _, ev in ipairs(main_data) do
        local m_len = measure_lengths[ev.measure] or 1.0
        local beat_pos = measure_start_beats[ev.measure] + (ev.pos * m_len * 4.0)
        table.insert(timeline_events, {
            beat_pos = beat_pos,
            ch = ev.ch,
            val = ev.val
        })
    end
    
    table.sort(timeline_events, function(a, b)
        return a.beat_pos < b.beat_pos
    end)
    
    local current_bpm = initial_bpm
    local current_time = 0.0
    local last_beat_pos = 0.0
    local final_events = {}
    local tempo_events = { {time = 0.0, bpm = initial_bpm} }
    
    for _, ev in ipairs(timeline_events) do
        local delta_beats = ev.beat_pos - last_beat_pos
        if delta_beats > 0 then
            current_time = current_time + (delta_beats * 60.0 / current_bpm)
            last_beat_pos = ev.beat_pos
        end
        
        if ev.ch == "03" then
            local new_bpm = tonumber(ev.val, 16)
            if new_bpm and new_bpm > 0 and new_bpm ~= current_bpm then
                current_bpm = new_bpm
                table.insert(tempo_events, {time = current_time, bpm = current_bpm})
            end
        elseif ev.ch == "08" then
            local new_bpm = headers.bpm[ev.val]
            if new_bpm and new_bpm > 0 and new_bpm ~= current_bpm then
                current_bpm = new_bpm
                table.insert(tempo_events, {time = current_time, bpm = current_bpm})
            end
        elseif ev.ch == "09" then
            local stop_val = headers.stop[ev.val]
            if stop_val then
                local stop_beats = stop_val / 48.0
                current_time = current_time + (stop_beats * 60.0 / current_bpm)
            end
        elseif ev.ch == "01" or ev.ch:match("^[1-6][%w]$") then
            table.insert(final_events, {
                time = current_time,
                wav_id = ev.val
            })
        end
    end
    
    return headers, final_events, tempo_events
end

local function main()
    local retval, filepath = reaper.GetUserFileNameForRead("", "Select BMS/BME/BML file", "")
    if not retval then return end
    
    local base_dir = get_file_dir(filepath)
    local headers, events, tempo_events = parse_bms(filepath)
    
    if not events or #events == 0 then
        reaper.ShowMessageBox("No valid notes found or failed to parse.", "Error", 0)
        return
    end
    
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    
    reaper.SNM_SetIntConfigVar("projtimebase", 0)
    
    for _, tm in ipairs(tempo_events) do
        reaper.SetTempoTimeSigMarker(0, -1, tm.time, -1, -1, tm.bpm, 0, 0, false)
    end
    reaper.UpdateTimeline()
    
    local track_map = {}
    local max_track_idx = reaper.CountTracks(0)
    local used_wav_ids = {}
    
    for _, ev in ipairs(events) do
        used_wav_ids[ev.wav_id] = true
    end
    
    local sorted_wavs = {}
    for wav_id, filename in pairs(headers.wav) do
        if used_wav_ids[wav_id] then
            table.insert(sorted_wavs, {id = wav_id, name = filename})
        end
    end
    table.sort(sorted_wavs, function(a, b) return a.name:lower() < b.name:lower() end)
    
    -- ファイル名のプレフィックスを抽出してグループを作成
    local groups = {}
    local group_names = {}
    for _, w in ipairs(sorted_wavs) do
        local prefix = w.name:match("^([%a]+)") or "other"
        prefix = prefix:lower()
        
        if not groups[prefix] then
            groups[prefix] = {}
            table.insert(group_names, prefix)
        end
        table.insert(groups[prefix], w)
    end
    table.sort(group_names)
    
    -- ルートフォルダの作成
    local root_folder_idx = max_track_idx
    reaper.InsertTrackAtIndex(root_folder_idx, false)
    local root_folder_track = reaper.GetTrack(0, root_folder_idx)
    reaper.GetSetMediaTrackInfo_String(root_folder_track, "P_NAME", "BMS Stems", true)
    reaper.SetMediaTrackInfo_Value(root_folder_track, "I_FOLDERDEPTH", 1)
    max_track_idx = max_track_idx + 1

    -- サブグループフォルダとトラックの作成
    for i, g_name in ipairs(group_names) do
        local wavs = groups[g_name]
        
        reaper.InsertTrackAtIndex(max_track_idx, false)
        local group_track = reaper.GetTrack(0, max_track_idx)
        reaper.GetSetMediaTrackInfo_String(group_track, "P_NAME", "Grp: " .. g_name, true)
        reaper.SetMediaTrackInfo_Value(group_track, "I_FOLDERDEPTH", 1)
        max_track_idx = max_track_idx + 1
        
        for j, w in ipairs(wavs) do
            local wav_id = w.id
            local filename = w.name
            
            reaper.InsertTrackAtIndex(max_track_idx, false)
            local track = reaper.GetTrack(0, max_track_idx)
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", string.format("[%s] %s", wav_id, filename), true)
            
            local depth = 0
            if j == #wavs then
                depth = -1
                if i == #group_names then
                    depth = -2
                end
            end
            reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", depth)
            
            track_map[wav_id] = track
            max_track_idx = max_track_idx + 1
        end
    end
    
    local vol_mult = headers.volwav / 100.0
    local last_items = {}

    for _, ev in ipairs(events) do
        local target_track = track_map[ev.wav_id]
        if target_track then
            local filename = headers.wav[ev.wav_id]
            local audio_path = find_audio_file(base_dir, filename)
            
            if audio_path then
                local prev_data = last_items[ev.wav_id]
                if prev_data then
                    local prev_item = prev_data.item
                    local prev_start = prev_data.start_time
                    if reaper.ValidatePtr(prev_item, "MediaItem*") then
                        local prev_len = reaper.GetMediaItemInfo_Value(prev_item, "D_LENGTH")
                        if prev_start + prev_len > ev.time then
                            local new_len = ev.time - prev_start
                            if new_len < 0 then new_len = 0 end
                            reaper.SetMediaItemLength(prev_item, new_len, false)
                        end
                    end
                end

                local item = reaper.AddMediaItemToTrack(target_track)
                reaper.SetMediaItemPosition(item, ev.time, false)
                local take = reaper.AddTakeToMediaItem(item)
                
                local src = reaper.PCM_Source_CreateFromFile(audio_path)
                if src then
                    reaper.SetMediaItemTake_Source(take, src)
                    local src_len = reaper.GetMediaSourceLength(src)
                    reaper.SetMediaItemLength(item, src_len, false)
                else
                    reaper.SetMediaItemLength(item, 1.0, false)
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "OFFLINE: " .. tostring(filename), true)
                end
                
                reaper.SetMediaItemInfo_Value(item, "D_VOL", vol_mult)
                reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0)
                reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)
                reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
                
                last_items[ev.wav_id] = { item = item, start_time = ev.time }
            end
        end
    end
    
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Import BMS Stems v2.4", -1)
end

main()   
