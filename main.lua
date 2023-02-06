utils = require "mp.utils"

local function print(s)
	mp.msg.info(s)
	mp.osd_message(s)
end

local function table_to_str(o)
	if type(o) == 'table' then
		local s = ''
		for k,v in pairs(o) do
			if type(k) ~= 'number' then k = '"'..k..'"' end
			s = s .. '['..k..'] = ' .. table_to_str(v) .. '\n'
		end
		return s
	else
		return tostring(o)
	end
end

local function to_hms(seconds)
	local ms = math.floor((seconds - math.floor(seconds)) * 1000)
	local secs = math.floor(seconds)
	local mins = math.floor(secs / 60)
	secs = secs % 60
	local hours = math.floor(mins / 60)
	mins = mins % 60
	return string.format("%02d-%02d-%02d-%03d", hours, mins, secs, ms)
end

local function next_table_key(t, current)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for i = 1, #keys do
		if keys[i] == current then
			return keys[(i % #keys) + 1]
		end
	end
	return keys[1]
end

ACTIONS = {}

ACTIONS.COPY = function(d)
	local args = {
		"ffmpeg",
		"-nostdin", "-y",
		"-loglevel", "error",
		"-ss", d.start_time,
		"-t", d.duration,
		"-i", d.inpath,
		"-pix_fmt", "yuv420p",
		"-c", "copy",
		"-map", "0",
		"-avoid_negative_ts", "make_zero",
		utils.join_path(d.indir, "COPY_" .. d.channel .. "_" .. d.infile_noext .. "_FROM_" .. d.start_time_hms .. "_TO_" .. d.end_time_hms .. d.ext)
	}
	mp.command_native_async({
		name = "subprocess",
		args = args,
		playback_only = false,
	}, function() print("Done") end)
end

ACTIONS.ENCODE = function(d)
	local args = {
		"ffmpeg",
		"-nostdin", "-y",
		"-loglevel", "error",
		"-i", d.inpath,
		"-ss", d.start_time,
		"-t", d.duration,
		"-pix_fmt", "yuv420p",
		"-crf", "16",
		"-preset", "superfast",
		utils.join_path(d.indir, "ENCODE_" .. d.channel .. "_" .. d.infile_noext .. "_FROM_" .. d.start_time_hms .. "_TO_" .. d.end_time_hms .. d.ext)
	}
	mp.command_native_async({
		name = "subprocess",
		args = args,
		playback_only = false,
	}, function() print("Done") end)
end

ACTIONS.LIST = function(d)
	local inpath = mp.get_property("path")
	local outpath = inpath .. ".list"
	local file = io.open(outpath, "a")
	if not file then print("Error writing to cut list") return end
	local filesize = file:seek("end")
	local s = "\n" .. d.channel
		.. ":" .. d.start_time
		.. ":" .. d.end_time
	file:write(s)
	local delta = file:seek("end") - filesize
	io.close(file)
	print("Δ " .. delta)
end

ACTION = "COPY"

MAKE_CUT = ACTIONS.COPY

CHANNEL = 1

CHANNEL_NAMES = {}

KEY_CUT = "c"
KEY_CYCLE_ACTION = "a"
KEY_BOOKMARK_ADD = "i"
KEY_CHANNEL_INC = "="
KEY_CHANNEL_DEC = "-"
KEY_MAKE_CUTS = "0"

pcall(require, "config")

mp.msg.info("MPV-CUT LOADED.")

for i, v in ipairs(CHANNEL_NAMES) do
    CHANNEL_NAMES[i] = string.gsub(v, ":", "-")
end

if not ACTIONS[ACTION] then ACTION = next_table_key(ACTIONS, nil) end

START_TIME = nil

local function get_current_channel_name()
	return CHANNEL_NAMES[CHANNEL] or tostring(CHANNEL)
end

local function get_data()
	local d = {}
	d.inpath = mp.get_property("path")
	d.indir = utils.split_path(d.inpath)
	d.infile = mp.get_property("filename")
	d.infile_noext = mp.get_property("filename/no-ext")
	d.ext = mp.get_property("filename"):match("^.+(%..+)$") or ".mp4"
	d.channel = get_current_channel_name()
	return d
end

local function get_times(start_time, end_time)
	local d = {}
	d.start_time = tostring(start_time)
	d.end_time = tostring(end_time)
	d.duration = tostring(end_time - start_time)
	d.start_time_hms = tostring(to_hms(start_time))
	d.end_time_hms = tostring(to_hms(end_time))
	d.duration_hms = tostring(to_hms(end_time - start_time))
	return d
end

text_overlay = mp.create_osd_overlay("ass-events")
text_overlay.hidden = true
text_overlay:update()

local function text_overlay_off()
	-- https://github.com/mpv-player/mpv/issues/10227
	text_overlay:update()
	text_overlay.hidden = true
	text_overlay:update()
end

local function text_overlay_on()
	local channel = get_current_channel_name()
	text_overlay.data = string.format("%s in %s from %s", ACTION, channel, START_TIME)
	text_overlay.hidden = false
	text_overlay:update()
end

local function print_or_update_text_overlay(content)
	if START_TIME then text_overlay_on() else print(content) end
end

local function cycle_action()
	ACTION = next_table_key(ACTIONS, ACTION)
	print_or_update_text_overlay("ACTION: " .. ACTION)
end

local function make_cuts()
	print("MAKING CUTS")
	if not MAKE_CUT then print("MAKE_CUT function not found.") return end
	local inpath = mp.get_property("path") .. ".list"
	local file = io.open(inpath, "r")
	if not file then print("Error reading cut list") return end
	for line in file:lines() do
		if line ~= "" then
			local cut = {}
			for token in string.gmatch(line, "[^" .. ":" .. "]+") do
				table.insert(cut, token)
			end
			local d = get_data()
			d.channel = cut[1]
			local t = get_times(tonumber(cut[2]), tonumber(cut[3]))
			for k, v in pairs(t) do d[k] = v end
			mp.msg.info("MAKE_CUT")
			mp.msg.info(table_to_str(d))
			MAKE_CUT(d)
		end
	end
	io.close(file)
end

local function cut(start_time, end_time)
	local d = get_data()
	local t = get_times(start_time, end_time)
	for k, v in pairs(t) do d[k] = v end
	mp.msg.info(ACTION)
	mp.msg.info(table_to_str(d))
	ACTIONS[ACTION](d)
end

local function put_time()
	local time = mp.get_property_number("time-pos")
	if not START_TIME then
		START_TIME = time
		text_overlay_on()
		return
	end
	text_overlay_off()
	if time > START_TIME then
		cut(START_TIME, time)
		START_TIME = nil
	else
		print("INVALID")
		START_TIME = nil
	end
end

local function get_bookmark_file_path()
	local d = get_data()
	mp.msg.info(table_to_str(d))
	local outfile = string.format("%s_%s.book", d.channel, d.infile)
	return utils.join_path(d.indir, outfile)
end

local function bookmarks_load()
	local inpath = get_bookmark_file_path()
	local file = io.open(inpath, "r")
	if not file then return end
	local arr = {}
	for line in file:lines() do
		if tonumber(line) then
			table.insert(arr, {
				time = tonumber(line),
				title = "chapter_" .. line
			})
		end
	end
	file:close()
	table.sort(arr, function(a, b) return a.time < b.time end)
	mp.set_property_native("chapter-list", arr)
end

local function bookmark_add()
	local d = get_data()
	local outpath = get_bookmark_file_path()
	local file = io.open(outpath, "a")
	if not file then print("Failed to open bookmark file for writing") return end
	local out_string = mp.get_property_number("time-pos") .. "\n"
	local filesize = file:seek("end")
	file:write(out_string)
	local delta = file:seek("end") - filesize
	io.close(file)
	bookmarks_load()
	print(string.format("Δ %s, %s", delta, d.channel))
end

local function channel_inc()
	CHANNEL = CHANNEL + 1
	bookmarks_load()
	print_or_update_text_overlay(get_current_channel_name())
end

local function channel_dec()
	if CHANNEL >= 2 then CHANNEL = CHANNEL - 1 end
	bookmarks_load()
	print_or_update_text_overlay(get_current_channel_name())
end

mp.add_key_binding(KEY_CUT, "cut", put_time)
mp.add_key_binding(KEY_BOOKMARK_ADD, "bookmark_add", bookmark_add)
mp.add_key_binding(KEY_CHANNEL_INC, "channel_inc", channel_inc)
mp.add_key_binding(KEY_CHANNEL_DEC, "channel_dec", channel_dec)
mp.add_key_binding(KEY_CYCLE_ACTION, "cycle_action", cycle_action)
mp.add_key_binding(KEY_MAKE_CUTS, "make_cuts", make_cuts)

mp.register_event('file-loaded', bookmarks_load)
