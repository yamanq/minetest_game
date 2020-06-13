#! /usr/bin/env lua

local me = arg[0]:gsub(".*[/\\](.*)$", "%1")

local function err(fmt, ...)
	io.stderr:write(("%s: %s\n"):format(me, fmt:format(...)))
	os.exit(1)
end

local output
local inputs = { }
local lang
local author

local i = 1

local function usage()
	print([[
Usage: ]]..me..[[ [OPTIONS] FILE...

Extract translatable strings from the given FILE(s).

Available options:
  -h,--help         Show this help screen and exit.
  -o,--output X     Set output file (default: stdout).
  -a,--author X     Set author.
  -l,--lang X       Set language name.
]])
	os.exit(0)
end

while i <= #arg do
	local a = arg[i]
	if (a == "-h") or (a == "--help") then
		usage()
	elseif (a == "-o") or (a == "--output") then
		i = i + 1
		if i > #arg then
			err("missing required argument to `%s'", a)
		end
		output = arg[i]
	elseif (a == "-a") or (a == "--author") then
		i = i + 1
		if i > #arg then
			err("missing required argument to `%s'", a)
		end
		author = arg[i]
	elseif (a == "-l") or (a == "--lang") then
		i = i + 1
		if i > #arg then
			err("missing required argument to `%s'", a)
		end
		lang = arg[i]
	elseif a:sub(1, 1) ~= "-" then
		table.insert(inputs, a)
	else
		err("unrecognized option `%s'", a)
	end
	i = i + 1
end

if #inputs == 0 then
	err("no input files")
end

local outfile = io.stdout

local function printf(fmt, ...)
	outfile:write(fmt:format(...))
end

if output then
	local e
	outfile, e = io.open(output, "w")
	if not outfile then
		err("error opening file for writing: %s", e)
	end
end

if author or lang then
	outfile:write("\n")
end

if lang then
	printf("# Language: %s\n", lang)
end

if author then
	printf("# Author: %s\n", author)
end

if author or lang then
	outfile:write("\n")
end

local c_escapes = {
	[('a'):byte(1)] = '\a',
	[('b'):byte(1)] = '\b',
	[('f'):byte(1)] = '\f',
	[('r'):byte(1)] = '\r',
	[('t'):byte(1)] = '\t',
	[('v'):byte(1)] = '\v',
	-- \n is handled separately
}

local function parse_lua_string(s)
	local esc = false
	local i = 1
	local len = #s

	while i <= len do
		local c = s:byte(i)
		i = i + 1
		if esc then
			esc = false
			if c >= 0x30 and c <= 0x39 then
				-- 0x30 = 0
				-- 0x39 = 9
				local scode = s:match('%d%d?%d?', i - 1)
				local ncode = tonumber(scode)
				s = s:sub(1, i - 3) .. string.char(ncode) .. s:sub(i-1 + #scode)
				-- Reevaluate the current character only if it isn't \
				i = i - (ncode == 0x5C and 1 or 2)
				len = #s
			elseif c == 0x6E then
				-- 0x6E = n
				s = s:sub(1, i - 3) .. "@n" .. s:sub(i)
			elseif c == 0x78 then
				-- 0x78 = x
				s = s:sub(1, i - 3) .. s:sub(i - 1)
				i = i - 2
				len = len - 1
				io.stderr:write("Warning: Hex escape sequence is illegal in Lua 5.1\n")
			elseif c_escapes[c] ~= nil then
				s = s:sub(1, i - 3) .. c_escapes[c] .. s:sub(i)
				len = len - 1
				i = i - 1
			else
				s = s:sub(1, i - 3) .. s:sub(i - 1)
				len = len - 1
				-- Reevaluate the current character only if it isn't \
				i = i - (c == 0x5C and 1 or 2)
			end
		elseif c == 0x5C then
			-- 0x5C = \
			esc = true
		elseif c == 0x0A then
			-- 0x0A = LF
			s = s:sub(1, i - 2) .. "@n" .. s:sub(i)
			len = len + 1
			i = i + 1
		elseif c == 0x3D then
			-- 0x3D = =
			s = s:sub(1, i - 2) .. "@=" .. s:sub(i)
			len = len + 1
			i = i + 1
		elseif c == 0x23 and i == 2 then
			-- 0x23 = #
			s = '@' .. s
			len = len + 1
			i = i + 1
		end
	end
	return s
end

local function replace_quote_in_quote(s)
	--[[
		state = 0: normal code, starting state
		state = 1: seen -
		state = 2: seen " or ' (begin string parsing)
		state = 3: seen \ within string
	--]]
	local state = 0
	local i = 1
	local len = #s
	local end_str

	while i <= len do
		local c = s:byte(i)
		i = i + 1
		if state == 0 then
			if c == 0x2D then
				-- 0x2D = -
				state = 1
			elseif c == 0x22 or c == 0x27 then
				-- 0x22 = "
				-- 0x27 = '
				end_str = c
				state = 2
			-- else remain in state 0
			end
		elseif state == 1 then
			if c == 0x2D then
				-- 0x2D = -
				-- Ignore the rest of the line. We don't parse --[[ ... ]].
				return s:sub(1, i - 3)
			elseif c == 0x22 or c == 0x27 then
				-- 0x22 = "
				-- 0x27 = '
				end_str = c
				state = 3
			else
				state = 0
			end
		elseif state == 2 then
			if c == 0x5C then
				-- 0x5C = \
				state = 3
			elseif c == end_str then
				state = 0
			elseif c == 0x22 or c == 0x27 or c == 0x28 then
				-- " or ' or open parenthesis
				s = s:sub(1, i - 2) .. ("\\%03d"):format(c) .. s:sub(i)
				i = i + 3
				len = len + 3
			-- else remain in state 2
			end
		elseif state == 3 then
			if c == 0x22 or c == 0x27 then
				-- Escaped quote found - replace it
				s = s:sub(1, i - 2) .. (c == 0x22 and "034" or "039") .. s:sub(i)
				i = i + 2
				len = len + 2
				state = 2
			else
				state = 2
			end
		end
	end
	assert(#s == len)
	return s
end

local messages = {}

for _, file in ipairs(inputs) do
	local infile, e = io.open(file, "r")
	local textdomains = {}
	if infile then
		for line in infile:lines() do
			for translator_name, textdomain in line:gmatch('local (%w+)%s*=%s*%w+%.get_translator%("([^"]*)"%)') do
				--print(translator_name, textdomain)
				messages[textdomain] = messages[textdomain] or {}
				textdomains[translator_name] = textdomain
			end
			line = replace_quote_in_quote(line)
			for translator, s in line:gmatch('(%w+)%("([^"]*)"') do
				s = parse_lua_string(s)
				if textdomains[translator] then
					local textdomain = textdomains[translator]
					table.insert(messages[textdomain], s)
				end
			end
			for textdomain, s in line:gmatch('%w+%.translate%("([^"]*)"%s*,%s*"([^"]*)"') do
				s = parse_lua_string(s)
				messages[textdomain] = messages[textdomain] or {}
				table.insert(messages[textdomain], s)
			end
		end
		infile:close()
	else
		io.stderr:write(("%s: WARNING: error opening file: %s\n"):format(me, e))
	end
end

for textdomain, mtbl in pairs(messages) do
	table.sort(messages[textdomain])

	local last_msg
	printf("# textdomain: %s\n", textdomain)

	for _, msg in ipairs(messages[textdomain]) do
		if msg ~= last_msg then
			printf("%s=\n", msg)
		end
		last_msg = msg
	end
end

if output then
	outfile:close()
end

--[[
TESTS:
local S = minetest.get_translator("domain")
S("foo") S("bar")
S("bar")
S("foo") -- S("doesn't matter")
print("this is in a string S(") x=0 print(") still text") S('bar baz "this" \"\'that\' foobar')
minetest.translate("another_domain", "foo")
S("#foo=@1\n@2", "bar", "baz")
S("what's this? (oh, an apostrophe)")
S("\035 is a #")
S("\092 is a \\")
S("\\ is a \\")
S("\# is a #")
]]
