-- @description Export VST/AU/CLAP/JSFX List to CSV
-- @version 1.1
-- @author Reaper AI

local sep = package.config:sub(1, 1)
local res_path = reaper.GetResourcePath()
local out_path = res_path .. sep .. "Plugin_List.csv"

local plugins = {}
local seen_keys = {}

local function escape_csv(str)
    if not str then return '""' end
    str = tostring(str):gsub('"', '""')
    return '"' .. str .. '"'
end

local function add_plugin(type_str, category, name, developer, file_path)
    local key = string.format("%s|%s|%s", type_str, name, file_path)
    if seen_keys[key] then return end
    seen_keys[key] = true

    table.insert(plugins, {
        type = type_str,
        category = category,
        name = name,
        developer = developer,
        file = file_path
    })
end

local function parse_vst_clap_ini(filename, default_type)
    local filepath = res_path .. sep .. filename
    local file = io.open(filepath, "r")
    if not file then return end

    for line in file:lines() do
        local file_part, data_part = line:match("^(.-)=(.*)$")
        if file_part and data_part and not file_part:match("^%[") then
            -- 実ファイルが存在するか確認（フルパス記録時）
            local exists = true
            if file_part:match("^%a:[/\\]") or file_part:match("^/") then
                exists = reaper.file_exists(file_part)
            end

            if exists then
                local _, _, rest = data_part:match("^([^,]+),([^,]+),(.*)$")
                if rest then
                    local is_inst = rest:match("!!!VSTi") or rest:match("!!!CLAPi")
                    rest = rest:gsub("!!!.*$", "")
                    rest = rest:gsub(",%s*[%w{}-]+$", "")

                    local name, dev = rest:match("^(.-)%s*%(([^)]+)%)$")
                    if not name then
                        name = rest
                        dev = "Unknown"
                    end

                    local ext = file_part:match("%.([^%.]+)$")
                    local type_str = default_type
                    if ext then
                        ext = ext:upper()
                        if ext == "DLL" or ext == "VST" then type_str = "VST"
                        elseif ext == "VST3" then type_str = "VST3"
                        elseif ext == "CLAP" then type_str = "CLAP"
                        elseif ext == "COMPONENT" then type_str = "AU"
                        end
                    end

                    add_plugin(type_str, is_inst and "Instrument" or "Effect", name, dev, file_part)
                end
            end
        end
    end
    file:close()
end

local function parse_jsfx_ini()
    local filepath = res_path .. sep .. "reaper-jsfx.ini"
    local file = io.open(filepath, "r")
    if not file then return end

    local effects_dir = res_path .. sep .. "Effects" .. sep
    local current_section = ""

    for line in file:lines() do
        local section = line:match("^%[(.-)%]")
        if section then
            current_section = section:lower()
        elseif current_section ~= "tags" then
            local rest = line:match("^[Nn][Aa][Mm][Ee]%s+(.*)$")
            if rest then
                local path_part, desc = rest:match('^"?([^"%s]+)"?%s*"?([^"]*)"?')
                if path_part and path_part ~= "" then
                    local full_jsfx_path = effects_dir .. path_part:gsub("/", sep)
                    if reaper.file_exists(full_jsfx_path) then
                        local category = path_part:match("^(.-)/") or "Utility"
                        local name = (desc and desc ~= "") and desc or (path_part:match("([^/]+)$") or path_part)
                        name = name:gsub("^JS:%s*", "")

                        add_plugin("JSFX", category, name, "JSFX Developer", path_part)
                    end
                end
            end
        end
    end
    file:close()
end

-- 各種設定ファイルの読み込み
parse_vst_clap_ini("reaper-vstplugins64.ini", "VST")
parse_vst_clap_ini("reaper-vstplugins.ini", "VST")
parse_vst_clap_ini("reaper-clapplugins64.ini", "CLAP")
parse_vst_clap_ini("reaper-clapplugins.ini", "CLAP")
parse_vst_clap_ini("reaper-auplugins64.ini", "AU")
parse_vst_clap_ini("reaper-auplugins.ini", "AU")
parse_jsfx_ini()

-- CSV書き出し（BOM付きUTF-8）
local out_file, err_msg = io.open(out_path, "w")
if out_file then
    out_file:write("\xEF\xBB\xBF")
    out_file:write("Type,Category,Name,Developer,File\n")
    for _, p in ipairs(plugins) do
        out_file:write(string.format("%s,%s,%s,%s,%s\n",
            escape_csv(p.type),
            escape_csv(p.category),
            escape_csv(p.name),
            escape_csv(p.developer),
            escape_csv(p.file)
        ))
    end
    out_file:close()
    reaper.ShowConsoleMsg("CSV export completed: " .. out_path .. "\n")
else
    reaper.ShowConsoleMsg("Error: " .. tostring(err_msg) .. "\n")
end
