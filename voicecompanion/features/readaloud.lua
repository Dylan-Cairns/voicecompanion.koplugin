--[[--
Read the book aloud from the current page.  Sentences are grouped into
requests of up to a few hundred characters (fewer requests, and a steadier
voice from AI models that drift between requests); a group ends at the last
paragraph (or other block) end inside the limit, so a request rarely starts
or stops in the middle of a paragraph.  The group being read is highlighted,
the page turns when the reading reaches the next page, and upcoming groups
are fetched while one plays.  Reflowable documents only.
--]]

local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local BookText = require("voicecompanion/reader/booktext")
local Config = require("voicecompanion/config")
local _ = require("gettext")

local ReadAloud = {
    -- The first groups are kept short so reading starts quickly, then
    -- grow to the configured size: group k is at most FIRST_CHARS * k.
    FIRST_CHARS = 120,
    -- A group may only stop at a paragraph break once it holds at least
    -- this much text (or half its limit, if that is less): headings and
    -- one-line paragraphs would otherwise become requests of their own.
    MIN_BLOCK_CHARS = 120,
    -- Reading speed used when the audio length is unknown (chars/second).
    CHARS_PER_SECOND = 15,
    FOLLOW_INTERVAL = 0.4,
}
ReadAloud.__index = ReadAloud

function ReadAloud:new(plugin)
    return setmetatable({ plugin = plugin, ui = plugin.ui, state = "stopped" }, self)
end

function ReadAloud:isActive()
    return self.state ~= "stopped"
end

local function speakable(text)
    return text and text:find("[%w\128-\255]") ~= nil
end

local function clean(text)
    return (text:gsub("\194\173", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Group sentences into speakable items of at most `target` characters.
-- A group ends at the last paragraph (or other block) end inside the limit,
-- so that requests rarely start or stop in the middle of a paragraph; when
-- the paragraph is longer than the limit, the group ends at a sentence.
-- `next_sentence()` returns the next speakable sentence or nil.
-- @return function() -> group|nil, where a group is
--   { text, pos0, pos1, first (sentence), last (sentence) }
function ReadAloud.grouper(next_sentence, target)
    local count = 0
    local pending = {}   -- sentences pushed back for the next group

    local function pull()
        if pending[1] then return table.remove(pending, 1) end
        return next_sentence()
    end

    return function()
        local s = pull()
        if not s then return nil end
        if not target or target <= 0 then
            -- One sentence per group.
            return { text = s.text, pos0 = s.pos0, pos1 = s.pos1, first = s, last = s }
        end
        count = count + 1
        local limit = math.min(target, ReadAloud.FIRST_CHARS * count)

        local buf, plen = { s }, { #s.text }
        local len = #s.text
        while len < limit do
            local n = pull()
            if not n then break end
            if len + 1 + #n.text > limit then
                table.insert(pending, 1, n)
                break
            end
            len = len + 1 + #n.text
            buf[#buf + 1] = n
            plen[#buf] = len
        end

        -- Stop at the last paragraph end in the group when there is one
        -- late enough to be worth it.
        local floor = math.min(limit / 2, ReadAloud.MIN_BLOCK_CHARS)
        local cut = #buf
        for i = #buf, 1, -1 do
            if buf[i].ends_block and plen[i] >= floor then
                cut = i
                break
            end
        end
        for i = #buf, cut + 1, -1 do
            table.insert(pending, 1, buf[i])
        end

        local parts = {}
        for i = 1, cut do
            -- A newline at a paragraph end makes voices pause as they should.
            if i > 1 then parts[#parts + 1] = buf[i - 1].ends_block and "\n" or " " end
            parts[#parts + 1] = buf[i].text
        end
        return {
            text = table.concat(parts),
            pos0 = buf[1].pos0,
            pos1 = buf[cut].pos1,
            first = buf[1],
            last = buf[cut],
        }
    end
end

--- Start reading at `first` (a sentence or an xpointer) or at the top of the
-- current page.
function ReadAloud:start(first)
    local ui = self.ui
    if not BookText.isReflowable(ui) then
        UIManager:show(InfoMessage:new{ text = _("Reading aloud works with EPUB, FB2 and other reflowable books.") })
        return
    end
    local cfg = Config.load()
    local opts = { skip_citations = cfg.read_aloud.skip_citations == true }
    if type(first) == "string" then
        first = BookText.sentenceAt(ui, first, opts)
    elseif not first then
        first = BookText.firstSentenceOnPage(ui, opts)
    end
    if not first then
        UIManager:show(InfoMessage:new{ text = _("No text found on this page.") })
        return
    end
    self.cfg = cfg
    self.list = {}
    self.state = "playing"
    self.current = nil

    -- Lazily walk the book; only speakable sentences are read.
    local last
    local returned       -- the last sentence handed to the grouper
    local function nextSentence()
        local s
        if last == nil then s = first else s = BookText.nextSentence(ui, last, opts) end
        local guard = 0
        while s and not speakable(s.text) do
            guard = guard + 1
            if guard > 50 then return nil end
            -- An empty sentence (a skipped citation label) can still end a
            -- paragraph; the paragraph ends after the sentence before it.
            if s.ends_block and returned then returned.ends_block = true end
            s = BookText.nextSentence(ui, s, opts)
        end
        if not s then
            if returned then returned.ends_block = true end
            return nil
        end
        last = s
        s.text = clean(s.text)
        returned = s
        return s
    end
    local nextGroup = ReadAloud.grouper(nextSentence, tonumber(cfg.read_aloud.chunk_chars) or 900)
    local list = self.list
    local function get(i)
        while #list < i do
            local g = nextGroup()
            if not g then return nil end
            table.insert(list, g)
        end
        return list[i].text
    end

    self.plugin:getVoice():speakSequence(get, {
        engine = cfg.read_aloud.engine,
        prefetch = cfg.read_aloud.prefetch or 2,
        parallel = cfg.read_aloud.parallel or 2,
    }, {
        on_play = function(i) self:_show(list[i]) end,
        on_done = function(ok, err)
            self:_finish()
            if not ok then self.plugin:showError(err) end
        end,
    })
end

--- Bring the group on screen and highlight it (called as its audio starts).
function ReadAloud:_show(group)
    self.current = group
    local ui, doc = self.ui, self.ui.document
    if not doc:isXPointerInCurrentPage(group.pos0) then
        ui:handleEvent(Event:new("GotoViewRel", 1))
        if not doc:isXPointerInCurrentPage(group.pos0) then
            ui:handleEvent(Event:new("GotoXPointer", group.pos0, group.pos0))
        end
    end
    if self.cfg.read_aloud.highlight then
        BookText.highlight(ui, group)
    end
    -- Count listening as activity so the device doesn't auto-suspend
    -- (the AutoSuspend plugin listens on this hook for user input).
    if UIManager.event_hook then
        pcall(UIManager.event_hook.execute, UIManager.event_hook, "InputEvent")
    end
    self:_follow(group)
end

--- While `group` plays, turn the page when the reading reaches text on
-- the next page (estimated from the share of text before the page end and
-- the playback position).
function ReadAloud:_follow(group)
    self._follow_token = (self._follow_token or 0) + 1
    local token = self._follow_token
    local ui = self.ui
    local voice = self.plugin:getVoice()
    local boundary, frac
    local function poll()
        if token ~= self._follow_token or self.state == "stopped" or self.current ~= group then return end
        local view_end = BookText.viewEnd(ui)
        if not view_end then return end
        if view_end ~= boundary then
            boundary = view_end
            frac = BookText.fractionBefore(ui, group, boundary)
        end
        if not frac then return end   -- the rest of the group is visible
        local pos, total = voice:progress()
        if pos then
            total = total or (#group.text / ReadAloud.CHARS_PER_SECOND * 1000)
            if pos >= frac * total then
                ui:handleEvent(Event:new("GotoViewRel", 1))
                if self.cfg.read_aloud.highlight then BookText.highlight(ui, group) end
            end
        end
        UIManager:scheduleIn(ReadAloud.FOLLOW_INTERVAL, poll)
    end
    UIManager:scheduleIn(ReadAloud.FOLLOW_INTERVAL, poll)
end

function ReadAloud:_finish()
    self.state = "stopped"
    self._follow_token = (self._follow_token or 0) + 1
    BookText.clearHighlight(self.ui)
end

function ReadAloud:stop()
    if self.state == "stopped" then return end
    self:_finish()
    self.current = nil
    self.plugin:getVoice():stop()
end

--- Pause/resume.  File playback pauses in place; the Android system voice
-- (and audio still loading) can't pause, so it stops and later restarts the
-- current sentence.
function ReadAloud:togglePause()
    local voice = self.plugin:getVoice()
    if self.state == "playing" then
        -- Set first: the voice reports its state change right away.
        self.state = "paused"
        if voice:canPause() then
            voice:pause()
        else
            voice:stop()
        end
    elseif self.state == "paused" then
        if voice:isPaused() then
            voice:resume()
            self.state = "playing"
        else
            local from = self.current and self.current.first
            self.state = "stopped"
            self:start(from)
        end
    end
end

return ReadAloud
