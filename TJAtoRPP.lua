-- @description TJA Importer (Don/Ka Note Placer)
-- @version 1.0
-- @about .tja ファイルを読み込み、ノーツタイプに応じてトラックに空のMIDIアイテムとして配置する。

local reaper = reaper

local function Msg(str)
    reaper.ShowConsoleMsg(str .. "\n")
end

local function main()
    local retval, file_path = reaper.GetUserFileNameForRead("", "TJAファイルを選択してください", "*.tja")
    if retval == 0 or not file_path then return end

    local file = io.open(file_path, "r")
    if not file then
        Msg("ファイルを開けません: " .. file_path)
        return
    end
    local content = file:read("*a")
    file:close()
    
    local content_upper = content:upper()

    local courses = {}
    for course_name in string.gmatch(content_upper, "COURSE:(%w+)") do
        table.insert(courses, course_name)
    end
    
    local selected_course_name = ""

    if #courses == 0 then
        selected_course_name = "DEFAULT"
        Msg("COURSEタグが見つかりません。ファイル全体の譜面を読み込みます。")
    elseif #courses > 1 then
        reaper.ClearConsole()
        Msg("TJAファイルから読み込むコースを選択してください:\n")
        for i, name in ipairs(courses) do
            Msg(string.format("%d: %s", i, name))
        end
        Msg("\n")

        local caption = "コンソールに表示されたコース番号を入力してください (1-" .. #courses .. "):"
        local retval_input, selected_index_str = reaper.GetUserInputs("TJA コース選択", 1, caption, "1")
        if retval_input == 0 then return end
        
        local selected_index = tonumber(selected_index_str)
        if not selected_index or selected_index < 1 or selected_index > #courses then
            Msg("無効な番号が入力されました。処理を中止します。")
            return
        end
        selected_course_name = courses[selected_index]
    else
        selected_course_name = courses[1]
    end

    local bpm = 120
    local offset = 0
    
    local bpm_match = string.match(content_upper, "#?BPM: *([%d.]+)")
    if bpm_match then bpm = tonumber(bpm_match) end
    
    local offset_match = string.match(content_upper, "#?OFFSET: *([-%d.]+)")
    if offset_match then offset = tonumber(offset_match) end

    local score_data_raw = ""
    
    if selected_course_name ~= "DEFAULT" then
        local start_pos = string.find(content_upper, "COURSE:" .. selected_course_name)
        if not start_pos then
            Msg("選択されたコースが見つかりません: " .. selected_course_name)
            return
        end
        
        local start_data_pos = string.find(content_upper, "#START", start_pos)
        if not start_data_pos then
            Msg("選択されたコースに #START が見つかりません。")
            return
        end
        
        local score_block = string.sub(content_upper, start_data_pos)
        
        local end_pos = string.find(score_block, "#END")
        local next_course_pos = string.find(score_block, "\nCOURSE:")
        
        local end_index = -1
        if end_pos then end_index = end_pos end
        
        if next_course_pos and (end_index == -1 or next_course_pos < end_index) then
            end_index = next_course_pos
        end
        
        if end_index > -1 then
            score_data_raw = string.sub(score_block, 1, end_index - 1)
        else
            score_data_raw = score_block
        end
    else
        local start_data_pos = string.find(content_upper, "#START")
        if not start_data_pos then
             Msg("譜面データ (#START) が見つかりません。")
             return
        end
        
        local score_block = string.sub(content_upper, start_data_pos)
        local end_pos = string.find(score_block, "#END")
        
        if end_pos then
            score_data_raw = string.sub(score_block, 1, end_pos - 1)
        else
            score_data_raw = score_block
        end
    end
    
    score_data_raw = score_data_raw:gsub("#START", "")

    local has_branch = string.find(score_data_raw, "#BRANCHSTART")
    local branch_preference = 1
    
    if has_branch then
        reaper.ClearConsole()
        Msg("譜面分岐が検出されました。\n読み込む譜面を番号で指定してください:\n\n1: 普通譜面 (Normal)\n2: 玄人譜面 (Expert)\n3: 達人譜面 (Master)\n\n")
        local retval_input, branch_str = reaper.GetUserInputs("譜面分岐の選択", 1, "コンソールで番号を確認し、入力してください (1-3):", "1")
        if retval_input == 0 then return end
        branch_preference = tonumber(branch_str) or 1
        if branch_preference < 1 or branch_preference > 3 then branch_preference = 1 end
    end
    
    reaper.Undo_BeginBlock()
    
    local proj = 0 
    local default_ts_num = 4
    local default_ts_denom = 4
    local default_lineartempo = false

    local retval, timepos, measurepos, beatpos, old_bpm, timesig_num, timesig_denom, lineartempo = reaper.GetTempoTimeSigMarker(proj, 0)
    if retval then
        reaper.SetTempoTimeSigMarker(proj, 0, 0.0, -1, -1, bpm, timesig_num, timesig_denom, lineartempo)
        default_ts_num = timesig_num
        default_ts_denom = timesig_denom
    else
        reaper.SetTempoTimeSigMarker(proj, -1, 0.0, -1, -1, bpm, default_ts_num, default_ts_denom, default_lineartempo)
    end
    
    if offset ~= 0.0 then
        reaper.SetTempoTimeSigMarker(proj, -1, offset, 1, 0.0, bpm, default_ts_num, default_ts_denom, default_lineartempo)
    end
    
    local base_track_idx = reaper.CountTracks()
    reaper.InsertTrackAtIndex(base_track_idx, true)
    reaper.InsertTrackAtIndex(base_track_idx + 1, true)
    reaper.InsertTrackAtIndex(base_track_idx + 2, true)
    reaper.InsertTrackAtIndex(base_track_idx + 3, true)
    reaper.InsertTrackAtIndex(base_track_idx + 4, true)

    local don_track     = reaper.GetTrack(0, base_track_idx)
    local ka_track      = reaper.GetTrack(0, base_track_idx + 1)
    local don_dai_track = reaper.GetTrack(0, base_track_idx + 2)
    local ka_dai_track  = reaper.GetTrack(0, base_track_idx + 3)
    local renda_track   = reaper.GetTrack(0, base_track_idx + 4)

    local suffix = " (" .. selected_course_name .. ")"
    reaper.GetSetMediaTrackInfo_String(don_track,     "P_NAME", "ドン(小)" .. suffix, true)
    reaper.GetSetMediaTrackInfo_String(ka_track,      "P_NAME", "カッ(小)" .. suffix, true)
    reaper.GetSetMediaTrackInfo_String(don_dai_track, "P_NAME", "ドン(大)" .. suffix, true)
    reaper.GetSetMediaTrackInfo_String(ka_dai_track,  "P_NAME", "カッ(大)" .. suffix, true)
    reaper.GetSetMediaTrackInfo_String(renda_track,   "P_NAME", "連打" .. suffix, true)

    local function CreateNoteItem(target_track, note_time, item_length)
        if target_track then
            if item_length < 0.001 then return end
            
            local item = reaper.CreateNewMIDIItemInProj(target_track, note_time, note_time + item_length, false)
            if item then
                local take = reaper.GetActiveTake(item)
                if take then
                    local fx_count = reaper.TakeFX_GetCount(take)
                    if fx_count > 0 then
                        for i = fx_count - 1, 0, -1 do
                            local retval, fx_name = reaper.TakeFX_GetFXName(take, i, "", 1024)
                            if retval and fx_name == "Video Processor" then
                                reaper.TakeFX_Delete(take, i)
                            end
                        end
                    end
                end
            end
        end
    end

    local current_time = offset
    local seconds_per_beat = 60.0 / bpm
    local current_measure_length_beats = 4.0
    local measure_count = 0
    
    local is_in_roll = false
    local roll_start_time = 0
    local roll_track = nil
    
    local in_branch = false
    local current_branch = 1

    for line in string.gmatch(score_data_raw, "([^\r\n]+)") do
        local clean_line = line:gsub("//[^\n]*", ""):match("^%s*(.-)%s*$")
        
        if clean_line ~= "" then
            if clean_line:sub(1, 1) == "#" then
                if clean_line == "#BRANCHSTART" then in_branch = true; current_branch = 1 end
                if clean_line == "#N" then current_branch = 1 end
                if clean_line == "#E" then current_branch = 2 end
                if clean_line == "#M" then current_branch = 3 end
                if clean_line == "#BRANCHEND" then in_branch = false; current_branch = 1 end
                
                local new_bpm_str = clean_line:match("#BPMCHANGE:([%d.]+)")
                if new_bpm_str then
                    bpm = tonumber(new_bpm_str)
                    seconds_per_beat = 60.0 / bpm
                    reaper.SetTempoTimeSigMarker(proj, -1, current_time, -1, -1, bpm, -1, -1, default_lineartempo)
                end
                
                local num_str, den_str = clean_line:match("#MEASURE:(%d+)/(%d+)")
                if num_str and den_str then
                    local num = tonumber(num_str)
                    local den = tonumber(den_str)
                    if num and den and den > 0 then
                        current_measure_length_beats = (num / den) * 4.0
                        reaper.SetTempoTimeSigMarker(proj, -1, current_time, -1, -1, -1, num, den, default_lineartempo)
                    end
                end
                
            elseif clean_line:sub(-1) == "," then
                local note_data_raw = clean_line:sub(1, -2)
                local notes_in_measure = string.len(note_data_raw)
                
                if notes_in_measure > 0 then
                    local seconds_per_measure = seconds_per_beat * current_measure_length_beats
                    local time_per_note_char = seconds_per_measure / notes_in_measure
                    
                    if (not in_branch) or (in_branch and current_branch == branch_preference) then
                        for i = 1, notes_in_measure do
                            local char = string.sub(note_data_raw, i, i)
                            local note_time = current_time + (time_per_note_char * (i - 1))
                            
                            local target_track = nil
                    
                            if char == '8' and is_in_roll then
                                is_in_roll = false
                                local item_length = note_time - roll_start_time
                                CreateNoteItem(roll_track, roll_start_time, item_length)
                                roll_track = nil
                            
                            elseif (char == '5' or char == '6' or char == '7') and not is_in_roll then
                                is_in_roll = true
                                roll_start_time = note_time
                                roll_track = renda_track
                            
                            elseif not is_in_roll then
                                if char == '1' then target_track = don_track
                                elseif char == '2' then target_track = ka_track
                                elseif char == '3' then target_track = don_dai_track
                                elseif char == '4' then target_track = ka_dai_track
                                end
                                
                                if target_track then
                                    local calculated_length = time_per_note_char
                                    local item_length = math.min(calculated_length, 0.5) 
                                    CreateNoteItem(target_track, note_time, item_length)
                                end
                            end
                        end
                    end
                    
                    current_time = current_time + seconds_per_measure
                    measure_count = measure_count + 1
                else
                    current_time = current_time + (seconds_per_beat * current_measure_length_beats)
                    measure_count = measure_count + 1
                end
            end
        end
    end
    
    if is_in_roll then
        Msg("警告: 連打(5,6,7)が '8' で閉じられずに譜面が終了しました。")
        local item_length = current_time - roll_start_time
        CreateNoteItem(roll_track, roll_start_time, item_length)
    end
    
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("TJAからノーツアイテムを配置 (" .. selected_course_name .. ")", -1)
    
    Msg(string.format("TJA読み込み完了 (%s): %d 小節を処理しました。\nプロジェクトテンポを %.2f に、オフセットを %.2f に設定しました。\n", selected_course_name, measure_count, bpm, offset))
end

main()
