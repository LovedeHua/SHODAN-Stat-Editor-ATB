-- SHODAN Stat Editor Offline: Stat Editor's own panel (stat_editor.lua, the in-game mod) in a desktop window,
-- editing the game's data files instead of the running game. The files are decrypted into memory as the game
-- holds them, the panel finds and edits them there, and Install writes the changed ones into the game folder.
-- host.lua [stat_editor.lua]
local here = (debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or './')
package.path = here .. '?.lua;' .. package.path

local ffi = require('ffi')
local shim = require('engine_shim')
local G = require('gamedata')
local D = require('hostdata')
local I = require('install')
local U = require('update')

pcall(ffi.cdef, 'uint64_t GetTickCount64(void);')
local function clock() return tonumber(ffi.C.GetTickCount64()) / 1000 end
local GAME_WRITABLE = nil   -- does this process have write access to the game's folder?
local log_file = nil
local function log(text)
    if not log_file then
        I.mkdirs(I.logs)
        log_file = io.open(I.logs .. '/SHODANStatEditorHost.log', 'w')
        if not log_file then
            -- no writable profile folder: keep the log beside the program, so a save that failed can be
            -- told apart from one that never happened
            log_file = io.open(here .. 'SHODANStatEditorHost.log', 'w')
        end
        if not log_file then log_file = false end
    end
    if log_file then log_file:write(os.date('%H:%M:%S '), text, '\n'); log_file:flush() end
end

-- The window's own colours follow the panel's theme (Settings > Theme). The light one is the DSH
-- desktop GUI's palette (#f9fafb / #ffffff / #eceef0 / #0f1115 / #81858c / #4176e6).
local current_state = nil   -- the panel's table (set once it is loaded, below)
-- the theme: the panel publishes it in the global SHODAN_THEME (rawset, in its own file) so the window's
-- chrome and the panel can never disagree about it
local light_now = function() return rawget(_G, 'SHODAN_THEME') == 'light' end
local LIGHT_MAP = {
    [ 8 * 65536 + 11 * 256 + 15 ] = { 255, 255, 255 },
    [ 12 * 65536 + 15 * 256 + 19 ] = { 255, 255, 255 },
    [ 24 * 65536 + 29 * 256 + 36 ] = { 240, 241, 243 },
    [ 28 * 65536 + 34 * 256 + 42 ] = { 232, 234, 238 },
    [ 40 * 65536 + 48 * 256 + 58 ] = { 219, 223, 229 },
    [ 52 * 65536 + 66 * 256 + 80 ] = { 213, 217, 223 },
    [ 70 * 65536 + 82 * 256 + 94 ] = { 229, 231, 235 },
    [ 95 * 65536 + 108 * 256 + 120 ] = { 168, 171, 176 },
    [ 153 * 65536 + 171 * 256 + 184 ] = { 129, 133, 140 },
    [ 238 * 65536 + 242 * 256 + 246 ] = { 15, 17, 21 },
    [ 255 * 65536 + 213 * 256 + 0 ] = { 65, 118, 230 },
    [ 255 * 65536 + 72 * 256 + 60 ] = { 217, 45, 32 },
    [ 255 * 65536 + 150 * 256 + 60 ] = { 217, 119, 6 },
    [ 120 * 65536 + 220 * 256 + 140 ] = { 22, 163, 74 },
}
local function theme_color(c)
    if not light_now() then return c end
    local hit = LIGHT_MAP[c[2] * 65536 + c[3] * 256 + c[4]]
    if hit then return { 255, hit[1], hit[2], hit[3] } end
    return { 255, math.floor(c[2] * 0.15), math.floor(c[3] * 0.15), math.floor(c[4] * 0.15) }
end
local function BACK() return theme_color({ 255, 12, 15, 19 }) end
local function RED() return theme_color({ 255, 255, 72, 60 }) end
local function GOLD() return theme_color({ 255, 255, 213, 0 }) end
local function WHITE() return theme_color({ 255, 238, 242, 246 }) end
local function MUTED() return theme_color({ 255, 153, 171, 184 }) end
local function WARN() return theme_color({ 255, 255, 150, 60 }) end
local function GOOD() return theme_color({ 255, 120, 220, 140 }) end

local function centred(text, y, size, c)
    shim.text(text, (shim.w - shim.text_width(text, size)) / 2, y, size, c)
end

-- a screen with a few lines of text (loading, problems)
local function screen(lines)
    shim.fill(0, 0, shim.w, shim.h, BACK())
    local s = shim.h / 1080
    local y = shim.h * 0.42
    for k, line in ipairs(lines) do
        local size = (k == 1 and 34 or 20) * s
        centred(line, y, size, k == 1 and GOLD() or MUTED())
        y = y + size * 1.8
    end
    shim.present()
end

local function fatal(text)
    log('stopped: ' .. text)
    shim.message_box(text, 0x10)
    os.exit(1)
end

-- ---------------------------------------------------------------- start
-- where the window was when it last closed: its top left (window.txt: x y)
local PLACE = I.home .. '/window.txt'
local function saved_place()
    local f = io.open(PLACE, 'r')
    local text = f and f:read('*a') or ''
    if f then f:close() end
    local x, y = text:match('^(%-?%d+) (%-?%d+)')
    return x and { tonumber(x), tonumber(y) } or nil
end

local function main()
    shim.open('SHODAN Stat Editor Offline', saved_place())
    shim.pump()
    local migrated = I.migrate()
    if migrated then log('copied ' .. migrated .. ' files from the CowboyBingus folder') end
    screen({ 'SHODAN Stat Editor Offline', 'Looking for Helldivers 2...' })
    local exe_dir = here:gsub('[/\\]app[/\\]$', ''):gsub('[/\\]$', '')
    local game = I.find_game(exe_dir)
    -- whether this process may write into the game's folder decides Install (and Restore) later: say so now,
    -- so the panel can offer the elevated restart before anything fails
    if game then
        local ok = I.game_writable(game)
        GAME_WRITABLE = ok
        log('game folder: ' .. game .. (ok and ' (writable)' or ' (NOT writable: run as administrator)'))
    end
    if not game then
        fatal('Helldivers 2 was not found.\n\nWrite the path of its folder (the one holding "data") into\n'
              .. I.home:gsub('/', '\\') .. '\\game folder.txt\nand start again.')
    end
    log('game: ' .. game)
    log('hash search: ' .. (G.native and 'native, every core' or 'Lua (shodan_hash.dll not found)'))
    screen({ 'SHODAN Stat Editor Offline', 'Reading the game\'s data files...' })
    shim.pump()
    local originals, ours, problems, count = I.originals(game)
    if count == 0 then fatal('No game data files in ' .. game) end
    -- read on demand: only a file whose kept original is stale is opened twice
    local function bytes_at(path)
        local handle = io.open(path, 'rb')
        if not handle then return nil end
        local data = handle:read('*a')
        handle:close()
        return data
    end
    local currents = setmetatable({}, { __index = function(t, name)
        local data = bytes_at(game .. '/' .. name)
        rawset(t, name, data)
        return data
    end })
    for _, p in ipairs(D.load(game, originals, currents)) do problems[#problems + 1] = p end
    for _, p in ipairs(problems) do log('problem: ' .. p) end
    local loaded = 0
    for _ in pairs(D.files) do loaded = loaded + 1 end
    log(string.format('%d of %d files loaded, %d installed by an earlier install', loaded, count,
        (function() local n = 0; for _ in pairs(ours) do n = n + 1 end return n end)()))
    if loaded == 0 then
        fatal('None of the game\'s data files could be read:\n\n' .. table.concat(problems, '\n', 1, math.min(#problems, 8))
              .. '\n\nVerify the game files in Steam and start again.')
    end
    if #problems > 0 then
        shim.message_box('Some of the game\'s data files are not as this editor expects; their stats cannot be edited:\n\n'
                         .. table.concat(problems, '\n', 1, math.min(#problems, 10))
                         .. '\n\nIf another tool changed them, verify the game files in Steam.', 0x30)
    end

    -- ------------------------------------------------------------ the editor
    screen({ 'SHODAN Stat Editor Offline', 'Finding the stats...' })
    rawset(_G, 'SHODAN_OFFLINE', true)
    -- the panel's first language (until one is chosen in Settings): Windows' display language, if translated
    pcall(ffi.cdef, 'uint16_t GetUserDefaultUILanguage(void);')
    local id = ffi.C.GetUserDefaultUILanguage()
    local primary, sub = id % 1024, math.floor(id / 1024)
    if rawget(_G, 'SHODAN_OFFLINE_LANG') == nil then rawset(_G, 'SHODAN_OFFLINE_LANG', primary == 0x04 and ((sub == 2 or sub == 4) and 'zh-Hans' or 'zh-Hant')
                                      or primary == 0x19 and 'ru' or nil) end
    stingray = shim.engine()
    function update(dt) end
    local editor = arg and arg[1] or here .. 'stat_editor.lua'
    -- the panel resolves its config folder while loading, before it can see `state`: hand it over here
    rawset(_G, 'SHODAN_OFFLINE_DATA', I.home)
    local chunk, why = loadfile(editor)
    if not chunk then fatal('Could not load ' .. editor .. ':\n' .. tostring(why)) end
    local ok, err = pcall(chunk)
    if not ok then fatal('Stat Editor did not start:\n' .. tostring(err)) end
    local state = rawget(_G, 'ShodanStatEditor')
current_state = state
    if type(state) ~= 'table' then fatal('Stat Editor did not start (no state).') end
    log('data folder: ' .. tostring(I.home))
    -- the panel's config.txt lives where the host's files are (the folder the location file chose):
    -- set the hint and the panel's own cache, since it resolved its folders while loading
    state.carry_config = function(from, to) return I.carry(from, to) end   -- "Choose folder"
    state.data_dir_hint = I.home
    if type(state.data_dirs) == 'table' then
        state.data_dirs['StatEditor'] = I.home
        state.data_dir_used = I.home
    end
    local build = U.build(here)   -- app/build.txt: version, commit, channel
    -- the build number goes in the title too: several ATB builds share the upstream version, and this is
    -- the quickest way to tell which one is running
    -- a commit of 'atb147' fills in as ' [ATB 147]', not ' [ATB atb147]'
    local commit = type(build.commit) == 'string' and build.commit or ''
    commit = commit:gsub('^%s*[Aa][Tt][Bb][ -]*', '')
    local tag = ' [ATB' .. (commit ~= '' and (' ' .. commit) or '') ..
                ']'   -- marks the ArmoryTuningBench build: dropdowns, ricochet, fire modes
    shim.set_title('SHODAN Stat Editor Offline v' .. tostring(state.version)
                   .. (build.channel == 'dev' and build.commit and ' (dev ' .. build.commit:sub(1, 7) .. ')' or '')
                   .. tag)
    -- ------------------------------------------------------------ a file dialog (comdlg32)
    -- Export / import of config.txt asks where: the panel calls this and gets a path, or nil when
    -- the user backs out. Windows' own dialog, so it looks like every other file picker.
    do
        local okffi, ffi = pcall(require, 'ffi')
        if okffi then
            pcall(ffi.cdef, [[
                typedef struct { unsigned int lStructSize; void *hwndOwner; void *hInstance;
                    const void *lpstrFilter; void *lpstrCustomFilter; unsigned int nMaxCustFilter;
                    unsigned int nFilterIndex; void *lpstrFile; unsigned int nMaxFile; void *lpstrFileTitle;
                    unsigned int nMaxFileTitle; const void *lpstrInitialDir; const void *lpstrTitle;
                    unsigned int Flags; unsigned short nFileOffset; unsigned short nFileExtension;
                    const void *lpstrDefExt; long long lCustData; void *lpfnHook;
                    const void *lpTemplateName; void *pvReserved; unsigned int dwReserved;
                    unsigned int FlagsEx; } OPENFILENAMEW;
                int GetOpenFileNameW(OPENFILENAMEW *);
                int GetSaveFileNameW(OPENFILENAMEW *);
                int MultiByteToWideChar(unsigned int, unsigned int, const char *, int, void *, int);
                int WideCharToMultiByte(unsigned int, unsigned int, const void *, int, char *, int, const char *, int *);
            ]])
            local ok, comdlg = pcall(ffi.load, 'comdlg32')
            local ok2, k32 = pcall(ffi.load, 'kernel32')
            if ok and ok2 then
                local function wide(text, size)   -- utf-8 -> a NUL-terminated wide buffer
                    local buf = ffi.new('uint16_t[?]', size or (#text + 2))
                    local n = k32.MultiByteToWideChar(65001, 0, text, #text, buf, size or (#text + 2))
                    if n < 0 then n = 0 end
                    if n < (size or (#text + 2)) then buf[n] = 0 end
                    return buf
                end
                local function narrow(buf, chars)   -- wide buffer -> utf-8
                    local out = ffi.new('char[?]', chars * 3 + 8)
                    local n = k32.WideCharToMultiByte(65001, 0, buf, chars, out, chars * 3 + 8, nil, nil)
                    if n <= 0 then return nil end
                    return ffi.string(out, n)
                end
                local FILTER = 'Text files (*.txt)\0*.txt\0All files (*.*)\0*.*\0\0'
                state.pick_file = function(save, title, initial_dir, default_name)
                    local ofn = ffi.new('OPENFILENAMEW')
                    local file = ffi.new('uint16_t[?]', 2048)
                    local filter = wide(FILTER, #FILTER + 2)
                    local wtitle = title and wide(title, #title + 2) or nil
                    local wdir = initial_dir and wide(initial_dir, #initial_dir + 2) or nil
                    local wext = wide('txt', 8)
                    if default_name and #default_name > 0 then
                        local start = wide(default_name, #default_name + 2)
                        ffi.copy(file, start, (#default_name + 1) * 2)
                    end
                    ofn.lStructSize = ffi.sizeof('OPENFILENAMEW')
                    ofn.lpstrFilter = filter
                    ofn.nFilterIndex = 1
                    ofn.lpstrFile = file
                    ofn.nMaxFile = 2048
                    ofn.lpstrTitle = wtitle
                    ofn.lpstrInitialDir = wdir
                    ofn.lpstrDefExt = wext
                    -- OFN_EXPLORER | OFN_NOCHANGEDIR | (save: OVERWRITEPROMPT, HIDEREADONLY)
                    ofn.Flags = 0x00080000 + 0x00000008 + (save and (0x00000002 + 0x00000004) or 0x00001000)
                    local done = (save and comdlg.GetSaveFileNameW or comdlg.GetOpenFileNameW)(ofn)
                    if done == 0 then return nil end
                    local n = 0
                    while n < 2047 and file[n] ~= 0 do n = n + 1 end
                    if n == 0 then return nil end
                    return narrow(file, n)
                end
                state.has_file_dialog = true
                log('file dialog: comdlg32 ready')
            else
                log('file dialog: comdlg32 not available (' .. tostring(comdlg) .. ')')
            end
        end
    end
    -- ------------------------------------------------------------ a folder picker (shell32)
    -- "Change folder" asks where the settings should live.
    do
        local okffi, ffi = pcall(require, 'ffi')
        if okffi then
            pcall(ffi.cdef, [[
                typedef struct { void *hwndOwner; void *pidlRoot; uint16_t *pszDisplayName; const uint16_t *lpszTitle;
                    unsigned int ulFlags; void *lpfn; long long lParam; int iImage; } BROWSEINFOW;
                void *SHBrowseForFolderW(BROWSEINFOW *);
                int SHGetPathFromIDListW(const void *pidl, uint16_t *path);
                void CoTaskMemFree(void *memory);
                long CoInitializeEx(void *reserved, unsigned int mode);
                void CoUninitialize(void);
                int MultiByteToWideChar(unsigned int, unsigned int, const char *, int, void *, int);
            ]])
            local ok, shell = pcall(ffi.load, 'shell32')
            local ok2, ole = pcall(ffi.load, 'ole32')
            local ok3, k32 = pcall(ffi.load, 'kernel32')
            if ok and ok2 and ok3 then
                local function wide(text, size)
                    local buf = ffi.new('uint16_t[?]', size or (#text + 2))
                    k32.MultiByteToWideChar(65001, 0, text, #text, buf, size or (#text + 2))
                    buf[#text] = 0
                    return buf
                end
                state.pick_folder = function(title, initial_dir)
                    local title_w = wide(title or 'Choose a folder')
                    local browse = ffi.new('BROWSEINFOW')
                    browse.pszDisplayName = ffi.new('uint16_t[?]', 512)
                    browse.lpszTitle = title_w
                    -- BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_USENEWUI
                    browse.ulFlags = 0x00000001 + 0x00000040 + 0x00000010
                    -- the new-style folder dialog is a COM one: without this it returns nothing at once
                    ole.CoInitializeEx(nil, 2)   -- COINIT_APARTMENTTHREADED
                    local pidl = shell.SHBrowseForFolderW(browse)
                    ole.CoUninitialize()
                    if pidl == nil then return nil end
                    local buf = ffi.new('uint16_t[?]', 2048)
                    local got = shell.SHGetPathFromIDListW(pidl, buf)
                    ole.CoTaskMemFree(pidl)
                    if got == 0 then return nil end
                    local n = 0
                    while n < 2047 and buf[n] ~= 0 do n = n + 1 end
                    if n == 0 then return nil end
                    local out = ffi.new('char[?]', n * 3 + 8)
                    local m = k32.WideCharToMultiByte(65001, 0, buf, n, out, n * 3 + 8, nil, nil)
                    if m <= 0 then return nil end
                    return ffi.string(out, m)
                end
                state.has_folder_dialog = true
                log('folder picker: shell32 ready')
            end
        end
    end
    -- the host's own text in the panel's language, drawn with its font
    -- a way out of "Permission denied": start again with the administrator's rights
    state.relaunch_elevated = function() return I.elevate() end
    state.game_writable = function() return GAME_WRITABLE end
    if GAME_WRITABLE == false then state.needs_admin = true end
    local function tr(text) return type(state.tr) == 'function' and state.tr(text) or text end
    if type(state.lang) == 'function' then shim.lang = state.lang end

    -- ------------------------------------------------------------ the host's bar (below the panel)
    local bar = { hover = nil, message = nil, tone = MUTED(), busy = nil, base = nil, buttons = {} }
    local function layout()
        local s = shim.h / 1080
        local y0, y1 = 1038 * s, 1072 * s
        bar.buttons = {
            { key = 'install', label = 'Install into the game', x0 = 30 * s, x1 = 290 * s, y0 = y0, y1 = y1 },
            { key = 'restore', label = 'Restore the game\'s files', x0 = 302 * s, x1 = 562 * s, y0 = y0, y1 = y1 },
        }
        if bar.release then
            local x1 = shim.w - 30 * s
            bar.buttons[3] = { key = 'update', label = 'Update to ' .. bar.release.label, x0 = x1 - 170 * s, x1 = x1,
                               y0 = 9 * s, y1 = 41 * s, gold = true }   -- top right, in the tagline's place
        end
        -- the titles (paint_bar): Stat Editor, then Enemy Editor once the editor offers the switch
        local x = 30 * s
        bar.titles = {}
        for _, t in ipairs({ { 'title_stat', 'SHODAN Stat Editor', GOLD() }, { 'title_enemy', 'SHODAN Enemy Editor', RED() } }) do
            if t[1] == 'title_stat' or type(state.switch_editor) == 'function' then
                local w = shim.text_width(t[2], 22 * s, true) + 24 * s   -- a box: 12 px each side of the text
                bar.titles[#bar.titles + 1] = { key = t[1], label = t[2], color = t[3], x0 = x, x1 = x + w, y0 = 6 * s, y1 = 42 * s }
                x = x + w + 12 * s
            end
        end
        bar.s, bar.h = s, shim.h
    end
    layout()

    local function installed_count() local n = 0; for _, v in pairs(ours) do if v then n = n + 1 end end return n end

    local function status()
        if bar.busy then return bar.busy, WARN() end
        if bar.message then return bar.message, bar.tone end
        if state.phase ~= 'ready' then return 'Finding the stats...', MUTED() end
        local n = installed_count()
        local dirty = bar.base and state.writes ~= bar.base
        if dirty and n == 0 then return 'Your values are not in the game yet: close the game, then Install.', WARN() end
        if dirty then return 'Changed since the last install: Install to put it in the game.', WARN() end
        if n > 0 then return 'Your values are installed (' .. n .. ' game files). Close the game before installing.', GOOD() end
        return 'The game\'s own files are in place. Close the game, then Install to play with your values.', MUTED()
    end

    local function paint_bar()
        local s = bar.s
        shim.fill(0, 1032 * s, shim.w, shim.h, BACK())
        shim.fill(0, 0, shim.w, 46 * s, BACK())
        -- the two editors' titles, as buttons: the one shown bright in a box of its colour, the other dimmed
        -- (brighter under the mouse); a click swaps
        local enemy = type(state.enemy_on) == 'function' and state.enemy_on()
        local function toward_back(c, k)
            return { 255, math.floor(BACK()[2] + (c[2] - BACK()[2]) * k), math.floor(BACK()[3] + (c[3] - BACK()[3]) * k),
                     math.floor(BACK()[4] + (c[4] - BACK()[4]) * k) }
        end
        for _, t in ipairs(bar.titles) do
            local on = (t.key == 'title_enemy') == (enemy and true or false)
            local hovered = bar.hover == t.key and not on
            -- taken fresh every frame, NOT from the table `layout()` built: that one runs once, so a colour
            -- captured there keeps the theme it was built with (a switch left the first title gold)
            local tc = (t.key == 'title_enemy') and RED() or GOLD()
            local c = on and tc or toward_back(tc, hovered and 0.65 or 0.4)
            local fill = on and toward_back(tc, 0.3) or hovered and theme_color({ 255, 40, 48, 58 }) or theme_color({ 255, 24, 29, 36 })
            local edge = on and tc or hovered and toward_back(tc, 0.8) or theme_color({ 255, 70, 82, 94 })
            local e = math.max(1, math.floor(2 * s + 0.5))
            shim.fill(t.x0, t.y0, t.x1, t.y1, fill)
            shim.fill(t.x0, t.y0, t.x1, t.y0 + e, edge); shim.fill(t.x0, t.y1 - e, t.x1, t.y1, edge)
            shim.fill(t.x0, t.y0, t.x0 + e, t.y1, edge); shim.fill(t.x1 - e, t.y0, t.x1, t.y1, edge)
            shim.flush()
            shim.text(t.label, t.x0 + 12 * s, (t.y0 + t.y1) / 2 + 22 * s * 0.35, 22 * s, c, true)
        end
        local t = tr('OFFLINE  -  edits the game\'s files; they apply when the game starts')
        if not bar.release then
            -- smaller where it would run into the titles (a longer translation)
            local last = bar.titles[#bar.titles]
            local room, size = shim.w - 30 * s - (last and last.x1 + 16 * s or 0), 15 * s
            while size > 10 * s and shim.text_width(t, size) > room do size = size - 0.5 * s end
            shim.text(t, shim.w - 30 * s - shim.text_width(t, size), 31 * s, size, MUTED())
        end
        for _, b in ipairs(bar.buttons) do
            local hovered = bar.hover == b.key and not bar.busy
            shim.fill(b.x0, b.y0, b.x1, b.y1, hovered and theme_color({ 255, 52, 66, 80 }) or theme_color({ 255, 28, 34, 42 }))
            local edge = hovered and GOLD() or theme_color({ 255, 70, 82, 94 })
            local e = math.max(1, math.floor(2 * s + 0.5))
            shim.fill(b.x0, b.y0, b.x1, b.y0 + e, edge); shim.fill(b.x0, b.y1 - e, b.x1, b.y1, edge)
            shim.fill(b.x0, b.y0, b.x0 + e, b.y1, edge); shim.fill(b.x1 - e, b.y0, b.x1, b.y1, edge)
            shim.flush()
            local size, label = 16 * s, tr(b.label)
            while size > 10 * s and shim.text_width(label, size) > b.x1 - b.x0 - 12 * s do size = size - 0.5 end
            shim.text(label, (b.x0 + b.x1 - shim.text_width(label, size)) / 2, (b.y0 + b.y1) / 2 + size * 0.35, size,
                      b.gold and GOLD() or WHITE())
        end
        local text, tone = status()
        text = tr(text)
        local x = 576 * s
        local size = 14 * s
        local limit = shim.w - 30 * s - x
        while size > 9 * s and shim.text_width(text, size) > limit do size = size - 0.5 end
        shim.text(text, x, 1055 * s + size * 0.35, size, tone)
    end

    local function paint()
        if state.phase == 'ready' then
            shim.paint_guis(BACK())
        else
            shim.fill(0, 0, shim.w, shim.h, BACK())
            centred(tr('Finding the stats...'), shim.h * 0.45, 30 * bar.s, GOLD())
            centred(tostring(state.status or ''), shim.h * 0.45 + 40 * bar.s, 18 * bar.s, MUTED())
        end
        paint_bar()
        shim.present()
    end

    local function say(text, tone) bar.message, bar.tone = text, tone or MUTED() end

    local function busy(text)
        bar.busy = text
        paint()
        shim.pump()
    end

    -- ------------------------------------------------------------ install / restore
    local function install()
        if I.game_running() then say('Helldivers 2 is running: close it, then Install.', WARN()); return end
        busy('Installing: finding what changed...')
        local changes = D.diff()
        local stacked, why_not = D.stack(changes, state.stacks and state.stacks(), log, state.own_off and state.own_off())
        if not stacked then
            for _, c in ipairs(changes) do G.free(c.plain) end
            bar.busy = nil
            log('install stopped: passive stacking: ' .. tostring(why_not))
            say('Not installed: the armor passives could not be stacked (' .. tostring(why_not) .. '). Nothing was changed.', WARN())
            return
        end
        local coded
        coded, why_not = D.codes(changes, state.codes and state.codes(), log)
        if not coded then
            for _, c in ipairs(changes) do G.free(c.plain) end
            bar.busy = nil
            log('install stopped: stratagem codes: ' .. tostring(why_not))
            say('Not installed: the stratagem codes could not be set (' .. tostring(why_not) .. '). Nothing was changed.', WARN())
            return
        end
        local writes, made, back = {}, 0, 0
        for k, c in ipairs(changes) do
            busy(string.format('Installing: preparing %s (%d of %d)...', c.name, k, #changes))
            local sealed, why = D.build(c, function(text) log(c.name .. ': ' .. text); shim.pump() end)
            if not sealed then
                for j = k + 1, #changes do G.free(changes[j].plain) end
                bar.busy = nil
                log('install stopped: ' .. c.name .. ': ' .. tostring(why))
                say('Not installed: ' .. c.name .. ' could not be prepared (' .. tostring(why) .. '). Nothing was changed.', WARN())
                return
            end
            writes[c.name], made = sealed, made + 1
        end
        for name, mine in pairs(ours) do
            if mine and not writes[name] then writes[name], back = originals[name], back + 1 end
        end
        if not next(writes) then
            bar.busy, bar.base = nil, state.writes
            say('Nothing to install: your values are the game\'s own.', GOOD())
            return
        end
        busy('Installing: writing the files...')
        local done, why = I.write_files(game, writes, originals)
        bar.busy = nil
        if not done then
            log('install failed: ' .. tostring(why))
    -- a permission problem has a way out (the panel offers it): remember it for the Settings page
    if tostring(why):find('not allowed to write') or tostring(why):find('Permission denied') then
        if type(state) == 'table' then state.needs_admin = true end
    end
            say('Not installed: ' .. tostring(why), WARN())
            return
        end
        for name, data in pairs(writes) do ours[name] = data ~= originals[name] end
        bar.base = state.writes
        log(string.format('installed: %d changed, %d back to the original', made, back))
        say(string.format('Installed (%d game files changed%s). Start the game to play with your values.', made,
            back > 0 and ', ' .. back .. ' back to the original' or ''), GOOD())
    end

    local function restore()
        if I.game_running() then say('Helldivers 2 is running: close it, then restore.', WARN()); return end
        local writes = {}
        for name, mine in pairs(ours) do if mine then writes[name] = originals[name] end end
        if not next(writes) then say('The game\'s own files are already in place.', GOOD()); return end
        busy('Restoring the game\'s files...')
        local names = {}
        for name in pairs(writes) do names[#names + 1] = name end
        local done, why = I.write_files(game, writes, originals, true)
        bar.busy = nil
        if not done then say('Not restored: ' .. tostring(why), WARN()); return end
        -- files another tool changed since: left as they are (theirs now); files another mod had changed before
        -- this editor: back to that mod's version, which Steam's file check replaces (issue #90)
        local modded = 0
        for _, name in ipairs(names) do
            ours[name] = false
            if writes[name] and D.modded[name] then modded = modded + 1 end
        end
        for _, name in ipairs(why) do log('restore skipped ' .. name .. ': another tool changed it since') end
        bar.base = nil
        log('restored the originals')
        say('The game\'s files are back as they were before this editor. Your values stay saved here (Install puts them in again).'
            .. (modded > 0 and string.format(' %d of them still hold another mod\'s changes: Steam\'s "Verify integrity of game files" puts back the game\'s own.', modded) or ''), GOOD())
    end

    -- ------------------------------------------------------------ updates (update.lua)
    local exe_dir = exe_dir
    local function update_program()
        local release = bar.release
        busy('Updating: downloading ' .. release.label .. '...')
        local zip = U.dir .. '/' .. release.name
        local job, why = U.fetch(release.url, zip)
        local done = nil
        if job then
            repeat
                if not shim.pump() then bar.busy = nil; return false end
                shim.sleep(20)
                done, why = U.poll(job)
            until done ~= nil
        end
        if not done then
            bar.busy = nil
            log('update: download failed: ' .. tostring(why))
            say('Update failed: ' .. tostring(why) .. '. The release page has it: ' .. U.PAGE, WARN())
            return false
        end
        busy('Updating: installing ' .. release.label .. '...')
        local exe, problem = U.install(zip, exe_dir, log)
        bar.busy = nil
        if not exe then
            log('update: not installed: ' .. tostring(problem))
            say('Update failed: ' .. tostring(problem) .. '. Nothing was changed.', WARN())
            return false
        end
        log('update: ' .. release.label .. ' installed, restarting: ' .. exe)
        U.note(release.label)
        bar.restart = exe
        return true
    end

    -- ------------------------------------------------------------ the frame loop
    local painted, was_down, armed, said_ready = nil, false, nil, false
    local last = clock()
    while shim.pump() do
        local now = clock()
        update(math.min(0.1, now - last))
        last = now
        if bar.h ~= shim.h then layout() end   -- moved onto another screen: sized for that one
        if state.phase == 'ready' and not said_ready then
            said_ready = true
            bar.base = installed_count() > 0 and state.writes or nil
            log(string.format('ready: %s weapons, %s values applied, %s refused', tostring(state.weapons),
                tostring(state.applied), tostring(state.refused)))
            local stacks = state.stacks and state.stacks() or {}
            local own_off = state.own_off and state.own_off() or {}
            if installed_count() == 0 and ((state.applied or 0) > 0 or next(stacks) or next(own_off)) then bar.base = -1 end
            if I.game_running() then say('Helldivers 2 is running: you can edit, but close it before you Install.', WARN()) end
            local updated = U.cleanup()
            if updated then say('Updated to ' .. updated .. '.', GOOD()) end
        end
        -- updates: asked at start, and again when Settings > Update channel changes
        local channel = type(state.update_channel) == 'function' and state.update_channel() or 'releases'
        if said_ready and U.available and channel ~= bar.channel and not U.checking and not bar.restart then
            bar.channel = channel
            if bar.release then bar.release = nil; layout() end
            U.check(channel)
        end
        if U.checking then
            local current = { version = state.version, commit = build.commit }
            local release = U.check_poll(current)
            if release and bar.channel ~= U.channel then release = nil end   -- the channel changed meanwhile
            if release then
                bar.release = release
                layout()
                log('update: ' .. release.label .. ' is available (' .. release.name .. ')')
                -- Settings > Updates: Automatic
                if type(state.updates) == 'function' and state.updates() == 'auto' and update_program() then break end
            elseif release == false then
                log('update: nothing newer on ' .. tostring(U.channel) .. ' than v' .. tostring(current.version)
                    .. (current.commit and ' (' .. current.commit:sub(1, 7) .. ')' or ''))
            end
        end
        -- the bar's buttons
        local x, y = nil, nil
        if shim.focused() then x, y = shim.cursor() end
        local hover = nil
        for _, b in ipairs(bar.buttons) do
            if x and x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1 then hover = b.key end
        end
        if #bar.titles > 1 then
            for _, b in ipairs(bar.titles) do
                if x and x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1 then hover = b.key end
            end
        end
        bar.hover = hover
        local down = shim.focused() and shim.key_down(0x01)
        if down and not was_down then armed = hover end
        if not down and was_down and armed and armed == hover and state.phase == 'ready' then
            bar.message = nil
            if hover == 'install' then install() elseif hover == 'restore' then restore()
            elseif hover == 'update' and update_program() then break
            elseif hover == 'title_stat' or hover == 'title_enemy' then state.switch_editor(hover == 'title_enemy') end
            armed = nil
        end
        was_down = down
        local text = status()
        local signature = table.concat({ shim.version, state.phase, tostring(state.status), tostring(hover), text,
                                         shim.lang(), bar.release and bar.release.label or '' }, '|')
        if signature ~= painted then
            painted = signature
            paint()
        end
        shim.sleep(state.phase == 'ready' and 10 or 1)
    end
    if shim.place then
        I.mkdirs(I.home)
        local f = io.open(PLACE, 'w')
        if f then f:write(shim.place[1], ' ', shim.place[2], '\n'); f:close() end
    end
    -- the editor saves its values a moment after a change
    local stop = clock() + 1.5
    while clock() < stop do update(0.05); shim.sleep(20) end
    if bar.restart then
        local go = true
        if go and not U.launch(bar.restart) then
            shim.message_box('Updated. Start ' .. bar.restart:gsub('/', '\\') .. ' again.', 0x40)
        end
    end
    log('closed')
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    log('error: ' .. tostring(err))
    shim.message_box('SHODAN Stat Editor Offline stopped:\n\n' .. tostring(err), 0x10)
end
