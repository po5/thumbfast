-- thumbfast.lua
--
-- High-performance on-the-fly thumbnailer
--
-- Built for easy integration in third-party UIs.

--[[
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
]]

local options = {
    -- Socket path (leave empty for auto)
    socket = "",

    -- Thumbnail path (leave empty for auto)
    thumbnail = "",

    -- Maximum thumbnail generation size in pixels (scaled down to fit)
    -- Values are scaled when hidpi is enabled
    max_height = 200,
    max_width = 200,

    -- Scale factor for thumbnail display size (requires mpv 0.38+)
    -- Note that this is lower quality than increasing max_height and max_width
    scale_factor = 1,

    -- Apply tone-mapping, no to disable
    tone_mapping = "auto",

    -- Overlay id
    overlay_id = 42,

    -- Spawn thumbnailer on file load for faster initial thumbnails
    spawn_first = false,

    -- Close thumbnailer process after an inactivity period in seconds, 0 to disable
    quit_after_inactivity = 0,

    -- Enable on network playback
    network = true,

    -- Enable on audio playback
    audio = false,

    -- Enable hardware decoding
    hwdec = false,

    -- Windows only: use native Windows API to write to pipe (requires LuaJIT)
    direct_io = false,

    -- Custom path to the mpv executable
    mpv_path = "mpv"
}

mp.utils = require "mp.utils"
mp.options = require "mp.options"
mp.options.read_options(options, "thumbfast")

local properties = {}
local pre_0_30_0 = mp.command_native_async == nil
local pre_0_33_0 = true
local support_media_control = mp.get_property_native("media-controls") ~= nil

function subprocess(args, async, callback)
    callback = callback or function() end

    if not pre_0_30_0 then
        if async then
            return mp.command_native_async({name = "subprocess", playback_only = true, capture_stdout = true, capture_stderr = true, args = args, env = "PATH="..os.getenv("PATH")}, callback)
        else
            return mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true, args = args, env = "PATH="..os.getenv("PATH")})
        end
    else
        if async then
            return mp.utils.subprocess_detached({args = args}, callback)
        else
            return mp.utils.subprocess({args = args})
        end
    end
end

local all_processes = {}
local process_queue = {}
local active_processes = 0
local max_processes = 5
local ytdl_subprocess_cancel = nil

local function spawn_one(args, callback)
    if active_processes < max_processes then
        active_processes = active_processes + 1
        local abort = subprocess(args, true, callback)
        for i, process in ipairs(process_queue) do
            if process.args == args then
                table.remove(process_queue, i)
                break
            end
        end
        for i, process in ipairs(all_processes) do
            if process.args == args then
                all_processes[i] = abort
                break
            end
        end
    end
end

local function spawn_queued_process(args, callback)
    local function wrap_callback(callback)
        return function(...)
            callback(...)
            active_processes = active_processes - 1
            if #process_queue > 0 then
                spawn_one(process_queue[1].args, process_queue[1].callback)
            end
        end
    end
    local wrapped_callback = wrap_callback(callback)
    local process = {args=args, callback=wrapped_callback}
    table.insert(process_queue, process)
    table.insert(all_processes, process)
    spawn_one(args, wrapped_callback)
end

local function prioritize_process(atlas_index)
    local target_process = all_processes[atlas_index]
    if not target_process or not target_process.args then return end

    for i, process in ipairs(process_queue) do
        if process.args == target_process.args then
            if i ~= 1 then
                table.remove(process_queue, i)
                table.insert(process_queue, 1, process)
            end
            break
        end
    end
end

local function cancel_queued_processes()
    for i, process in ipairs(all_processes) do
        if process and not process.args then
            mp.abort_async_command(process)
        end
    end
    all_processes = {}
    process_queue = {}
    if ytdl_subprocess_cancel ~= nil then
        mp.abort_async_command(ytdl_subprocess_cancel)
        ytdl_subprocess_cancel = nil
    end
end

local function closest_preceeding_thumbnail(tbl, target)
    for offset = 0, target - 1 do
        if tbl[target - offset] then
            return tbl[target - offset]
        end
    end
end

local winapi = {}
if options.direct_io then
    local ffi_loaded, ffi = pcall(require, "ffi")
    if ffi_loaded then
        winapi = {
            ffi = ffi,
            C = ffi.C,
            bit = require("bit"),
            socket_wc = "",

            -- WinAPI constants
            CP_UTF8 = 65001,
            GENERIC_WRITE = 0x40000000,
            OPEN_EXISTING = 3,
            FILE_FLAG_WRITE_THROUGH = 0x80000000,
            FILE_FLAG_NO_BUFFERING = 0x20000000,
            PIPE_NOWAIT = ffi.new("unsigned long[1]", 0x00000001),

            INVALID_HANDLE_VALUE = ffi.cast("void*", -1),

            -- don't care about how many bytes WriteFile wrote, so allocate something to store the result once
            _lpNumberOfBytesWritten = ffi.new("unsigned long[1]"),
        }
        -- cache flags used in run() to avoid bor() call
        winapi._createfile_pipe_flags = winapi.bit.bor(winapi.FILE_FLAG_WRITE_THROUGH, winapi.FILE_FLAG_NO_BUFFERING)

        ffi.cdef[[
            void* __stdcall CreateFileW(const wchar_t *lpFileName, unsigned long dwDesiredAccess, unsigned long dwShareMode, void *lpSecurityAttributes, unsigned long dwCreationDisposition, unsigned long dwFlagsAndAttributes, void *hTemplateFile);
            bool __stdcall WriteFile(void *hFile, const void *lpBuffer, unsigned long nNumberOfBytesToWrite, unsigned long *lpNumberOfBytesWritten, void *lpOverlapped);
            bool __stdcall CloseHandle(void *hObject);
            bool __stdcall SetNamedPipeHandleState(void *hNamedPipe, unsigned long *lpMode, unsigned long *lpMaxCollectionCount, unsigned long *lpCollectDataTimeout);
            int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
        ]]

        winapi.MultiByteToWideChar = function(MultiByteStr)
            if MultiByteStr then
                local utf16_len = winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, nil, 0)
                if utf16_len > 0 then
                    local utf16_str = winapi.ffi.new("wchar_t[?]", utf16_len)
                    if winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, utf16_str, utf16_len) > 0 then
                        return utf16_str
                    end
                end
            end
            return ""
        end

    else
        options.direct_io = false
    end
end

local file
local file_bytes = 0
local spawned = false
local disabled = false
local force_disabled = false
local spawn_waiting = false
local spawn_working = false
local script_written = false
local using_storyboards = false
local thumbnail_delta = nil
local thumb_count_per_storyboard = 1
local storyboard_thumbnails = {}

local dirty = false

local x, y
local last_x, last_y

local last_seek_time

local effective_w, effective_h = options.max_width, options.max_height
local real_w, real_h
local last_real_w, last_real_h

local script_name

local show_thumbnail = false

local filters_reset = {["lavfi-crop"]=true, ["crop"]=true}
local filters_runtime = {["hflip"]=true, ["vflip"]=true}
local filters_all = {["hflip"]=true, ["vflip"]=true, ["lavfi-crop"]=true, ["crop"]=true}

local tone_mappings = {["none"]=true, ["clip"]=true, ["linear"]=true, ["gamma"]=true, ["reinhard"]=true, ["hable"]=true, ["mobius"]=true}
local last_tone_mapping

local lavfi_crop = {}
local storyboard_transpose = false

local last_vf_reset = ""
local last_vf_runtime = ""

local last_rotate = 0

local par = ""
local last_par = ""

local last_crop = nil

local last_has_vid = 0
local has_vid = 0

local file_timer
local file_check_period = 1/60

local allow_fast_seek = true

local client_script = [=[
#!/usr/bin/env bash
MPV_IPC_FD=0; MPV_IPC_PATH="%s"
trap "kill 0" EXIT
while [[ $# -ne 0 ]]; do case $1 in --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;; esac; shift; done
if echo "print-text thumbfast" >&"$MPV_IPC_FD"; then echo -n > "$MPV_IPC_PATH"; tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" & while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done; fi
]=]

local function get_os()
    local raw_os_name = ""

    if jit and jit.os and jit.arch then
        raw_os_name = jit.os
    else
        if package.config:sub(1,1) == "\\" then
            -- Windows
            local env_OS = os.getenv("OS")
            if env_OS then
                raw_os_name = env_OS
            end
        else
            raw_os_name = subprocess({"uname", "-s"}).stdout
        end
    end

    raw_os_name = (raw_os_name):lower()

    local os_patterns = {
        ["windows"] = "windows",
        ["linux"]   = "linux",

        ["osx"]     = "darwin",
        ["mac"]     = "darwin",
        ["darwin"]  = "darwin",

        ["^mingw"]  = "windows",
        ["^cygwin"] = "windows",

        ["bsd$"]    = "darwin",
        ["sunos"]   = "darwin"
    }

    -- Default to linux
    local str_os_name = "linux"

    for pattern, name in pairs(os_patterns) do
        if raw_os_name:match(pattern) then
            str_os_name = name
            break
        end
    end

    return str_os_name
end

local os_name = mp.get_property("platform") or get_os()

local path_separator = os_name == "windows" and "\\" or "/"

if options.socket == "" then
    if os_name == "windows" then
        options.socket = "thumbfast"
    else
        options.socket = "/tmp/thumbfast"
    end
end

if options.thumbnail == "" then
    if os_name == "windows" then
        options.thumbnail = os.getenv("TEMP").."\\thumbfast.out"
    else
        options.thumbnail = "/tmp/thumbfast.out"
    end
end

local unique = mp.utils.getpid()

options.socket = options.socket .. unique
options.thumbnail = options.thumbnail .. unique

local thumbnail_path = options.thumbnail

if options.direct_io then
    if os_name == "windows" then
        winapi.socket_wc = winapi.MultiByteToWideChar("\\\\.\\pipe\\" .. options.socket)
    end

    if winapi.socket_wc == "" then
        options.direct_io = false
    end
end

options.scale_factor = math.floor(options.scale_factor)

local mpv_path = options.mpv_path
local frontend_path

if mpv_path == "mpv" and os_name == "windows" then
    frontend_path = mp.get_property_native("user-data/frontend/process-path")
    mpv_path = frontend_path or mpv_path
end

if mpv_path == "mpv" and os_name == "darwin" and unique then
    -- TODO: look into ~~osxbundle/
    mpv_path = string.gsub(subprocess({"ps", "-o", "comm=", "-p", tostring(unique)}).stdout, "[\n\r]", "")
    if mpv_path ~= "mpv" then
        mpv_path = string.gsub(mpv_path, "/mpv%-bundle$", "/mpv")
        local mpv_bin = mp.utils.file_info("/usr/local/mpv")
        if mpv_bin and mpv_bin.is_file then
            mpv_path = "/usr/local/mpv"
        else
            local mpv_app = mp.utils.file_info("/Applications/mpv.app/Contents/MacOS/mpv")
            if mpv_app and mpv_app.is_file then
                mp.msg.warn("symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            else
                mp.msg.warn("drag to your Applications folder and symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            end
        end
    end
end

local function vo_tone_mapping()
    local passes = mp.get_property_native("vo-passes")
    if passes and passes["fresh"] then
        for k, v in pairs(passes["fresh"]) do
            for k2, v2 in pairs(v) do
                if k2 == "desc" and v2 then
                    local tone_mapping = string.match(v2, "([0-9a-z.-]+) tone map")
                    if tone_mapping then
                        return tone_mapping
                    end
                end
            end
        end
    end
end

local function vf_string_simple(filters, vf)
    local vf_table = properties["vf"]

    if vf_table and #vf_table > 0 then
        for i = #vf_table, 1, -1 do
            if filters[vf_table[i].name] then
                local args = ""
                for key, value in pairs(vf_table[i].params) do
                    if args ~= "" then
                        args = args .. ":"
                    end
                    args = args .. key .. "=" .. value
                end
                vf = vf .. vf_table[i].name .. "=" .. args .. ","
            end
        end
    end

    return vf
end

local function vf_string(filters, full)
    local vf = ""

    if (properties["video-crop"] or "") ~= "" then
        vf = "lavfi-crop="..string.gsub(properties["video-crop"], "(%d*)x?(%d*)%+(%d+)%+(%d+)", "w=%1:h=%2:x=%3:y=%4")..","
        local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
        local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
        if width and height then
            vf = string.gsub(vf, "w=:h=:", "w="..width..":h="..height..":")
        end
    end

    vf = vf_string_simple(filters, vf)

    -- TODO: don't apply to storyboards???
    if (full and options.tone_mapping ~= "no") or options.tone_mapping == "auto" then
        if properties["video-params"] and properties["video-params"]["primaries"] == "bt.2020" then
            local tone_mapping = options.tone_mapping
            if tone_mapping == "auto" then
                tone_mapping = last_tone_mapping or properties["tone-mapping"]
                if tone_mapping == "auto" and properties["current-vo"] == "gpu-next" then
                    tone_mapping = vo_tone_mapping()
                end
            end
            if not tone_mappings[tone_mapping] then
                tone_mapping = "hable"
            end
            last_tone_mapping = tone_mapping
            vf = vf .. "zscale=transfer=linear,format=gbrpf32le,tonemap="..tone_mapping..",zscale=transfer=bt709,"
        end
    end

    if full then
        vf = vf.."scale=w="..effective_w..":h="..effective_h..par..",pad=w="..effective_w..":h="..effective_h..":x=-1:y=-1,format=bgra"
    end

    return vf
end

local function calc_dimensions()
    local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
    local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
    if not width or not height then return end

    local scale = properties["display-hidpi-scale"] or 1

    if width / height > options.max_width / options.max_height then
        effective_w = math.floor(options.max_width * scale + 0.5)
        effective_h = math.floor(height / width * effective_w + 0.5)
    else
        effective_h = math.floor(options.max_height * scale + 0.5)
        effective_w = math.floor(width / height * effective_h + 0.5)
    end

    local v_par = properties["video-out-params"] and properties["video-out-params"]["par"] or 1
    if v_par == 1 then
        par = ":force_original_aspect_ratio=decrease"
    else
        par = ""
    end
end

local info_timer = nil

local function info(w, h)
    local rotate = properties["video-params"] and properties["video-params"]["rotate"]
    local image = properties["current-tracks/video"] and properties["current-tracks/video"]["image"]
    local albumart = image and properties["current-tracks/video"]["albumart"]

    disabled = (w or 0) == 0 or (h or 0) == 0 or
        has_vid == 0 or
        (properties["demuxer-via-network"] and not options.network) or
        (albumart and not options.audio) or
        (image and not albumart) or
        force_disabled

    if info_timer then
        info_timer:kill()
        info_timer = nil
    elseif has_vid == 0 or (rotate == nil and not disabled) then
        info_timer = mp.add_timeout(0.05, function() info(w, h) end)
    end

    local json, err = mp.utils.format_json({width=w * options.scale_factor, height=h * options.scale_factor, scale_factor=options.scale_factor, disabled=disabled, available=true, socket=options.socket, thumbnail=options.thumbnail, overlay_id=options.overlay_id}) -- TODO: add storyboard info
    if pre_0_30_0 then
        mp.command_native({"script-message", "thumbfast-info", json})
    else
        mp.command_native_async({"script-message", "thumbfast-info", json}, function() end)
    end
end

local function remove_thumbnail_files()
    if file then
        file:close()
        file = nil
        file_bytes = 0
    end
    os.remove(options.thumbnail)
    os.remove(options.thumbnail..".bgra")
end

local function remove_storyboard_files()
    local atlas = 0
    for thumb_index, thumb_filename in pairs(storyboard_thumbnails) do
        atlas_index = math.ceil(thumb_index / thumb_count_per_storyboard)
        if atlas_index > atlas then
            atlas = atlas_index
            os.remove(options.thumbnail..".ytdl"..tostring(atlas_index))
        end
        os.remove(thumb_filename..".bgra")
    end
end

local activity_timer

local function spawn(time)
    if disabled then return end

    local path = properties["path"]
    if path == nil then return end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    remove_thumbnail_files()
    remove_storyboard_files()
    thumbnail_path = options.thumbnail

    local vid = properties["vid"]
    has_vid = vid or 0

    -- TODO: add filtered ytdl-raw-options, especially for 'cookies' option, and maybe 'extractor-args' too
    -- TODO: use native property for cookies and cookies-file??

    local args = {
        mpv_path, "--no-config", "--msg-level=all=no", "--idle", "--pause", "--keep-open=always", "--really-quiet", "--no-terminal",
        "--load-scripts=no", "--osc=no", "--load-stats-overlay=no", "--load-osd-console=no", "--load-auto-profiles=no",
        "--edition="..(properties["edition"] or "auto"), "--vid="..(vid or "auto"), "--no-sub", "--no-audio",
        "--start="..time, allow_fast_seek and "--hr-seek=no" or "--hr-seek=yes",
        "--ytdl-format=worst", "--demuxer-readahead-secs=0", "--demuxer-max-bytes=128KiB",
        "--http-header-fields="..(properties["http-header-fields"] or ""), -- does this actually work well with SVP?
        "--cookies="..(properties["cookies"] or "no"),
        "--cookies-file="..(properties["cookies-file"] or ""),
        "--vd-lavc-skiploopfilter=all", "--vd-lavc-software-fallback=1", "--vd-lavc-fast", "--vd-lavc-threads=2", "--hwdec="..(options.hwdec and "auto" or "no"),
        "--vf="..vf_string(filters_all, true),
        "--sws-scaler=fast-bilinear",
        "--video-rotate="..last_rotate,
        "--ovc=rawvideo", "--of=image2", "--ofopts=update=1", "--o="..thumbnail_path
    }

    if not pre_0_30_0 then
        table.insert(args, "--sws-allow-zimg=no")
    end

    if support_media_control then
        table.insert(args, "--media-controls=no")
    end

    if os_name == "darwin" and properties["macos-app-activation-policy"] then
        table.insert(args, "--macos-app-activation-policy=accessory")
    end

    if os_name == "windows" or pre_0_33_0 then
        table.insert(args, "--input-ipc-server="..options.socket)
    elseif not script_written then
        local client_script_path = options.socket..".run"
        local script = io.open(client_script_path, "w+")
        if script == nil then
            mp.msg.error("client script write failed")
            return
        else
            script_written = true
            script:write(string.format(client_script, options.socket))
            script:close()
            subprocess({"chmod", "+x", client_script_path}, true)
            table.insert(args, "--scripts="..client_script_path)
        end
    else
        local client_script_path = options.socket..".run"
        table.insert(args, "--scripts="..client_script_path)
    end

    table.insert(args, "--")
    table.insert(args, path)

    spawned = true
    spawn_waiting = true

    subprocess(args, true,
        function(success, result)
            if spawn_waiting and (success == false or not result or (result.status ~= 0 and result.status ~= -2)) then
                spawned = false
                spawn_waiting = false
                options.tone_mapping = "no"
                mp.msg.error("mpv subprocess create failed")
                if not spawn_working then -- notify users of required configuration
                    if options.mpv_path == "mpv" then
                        if properties["current-vo"] == "libmpv" then
                            if options.mpv_path == mpv_path then -- attempt to locate ImPlay
                                mpv_path = "ImPlay"
                                spawn(time)
                            else -- ImPlay not in path
                                if os_name ~= "darwin" then
                                    force_disabled = true
                                    info(real_w or effective_w, real_h or effective_h)
                                end
                                mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                                mp.commandv("script-message-to", "implay", "show-message", "thumbfast initial setup", "Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                            end
                        else
                            mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                            if os_name == "windows" and frontend_path == nil then
                                mp.commandv("script-message-to", "mpvnet", "show-text", "thumbfast: ERROR! install standalone mpv, see README", 5000, 20)
                                mp.commandv("script-message", "mpv.net", "show-text", "thumbfast: ERROR! install standalone mpv, see README", 5000, 20)
                            end
                        end
                    else
                        mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                        -- found ImPlay but not defined in config
                        mp.commandv("script-message-to", "implay", "show-message", "thumbfast", "Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                    end
                end
            elseif success == true and result and (result.status == 0 or result.status == -2) then
                if not spawn_working and properties["current-vo"] == "libmpv" and options.mpv_path ~= mpv_path then
                    mp.commandv("script-message-to", "implay", "show-message", "thumbfast initial setup", "Set mpv_path=ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                end
                spawn_working = true
                spawn_waiting = false
            end
        end
    )
end

local function run(command)
    if not spawned then return end

    if options.direct_io then
        local hPipe = winapi.C.CreateFileW(winapi.socket_wc, winapi.GENERIC_WRITE, 0, nil, winapi.OPEN_EXISTING, winapi._createfile_pipe_flags, nil)
        if hPipe ~= winapi.INVALID_HANDLE_VALUE then
            local buf = command .. "\n"
            winapi.C.SetNamedPipeHandleState(hPipe, winapi.PIPE_NOWAIT, nil, nil)
            winapi.C.WriteFile(hPipe, buf, #buf + 1, winapi._lpNumberOfBytesWritten, nil)
            winapi.C.CloseHandle(hPipe)
        end

        return
    end

    local command_n = command.."\n"

    if os_name == "windows" then
        if file and file_bytes + #command_n >= 4096 then
            file:close()
            file = nil
            file_bytes = 0
        end
        if not file then
            file = io.open("\\\\.\\pipe\\"..options.socket, "r+b")
        end
    elseif pre_0_33_0 then
        subprocess({"/usr/bin/env", "sh", "-c", "echo '" .. command .. "' | socat - " .. options.socket})
        return
    elseif not file then
        file = io.open(options.socket, "r+")
    end
    if file then
        file_bytes = file:seek("end")
        file:write(command_n)
        file:flush()
    end
end

local function draw(w, h, script)
    if not w or not show_thumbnail or not thumbnail_path then return end
    if x ~= nil then
        local scale_w, scale_h = options.scale_factor ~= 1 and (w * options.scale_factor) or nil, options.scale_factor ~= 1 and (h * options.scale_factor) or nil
        if pre_0_30_0 then
            mp.command_native({"overlay-add", options.overlay_id, x, y, thumbnail_path..".bgra", 0, "bgra", w, h, (4*w), scale_w, scale_h})
        else
            mp.command_native_async({"overlay-add", options.overlay_id, x, y, thumbnail_path..".bgra", 0, "bgra", w, h, (4*w), scale_w, scale_h}, function() end)
        end
    elseif script then
        local json, err = mp.utils.format_json({width=w, height=h, scale_factor=options.scale_factor, x=x, y=y, socket=options.socket, thumbnail=thumbnail_path, overlay_id=options.overlay_id})
        mp.commandv("script-message-to", script, "thumbfast-render", json)
    end
end

local function real_res(req_w, req_h, filesize)
    local count = filesize / 4
    local diff = (req_w * req_h) - count

    if (properties["video-params"] and properties["video-params"]["rotate"] or 0) % 180 == 90 then
        req_w, req_h = req_h, req_w
    end

    if diff == 0 then
        return req_w, req_h
    else
        local threshold = 5 -- throw out results that change too much
        local long_side, short_side = req_w, req_h
        if req_h > req_w then
            long_side, short_side = req_h, req_w
        end
        for a = short_side, short_side - threshold, -1 do
            if count % a == 0 then
                local b = count / a
                if long_side - b < threshold then
                    if req_h < req_w then return b, a else return a, b end
                end
            end
        end
        return nil
    end
end

local function move_file(from, to)
    if os_name == "windows" then
        os.remove(to)
    end
    -- move the file because it can get overwritten while overlay-add is reading it, and crash the player
    os.rename(from, to)
end

local function seek(fast)
    if last_seek_time then
        run("async seek " .. last_seek_time .. (fast and " absolute+keyframes" or " absolute+exact"))
    end
end

local seek_period = 3/60
local seek_period_counter = 0
local seek_timer
seek_timer = mp.add_periodic_timer(seek_period, function()
    if seek_period_counter == 0 then
        seek(allow_fast_seek)
        seek_period_counter = 1
    else
        if seek_period_counter == 2 then
            if allow_fast_seek then
                seek_timer:kill()
                seek()
            end
        else seek_period_counter = seek_period_counter + 1 end
    end
end)
seek_timer:kill()

local function request_seek()
    if seek_timer:is_enabled() then
        seek_period_counter = 0
    else
        seek_timer:resume()
        seek(allow_fast_seek)
        seek_period_counter = 1
    end
end

local function check_new_thumb()
    -- the slave might start writing to the file after checking existance and
    -- validity but before actually moving the file, so move to a temporary
    -- location before validity check to make sure everything stays consistant
    -- and valid thumbnails don't get overwritten by invalid ones
    if not thumbnail_path then return end
    local tmp = thumbnail_path..".tmp"
    move_file(thumbnail_path, tmp)
    local finfo = mp.utils.file_info(tmp)
    if not finfo then return false end
    spawn_waiting = false
    local w, h = real_res(effective_w, effective_h, finfo.size)
    if w then -- only accept valid thumbnails
        move_file(tmp, thumbnail_path..".bgra")

        real_w, real_h = w, h
        if real_w and (real_w ~= last_real_w or real_h ~= last_real_h) then
            last_real_w, last_real_h = real_w, real_h
            info(real_w, real_h)
        end
        if not show_thumbnail then
            file_timer:kill()
        end
        return true
    end

    return false
end

file_timer = mp.add_periodic_timer(file_check_period, function()
    if check_new_thumb() then
        draw(real_w, real_h, script_name)
    end
end)
file_timer:kill()

local function clear()
    file_timer:kill()
    seek_timer:kill()
    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end
    last_seek_time = nil
    show_thumbnail = false
    last_x = nil
    last_y = nil
    thumbnail_path = nil
    if script_name then return end
    if pre_0_30_0 then
        mp.command_native({"overlay-remove", options.overlay_id})
    else
        mp.command_native_async({"overlay-remove", options.overlay_id}, function() end)
    end
end

local function quit()
    activity_timer:kill()
    if show_thumbnail then
        activity_timer:resume()
        return
    end
    run("quit")
    spawned = false
    real_w, real_h = nil, nil
    clear()
end

activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
activity_timer:kill()

local function thumb(time, r_x, r_y, script)
    if disabled then return end

    time = tonumber(time)
    if time == nil then return end

    if r_x == "" or r_y == "" then
        x, y = nil, nil
    else
        x, y = math.floor(r_x + 0.5), math.floor(r_y + 0.5)
    end

    if using_storyboards and thumbnail_delta then
        local thumb_index = math.floor(time / thumbnail_delta)
        local closest = closest_preceeding_thumbnail(storyboard_thumbnails, thumb_index)
        if closest ~= nil then
            thumbnail_path = closest
        end
        local atlas_index = math.ceil(thumb_index / thumb_count_per_storyboard)
        prioritize_process(atlas_index)
    end

    script_name = script
    if last_x ~= x or last_y ~= y or not show_thumbnail or (using_storyboards and thumbnail_delta and time ~= last_seek_time) then
        show_thumbnail = true
        last_x, last_y = x, y
        draw(real_w, real_h, script)
    end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    if time == last_seek_time then return end
    last_seek_time = time
    if using_storyboards then return end
    if not spawned then spawn(time) end
    request_seek()
    if not file_timer:is_enabled() then file_timer:resume() end
end

local function parse_lavfi_crop(filters)
    lavfi_crop = {}
    local crop = string.match(filters, "lavfi%-crop=([^,]+)") -- TODO: do we also have to handle non-lavfi "crop"?
    if crop then
        for coord in crop:gmatch("[^:]+") do
            local key, val = string.match(coord, "^([^=]+)=(.*)")
            if key then
                lavfi_crop[key] = tonumber(val)
            end
        end
    end
end

local function watch_changes()
    if not dirty or not properties["video-out-params"] then return end
    dirty = false

    local vf_reset = vf_string(filters_reset)
    local rotate = properties["video-rotate"] or 0

    local resized_storyboard = last_vf_reset ~= vf_reset or
        last_rotate ~= rotate or
        last_crop ~= properties["video-crop"]
    -- TODO: add flipping detection

    if resized_storyboard then
        storyboard_transpose = rotate % 180 == 90
        parse_lavfi_crop(vf_reset)
        -- TODO: honor options.spawn_first, where we only start fetching thumbnails on hover?
        clear() -- TODO: be smarter about this?
        setup_storyboards()
    end

    if using_storyboards then
        if resized_storyboard then
            -- TODO: respawn
            last_vf_reset = vf_reset
            last_rotate = rotate
            last_crop = properties["video-crop"]
        end
        return
    end

    local old_w = effective_w
    local old_h = effective_h

    calc_dimensions()

    local resized = old_w ~= effective_w or
        old_h ~= effective_h or
        last_vf_reset ~= vf_reset or
        (last_rotate % 180) ~= (rotate % 180) or
        last_crop ~= properties["video-crop"] or
        par ~= last_par

    if resized then
        last_rotate = rotate
        info(effective_w, effective_h)
    elseif last_has_vid ~= has_vid and has_vid ~= 0 then
        info(effective_w, effective_h)
    end

    if spawned then
        if resized then
            -- mpv doesn't allow us to change output size
            local seek_time = last_seek_time
            run("quit")
            clear()
            spawned = false
            spawn(seek_time or mp.get_property_number("time-pos", 0))
            file_timer:resume()
        else
            if rotate ~= last_rotate then
                run("set video-rotate "..rotate)
            end
            local vf_runtime = vf_string(filters_runtime)
            if vf_runtime ~= last_vf_runtime then
                run("vf set "..vf_string(filters_all, true))
                last_vf_runtime = vf_runtime
            end
        end
    else
        last_vf_runtime = vf_string(filters_runtime)
    end

    last_vf_reset = vf_reset
    last_rotate = rotate
    last_par = par
    last_crop = properties["video-crop"]
    last_has_vid = has_vid

    if not spawned and not disabled and options.spawn_first and resized then
        spawn(mp.get_property_number("time-pos", 0))
        file_timer:resume()
    end
end

local function update_property(name, value)
    properties[name] = value
end

local function update_property_dirty(name, value)
    properties[name] = value
    dirty = true
    if name == "tone-mapping" then
        last_tone_mapping = nil
    end
end

local function update_tracklist(name, value)
    -- current-tracks shim
    for _, track in ipairs(value) do
        if track.type == "video" and track.selected then
            properties["current-tracks/video"] = track
            return
        end
    end
end

local function sync_changes(prop, val)
    update_property(prop, val)
    if val == nil then return end

    if type(val) == "boolean" then
        if prop == "vid" then
            has_vid = 0
            last_has_vid = 0
            info(effective_w, effective_h)
            clear()
            return
        end
        val = val and "yes" or "no"
    end

    if prop == "vid" then
        has_vid = 1
    end

    if not spawned then return end

    run("set "..prop.." "..val)
    dirty = true
end

local function get_thumb(atlas_path, atlas_idx, storyboard, thumbnail_size, rotation, crop, hflip, vflip)
    local atlas = io.open(atlas_path, "rb")
    if not atlas then
        print("could not open atlas file", atlas_path)
        return
    end

    local atlas_filesize = atlas:seek("end")
    local total_thumb_pixels = 4 * thumbnail_size.w * thumbnail_size.h
    local num_thumbs = math.floor(atlas_filesize / total_thumb_pixels + 0.5)
    local num_per_atlas = storyboard.columns * storyboard.rows

    local logical_columns = math.min(storyboard.columns, num_thumbs)
    local logical_rows = math.ceil(num_thumbs / logical_columns)

    local t_width, t_height, physical_atlas_width, physical_atlas_height

    if rotation == 0 or rotation == 180 then
        t_width = thumbnail_size.w
        t_height = thumbnail_size.h
        physical_atlas_width = logical_columns * t_width
        physical_atlas_height = logical_rows * t_height
    elseif rotation == 90 or rotation == 270 then
        t_width = thumbnail_size.h
        t_height = thumbnail_size.w
        physical_atlas_width = logical_rows * t_width
        physical_atlas_height = logical_columns * t_height
    end

    local stride = 4 * physical_atlas_width

    -- TODO: handle cropping

    for pic = 0, num_thumbs - 1 do
        local logical_col = pic % logical_columns
        local logical_row = math.floor(pic / logical_columns)

        local x_start, y_start

        if rotation == 0 then
            x_start = logical_col * t_width
            y_start = logical_row * t_height
        elseif rotation == 180 then
            x_start = physical_atlas_width - (logical_col + 1) * t_width
            y_start = physical_atlas_height - (logical_row + 1) * t_height
        elseif rotation == 90 then
            local phys_col = logical_rows - 1 - logical_row
            local phys_row = logical_col
            x_start = phys_col * t_width
            y_start = phys_row * t_height
        elseif rotation == 270 then
            local phys_col = logical_row
            local phys_row = logical_columns - 1 - logical_col
            x_start = phys_col * t_width
            y_start = phys_row * t_height
        end

        if hflip then
            x_start = (physical_atlas_width - t_width) - x_start
        end
        if vflip then
            y_start = (physical_atlas_height - t_height) - y_start
        end

        local thumb_idx = (atlas_idx - 1) * num_per_atlas + pic
        local filename = options.thumbnail .. ".ytdl-thumbx" .. tostring(thumb_idx)
        local thumb_file = io.open(filename .. ".bgra", "wb")
        if not thumb_file then
            atlas:close()
            print("storyboard thumbnail write failed", filename)
            return
        end

        for line = 0, t_height - 1 do
            atlas:seek("set", 4 * x_start + (y_start + line) * stride)
            local data = atlas:read(t_width * 4)
            if data then
                thumb_file:write(data)
            end
        end

        thumb_file:close()
        storyboard_thumbnails[thumb_idx] = filename

        if last_seek_time then
            local last_thumb_idx = math.floor(last_seek_time / thumbnail_delta)
            if last_thumb_idx == thumb_idx then
                last_seek_time = nil
            end
        end
    end

    atlas:close()
end

local function fetch_fragment(storyboard, i, thumbnail_size, storyboard_scale, scale_formula, video_filters, crop, hflip, vflip)
    if not storyboard.fragments[i] then return end

    local args = {
        mpv_path, storyboard.fragments[i].url, "--no-config", "--msg-level=all=no", "--really-quiet", "--no-terminal",
        "--frames=1",
        --"--load-scripts=no", "--osc=no", "--ytdl=no", "--load-stats-overlay=no", "--load-osd-console=no", "--load-auto-profiles=no",
        "--no-sub", "--no-audio", "--hr-seek=no", "--sub-font-provider=none", "--embeddedfonts=no",
        "--no-ytdl", "--demuxer-readahead-secs=0", "--demuxer-max-bytes=128KiB",
        "--vd-lavc-software-fallback=1", "--vd-lavc-fast", "--vd-lavc-threads=2", --"--hwdec="..(options.hwdec and "auto" or "no"),
        "--vf="..video_filters,
        "--sws-allow-zimg=no", "--sws-fast=yes", "--sws-scaler=fast-bilinear",
        --"--video-rotate="..last_rotate,
        "--vf-add=format=bgra,scale="..scale_formula,
        "--ovc=rawvideo", "--of=rawvideo", "--ofopts=update=1", "--o="..options.thumbnail..".ytdl"..tostring(i)
    }

    if os_name == "Mac" then
        table.insert(args, "--macos-app-activation-policy=prohibited")
    end

    spawn_queued_process(args,
        function(success, result, err)
            if success == false or (not result or result.status ~= 0) then
                if not result.killed_by_us then
                    mp.msg.error("thumbfast: storyboard download failed", "atlas:", i, "status:", result.status)
                end
            else
                get_thumb(options.thumbnail..".ytdl"..tostring(i), i, storyboard, thumbnail_size, math.floor((properties["video-rotate"] or 0) / 90 + 0.5) * 90, crop, hflip, vflip)
            end
        end
    )

    fetch_fragment(storyboard, i+1, thumbnail_size, storyboard_scale, scale_formula, video_filters, crop, hflip, vflip)
end

local function anycase(s)
    return string.gsub(s, "%a", function (c)
        return string.format("[%s%s]", c:lower(), c:upper())
    end)
end

local http_prefix = anycase("^https?://")
local ytdl_prefix = "^ytdl://(.+)"
local subdomains = "[%w-.]*"
local naked_ytdl_id = "^ytdl://([%w-_]+)$"
local youtube_id = ".+"
local twitch_id = "%d+.*"
local ytdl_opts = {try_ytdl_first = false, ytdl_path = ""}
mp.options.read_options(ytdl_opts, "ytdl_hook")

local youtube_patterns_free = {
    -- youtube.com/watch?v=abcdef01234 or any invidious/piped site
    anycase(".*/watch.*[?&]v=")..youtube_id,

    -- youtube.com/embed/abcdef01234 or any invidious/piped site
    anycase(".*/embed/")..youtube_id,
}
local youtube_patterns = {
    -- youtu.be/abcdef01234
    "^"..anycase("youtu%.be/")..youtube_id,

    -- youtube.com/v/abcdef01234 or youtube.com/shorts/abcdef01234
    "^"..subdomains..anycase("youtube%.com/[^/]+/")..youtube_id,
}
local twitch_base = subdomains..anycase("twitch%.tv/")
local twitch_patterns = {
    -- twitch.tv/user/v/123456
    "^"..subdomains..anycase("twitch%.tv/[^/]+/v/")..twitch_id,

    -- twitch.tv/user/video/123456
    "^"..subdomains..anycase("twitch%.tv/[^/]+/video/")..twitch_id,

    -- twitch.tv/videos/123456
    "^"..subdomains..anycase("twitch%.tv/videos/")..twitch_id,

    -- twitch.tv/user/schedule?vodID=123456
    "^"..subdomains..anycase("twitch%.tv/[^/]+/schedule%?vodID=")..twitch_id,

    -- player.twitch.tv/?video=v123456 or player.twitch.tv/?video=123456
    "^"..anycase("player%.twitch%.tv/.*[?&]video=v?")..twitch_id,
}

local function storyboard_supported_url(path, referer)
    local video_url = string.match(path, naked_ytdl_id) or string.match(referer, naked_ytdl_id)
    if video_url then
        return video_url
    end

    path_ytdl, path_has_ytdl_prefix = string.gsub(path, ytdl_prefix, "%1")
    path,      path_has_http_prefix = string.gsub(path_ytdl, http_prefix, "")
    path_has_prefix = path_has_ytdl_prefix or path_has_http_prefix or ytdl_opts.try_ytdl_first

    referer_ytdl, referer_has_ytdl_prefix = string.gsub(referer, ytdl_prefix, "%1")
    referer,      referer_has_http_prefix = string.gsub(referer_ytdl, http_prefix, "")
    referer_has_prefix = referer ~= "" and (referer_has_ytdl_prefix or referer_has_http_prefix or ytdl_opts.try_ytdl_first)

    local checks = {
        {input = path_ytdl,    patterns = youtube_patterns_free, condition = function(input) return true end},
        {input = path,         patterns = youtube_patterns,      condition = function(input) return path_has_prefix end},
        {input = path,         patterns = twitch_patterns,       condition = function(input) return path_has_prefix and string.match(input, twitch_base) end},
        {input = referer_ytdl, patterns = youtube_patterns_free, condition = function(input) return input ~= "" end},
        {input = referer,      patterns = youtube_patterns,      condition = function(input) return referer_has_prefix end},
        {input = referer,      patterns = twitch_patterns,       condition = function(input) return referer_has_prefix and string.match(input, twitch_base) end},
    }

    for _, check in ipairs(checks) do
        if check.condition(check.input) then
            for _, pattern in ipairs(check.patterns) do
                video_url = string.match(check.input, pattern)
                if video_url then
                    return video_url
                end
            end
        end
    end
end

local ytdl_paths_to_search = {"yt-dlp", "yt-dlp_x86", "youtube-dl"}
local ytdl_path = nil
local function find_ytdl_path()
    if ytdl_path ~= nil then return end

    ytdl_path = properties["user-data/mpv/ytdl/path"]
    if ytdl_path == "" then
        -- TODO: logging
        ytdl_path = false
    end

    if ytdl_path ~= nil then return end

    -- logic from ytdl_hook.lua for mpv <v0.39.0
    local separator = os_name == "windows" and ";" or ":"
    if ytdl_opts.ytdl_path:match("[^" .. separator .. "]") then
        ytdl_paths_to_search = {}
        for path in ytdl_opts.ytdl_path:gmatch("[^" .. separator .. "]+") do
            table.insert(ytdl_paths_to_search, path)
        end
    end

    for _, path in pairs(ytdl_paths_to_search) do
        -- search for youtube-dl in mpv's config dir
        local exesuf = os_name == "windows" and not path:lower():match("%.exe$")
                        and ".exe" or ""
        ytdl_path = mp.find_config_file(path .. exesuf)
        if ytdl_path then
            msg.verbose("Found youtube-dl at: " .. ytdl_path)
            return
        end
    end

    ytdl_path = 0
end

local function ytdl_subprocess(args, async, cb)
    local callback = cb
    local function wrap_callback(callback)
        return function(success, result, err)
            if result and result.killed_by_us then
                ytdl_path = ytdl_path - 1
                return
            end
            if err == "init" or (result and result.error_string == "init") then
                ytdl_subprocess(args, async, cb)
                return
            elseif (err or "") ~= "" or not success then
                -- TODO: logging
                ytdl_path = false
            else
                -- we found ytdl
                ytdl_path = args[1]
            end
            callback(success, result, err)
        end
    end
    if type(ytdl_path) == "number" then
        ytdl_path = ytdl_path + 1
        if ytdl_path >= #ytdl_paths_to_search then
            -- TODO: logging
            ytdl_path = false
            callback(false, nil, nil)
            return
        end
        args[1] = ytdl_paths_to_search[ytdl_path]
        callback = wrap_callback(callback)
    else
        local ytdl_hook_subprocess = properties["user-data/mpv/ytdl/json-subprocess-result"]
        if ytdl_hook_subprocess ~= nil then
            callback(true, ytdl_hook_subprocess, nil)
            return
        end
    end
    ytdl_subprocess_cancel = subprocess(args, async, callback)
end

function setup_storyboards()
    if not options.network then return end

    local path = properties["path"]
    if path == nil then return end

    local open_filename = properties["stream-open-filename"]
    local forced_path = open_filename and path ~= open_filename -- and properties["demuxer-via-network"]
    if not forced_path then return end

    remove_thumbnail_files()
    remove_storyboard_files()

    local referer = string.match(properties["http-header-fields"] or "", "Referer:([^,]+)") or "" -- TODO: use native property here

    local video_url = storyboard_supported_url(path, referer)

    if video_url then
        find_ytdl_path()
        if not ytdl_path then return end

        using_storyboards = true

        local sb_cmd = {ytdl_path, "--format", "sb0", "--dump-json", "--no-playlist",
                        "--extractor-args", "youtube:skip=hls,dash,translated_subs", -- yt speedup
                        "--", video_url}

        ytdl_subprocess(sb_cmd, true, function(success, sb_json, err)
            if success and sb_json.status == 0 then
                local sb_j = mp.utils.parse_json(sb_json.stdout)
                if sb_j and sb_j.formats then
                for _, sb in ipairs(sb_j.formats) do
                if sb and sb.format_id == "sb0" and sb_j.duration and sb.width and sb.height and sb.rows and sb.columns and sb.fragments and #sb.fragments > 0 then
                    local thumbnail_count = 0
                    thumb_count_per_storyboard = sb.rows * sb.columns
                    thumbnail_path = nil

                    if sb.fps then
                        thumbnail_count = math.floor(sb.fps * sb_j.duration + 0.5)
                    else
                        -- estimate the count of thumbnails
                        -- assume first atlas is always full
                        thumbnail_delta = sb.fragments[1].duration / (sb.rows * sb.columns)
                        thumbnail_count = math.floor(sb_j.duration / thumbnail_delta)
                    end

                    -- Storyboard upscaling factor
                    local scale = properties["display-hidpi-scale"] or 1
                    if sb.width / sb.height > options.max_width / options.max_height then
                        real_w = options.max_width * scale
                        real_h = math.floor(sb.height / sb.width * real_w)
                        real_w = math.floor(real_w)
                    else
                        real_h = options.max_height * scale
                        real_w = math.floor(sb.width / sb.height * real_h)
                        real_h = math.floor(real_h)
                    end
                    local storyboard_scale = {w=real_w/sb.width, h=real_h/sb.height}
                    local thumbnail_size = {w=real_w, h=real_h, ow=sb.width, oh=sb.height, cw=real_w, ch=real_h}
                    effective_w, effective_h = real_w, real_h
                    if storyboard_transpose then
                        real_w, real_h = real_h, real_w
                    end
                    local crop = {x=0, y=0, w=0, h=0}
                    local vf_reset = vf_string(filters_reset)
                    parse_lavfi_crop(vf_reset)
                    if lavfi_crop.x and lavfi_crop.y and lavfi_crop.w and lavfi_crop.h then
                        local width, height = properties["width"], properties["height"]
                        if width and height then
                            -- TODO: crop handling is unfinished
                            local cropped_from_width = width - lavfi_crop.w
                            local cropped_from_height = height - lavfi_crop.h
                            thumbnail_size.cw = math.floor(thumbnail_size.w * (width / lavfi_crop.w) + 0.5)
                            thumbnail_size.ch = math.floor(thumbnail_size.h * (height / lavfi_crop.h) + 0.5)
                            local scale_x = thumbnail_size.cw / thumbnail_size.w
                            local scale_y = thumbnail_size.ch / thumbnail_size.h
                            crop.x = math.floor(lavfi_crop.x / scale_x + 0.5) -- TODO: math.min(crop.x + thumbnail_size.w, thumbnail_size.cw) - thumbnail_size.w
                            crop.y = math.floor(lavfi_crop.y / scale_y + 0.5) -- TODO: math.min(crop.y + thumbnail_size.h, thumbnail_size.ch) - thumbnail_size.h
                            crop.w = math.floor(lavfi_crop.w / scale_x + 0.5) -- TODO: thumbnail_size.w
                            crop.h = math.floor(lavfi_crop.h / scale_y + 0.5) -- TODO: thumbnail_size.h
                            real_w = crop.w -- unnecessary
                            real_h = crop.h -- unnecessary
                            storyboard_scale = {w=thumbnail_size.cw/thumbnail_size.ow, h=thumbnail_size.ch/thumbnail_size.oh}
                        end
                    end
                    info(real_w, real_h)

                    local transpose = string.rep("transpose=1,", math.floor(properties["video-rotate"] or 0) / 90 % 4)
                    local vf = vf_string_simple(filters_runtime, "")
                    local video_filters = (vf .. transpose):sub(1, -2)
                    local width_formula = "round(iw*"..storyboard_scale.w.."/"..thumbnail_size.cw..")*"..thumbnail_size.cw
                    local height_formula = "round(ih*"..storyboard_scale.h.."/"..thumbnail_size.ch..")*"..thumbnail_size.ch
                    if storyboard_transpose then
                        width_formula = "round(iw*"..storyboard_scale.w.."/"..thumbnail_size.ch..")*"..thumbnail_size.ch
                        height_formula = "round(ih*"..storyboard_scale.h.."/"..thumbnail_size.cw..")*"..thumbnail_size.cw
                    end
                    local scale_formula = width_formula..":"..height_formula

                    -- TODO: account for when hflip or vflip get cancelled out by multiple invocations... and use the actual vf table instead of working on strings
                    local hflip, vflip = string.match(vf, "hflip"), string.match(vf, "vflip")

                    thumbnail_delta = sb_j.duration / thumbnail_count

                    fetch_fragment(sb, 1, thumbnail_size, storyboard_scale, scale_formula, video_filters, lavfi_crop, hflip, vflip)
                    return
                end
                end
                end
            end

            -- fall back to regular thumbnailing
            file_load()
        end)
        -- we are in a state where we decided yeah let's try storyboards
        return true
    end
end

local function file_load()
    clear()
    spawned = false
    real_w, real_h = nil, nil
    last_real_w, last_real_h = nil, nil
    last_tone_mapping = nil
    last_seek_time = nil
    if info_timer then
        info_timer:kill()
        info_timer = nil
    end
    using_storyboards = false
    thumbnail_delta = nil
    thumbnail_path = nil

    cancel_queued_processes()

    calc_dimensions()
    info(effective_w, effective_h)
    if disabled then return end

    spawned = false
    if options.spawn_first then -- TODO: skip if matches storyboard stuff
        spawn(mp.get_property_number("time-pos", 0))
        first_file = true
    end
end

local function shutdown()
    run("quit")
    remove_thumbnail_files()
    remove_storyboard_files()
    if os_name ~= "windows" then
        os.remove(options.socket)
        os.remove(options.socket..".run")
    end
end

local function on_duration(prop, val)
    allow_fast_seek = (val or 30) >= 30
end

mp.observe_property("current-tracks/video", "native", function(name, value)
    if pre_0_33_0 then
        mp.unobserve_property(update_tracklist)
        pre_0_33_0 = false
    end
    update_property(name, value)
end)

mp.observe_property("track-list", "native", update_tracklist)
mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-out-params", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("vf", "native", update_property_dirty)
mp.observe_property("tone-mapping", "native", update_property_dirty)
mp.observe_property("demuxer-via-network", "native", update_property)
mp.observe_property("http-header-fields", "string", update_property)
mp.observe_property("cookies", "string", update_property)
mp.observe_property("cookies-file", "string", update_property)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("user-data/mpv/ytdl/path", "native", update_property)
mp.observe_property("user-data/mpv/ytdl/json-subprocess-result", "native", update_property)
mp.observe_property("macos-app-activation-policy", "native", update_property)
mp.observe_property("current-vo", "native", update_property)
mp.observe_property("video-rotate", "native", update_property)
mp.observe_property("video-crop", "native", update_property)
mp.observe_property("path", "native", update_property)
mp.observe_property("width", "native", update_property)
mp.observe_property("height", "native", update_property)
mp.observe_property("vid", "native", sync_changes)
mp.observe_property("edition", "native", sync_changes)
mp.observe_property("duration", "native", on_duration)

mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)

mp.register_event("file-loaded", file_load)
mp.register_event("shutdown", shutdown)

mp.register_idle(watch_changes)
