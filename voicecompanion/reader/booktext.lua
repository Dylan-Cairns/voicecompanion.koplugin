--[[--
Access to the book's text and on-screen positions, for reflowable documents
(EPUB, FB2, HTML, …) rendered by crengine.

crengine exposes word navigation but no sentence navigation, so sentences
are built here by walking words: a sentence ends after . ! ? … (unless it
is an abbreviation, or the next word starts in lowercase), at a paragraph
break, or, for a very long sentence, at a clause break (, ; : —) after
SOFT_WORDS words and in any case after MAX_WORDS words.
--]]

local BookText = {
    SOFT_WORDS = 60,
    MAX_WORDS = 120,
}

local ABBREVIATIONS = {
    mr = true, mrs = true, ms = true, dr = true, prof = true, st = true, jr = true, sr = true,
    vs = true, etc = true, ["e.g"] = true, ["i.e"] = true, vol = true, fig = true,
    gen = true, col = true, capt = true, lt = true, sgt = true, rev = true, mt = true,
}

function BookText.isReflowable(ui)
    return ui and ui.rolling ~= nil and ui.document ~= nil
        and ui.document.getNextVisibleWordStart ~= nil
end

--- Normalize `xp` to the start of the word it is in (or the next word).
function BookText.wordStart(ui, xp)
    local doc = ui.document
    local ok, we = pcall(doc.getNextVisibleWordEnd, doc, xp)
    if not ok or not we then return nil end
    local ok2, ws = pcall(doc.getPrevVisibleWordStart, doc, we)
    if ok2 and ws then return ws end
    return nil
end

--- Classify the text between one word's start and the next word's start
-- ("word" + punctuation + spaces/newlines): does a sentence end here?
-- `next_word` is the following word's text (or nil at the end).
function BookText.endsSentence(chunk, next_word)
    if chunk:find("\n") then return true end   -- paragraph / block break
    local s = chunk:gsub("%s+$", ""):gsub("\226\128\166", "...")   -- … -> ...
    -- Drop the next sentence's opening quote or bracket: him. “It ...
    while true do
        local t = s:gsub("%s*[%(%[]$", ""):gsub("%s*\226\128[\156\152]$", ""):gsub("%s*\194\171$", "")
        if t == s then break end
        s = t
    end
    -- Strip closing quotes and brackets: ” ’ » " ' ) ]
    while true do
        local t = s:gsub("[\"')%]]$", ""):gsub("\226\128[\157\153]$", ""):gsub("\194\187$", "")
        if t == s then break end
        s = t
    end
    local last = s:sub(-1)
    if last ~= "." and last ~= "!" and last ~= "?" then return false end
    if last == "." and not s:find("%.%.$") then
        local word = s:match("([^%s]+)%.$") or ""
        local bare = word:lower():gsub("^[%(\"']+", ""):gsub("^\226\128[\156\152]", "")
        if ABBREVIATIONS[bare] then return false end
        -- "No. 5", but "I said no. Then"
        if bare == "no" and next_word and next_word:match("^%d") then return false end
        if #bare == 1 and bare:match("%a") then return false end   -- initials: "J. Smith"
    end
    if next_word and next_word:match("^%l") then return false end
    return true
end

-- Inline elements: a change only in these does not start a new block.
local INLINE = {
    a = true, abbr = true, b = true, big = true, cite = true, code = true, del = true,
    dfn = true, em = true, font = true, i = true, ins = true, kbd = true, q = true,
    s = true, samp = true, small = true, span = true, strike = true, strong = true,
    sub = true, sup = true, tt = true, u = true, var = true,
}

--- The block-level part of an xpointer path, e.g.
-- "/body/DocFragment/body/p[3]/em/text().4" -> "/body/DocFragment/body/p[3]"
function BookText.blockPath(xp)
    local path = (xp or ""):gsub("/text%(%)[^/]*$", ""):gsub("%.%d+$", "")
    while true do
        local parent, tag = path:match("^(.*)/([%a][%w]*)[^/]*$")
        if not tag or not INLINE[tag:lower()] then break end
        path = parent
    end
    return path
end

local CLOSING = { ".", "!", "?", "\"", "'", ")", "]", ":", ";", ",",
    "\226\128\166", "\226\128\157", "\226\128\153", "\194\187",   -- … ” ’ »
    "\226\128\148", "\226\128\147" }  -- — –

-- A clause ends here: a long sentence may be split after this chunk.
local function endsClause(chunk)
    local rest = chunk:gsub("^[^%s%p\128-\255]+", "")
    return rest:find("^[,;:]") ~= nil or rest:find("^\226\128[\147\148]") ~= nil
end

--- `xp` moved forward over `text` (the characters right after it), or
-- nil when the document's characters there don't match.  Steps until the
-- text matches: a step can also cross a text node boundary without
-- passing a character.
local function advanceOver(doc, xp, text)
    local want = text:gsub("%s+", "")
    local target = xp
    for _i = 1, 2 * #want + 2 do
        local ok, nxt = pcall(doc.getNextVisibleChar, doc, target)
        if not ok or not nxt or nxt == target then return nil end
        target = nxt
        local got = (doc:getTextFromXPointers(xp, target) or ""):gsub("%s+", "")
        if got == want then return target end
        if #got > #want then return nil end
    end
    return nil
end

--- The leading run of closing punctuation in `s` (stops at anything else,
-- e.g. the next block's opening quote).
function BookText.closingPunctuation(s)
    local out, i = {}, 1
    while i <= #s do
        local matched
        for _j, p in ipairs(CLOSING) do
            if s:sub(i, i + #p - 1) == p then matched = p break end
        end
        if not matched then break end
        table.insert(out, matched)
        i = i + #matched
    end
    return table.concat(out)
end

-- ── Citations ──────────────────────────────────────────────────────────
--
-- vault-reader books mark evidence and footnote references with
-- epub:type="noteref" / role="doc-noteref".  Those anchors are citation
-- labels: they stay visible and tappable, but read-aloud can leave them out
-- of the spoken text.

-- The nearest enclosing <a> in an xpointer's element path, or nil.
function BookText.anchorPath(xp)
    local path = (xp or ""):gsub("/text%(%)[^/]*$", ""):gsub("%.%d+$", "")
    local segments = {}
    for segment in path:gmatch("[^/]+") do table.insert(segments, segment) end
    for i = #segments, 1, -1 do
        if segments[i]:match("^a%[%d+%]$") or segments[i] == "a" then
            return "/" .. table.concat(segments, "/", 1, i)
        end
    end
    return nil
end

local citation_cache = setmetatable({}, { __mode = "k" })

--- Whether `xp` is inside an <a epub:type="noteref"> (or role
-- doc-noteref).  Results are cached per document and anchor.
function BookText.isCitationAnchor(ui, xp)
    local anchor = BookText.anchorPath(xp)
    local doc = ui and ui.document
    if not anchor or not doc or type(doc.getHTMLFromXPointer) ~= "function" then
        return false
    end
    local cache = citation_cache[doc]
    if not cache then
        cache = {}
        citation_cache[doc] = cache
    end
    if cache[anchor] == nil then
        local ok, html = pcall(doc.getHTMLFromXPointer, doc, anchor, 0x1001)
        local found = false
        if ok and type(html) == "string" then
            local h = html:lower()
            found = h:find("epub:type%s*=%s*['\"][^'\"]*noteref") ~= nil
                or h:find("role%s*=%s*['\"][^'\"]*doc%-noteref") ~= nil
        end
        cache[anchor] = found
    end
    return cache[anchor]
end

-- compareXPointers(a, b) is 1 when b comes after a.
local function isBefore(doc, a, b)
    if a == b then return true end
    local ok, cmp = pcall(doc.compareXPointers, doc, a, b)
    return ok and cmp == 1 or false
end

local function isAfter(doc, a, b)
    if a == b then return false end
    local ok, cmp = pcall(doc.compareXPointers, doc, a, b)
    return ok and cmp == -1 or false
end

-- Expand a word's position over the rest of the citation anchor's text.
local function citationStart(doc, xp, anchor)
    for _i = 1, 400 do
        local ok, prev = pcall(doc.getPrevVisibleChar, doc, xp)
        if not ok or not prev or prev == xp then break end
        if BookText.anchorPath(prev) ~= anchor then break end
        xp = prev
    end
    return xp
end

local function citationEnd(doc, xp, anchor)
    for _i = 1, 400 do
        if BookText.anchorPath(xp) ~= anchor then break end
        local ok, nxt = pcall(doc.getNextVisibleChar, doc, xp)
        if not ok or not nxt or nxt == xp then break end
        xp = nxt
    end
    return xp
end

--- Tidy the gaps left by removed citation labels: empty brackets, a space
-- before punctuation, or a separator at the start of the sentence.
function BookText.cleanCitationGaps(text)
    local t = text or ""
    t = t:gsub("%(%s*%)", ""):gsub("%[%s*%]", ""):gsub("{%s*}", "")
    t = t:gsub("%s+([,;:%.!%?])", "%1")
    t = t:gsub("^[,;:]+%s*", "")
    t = t:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return t
end

--- Build the sentence starting at word start `ws`.
-- `opts.skip_citations` leaves citation labels out of `text`; the highlight
-- (pos0..pos1) still covers them.  Sentence splitting also ignores them.
-- @return { text, pos0, pos1, next_start } or nil
function BookText.sentenceFrom(ui, ws, opts)
    local doc = ui.document
    if not ws then return nil end
    local skip_citations = opts and opts.skip_citations
    local pos0 = ws
    -- Include an opening quote or bracket right before the first word.
    local ok_p, prev = pcall(doc.getPrevVisibleChar, doc, ws)
    if ok_p and prev then
        local c = doc:getTextFromXPointers(prev, ws) or ""
        if c == "\"" or c == "'" or c == "(" or c == "[" or c == "\226\128\156"
                or c == "\226\128\152" or c == "\194\171" then
            pos0 = prev
        end
    end
    local pos1
    local next_start
    local ends_block = false
    local trailing = ""
    local words = 0
    local cur = ws
    local cuts = {}       -- ranges of citation anchors to leave out of `text`
    local cut           -- the citation anchor being walked
    local cut_anchor    -- its path
    while true do
        local ok_e, we = pcall(doc.getNextVisibleWordEnd, doc, cur)
        if not ok_e or not we then pos1 = cur break end

        local anchor = skip_citations and BookText.anchorPath(cur) or nil
        local citation = anchor and BookText.isCitationAnchor(ui, cur) or false
        if citation then
            if anchor ~= cut_anchor then
                cut = { citationStart(doc, cur, anchor), citationEnd(doc, we, anchor) }
                table.insert(cuts, cut)
                cut_anchor = anchor
            end
        else
            cut, cut_anchor = nil, nil
        end

        local ok_s, nws = pcall(doc.getNextVisibleWordStart, doc, we)
        if not citation then words = words + 1 end
        if not ok_s or not nws or nws == cur then
            pos1 = we
            next_start = nil
            break
        end
        local chunk = doc:getTextFromXPointers(cur, nws) or ""
        local split_chunk = chunk
        if citation then
            -- Ignore label text (including punctuation between its words)
            -- when deciding where the sentence ends.
            if BookText.anchorPath(nws) == anchor then
                split_chunk = ""
            else
                split_chunk = doc:getTextFromXPointers(cut[2], nws) or ""
            end
        end
        local next_word
        if split_chunk:find("[%.!%?]") or split_chunk:find("\226\128\166") then
            local ok_n, nwe = pcall(doc.getNextVisibleWordEnd, doc, nws)
            next_word = ok_n and nwe and doc:getTextFromXPointers(nws, nwe) or nil
        end
        local new_block = BookText.blockPath(cur) ~= BookText.blockPath(nws)
        if new_block or BookText.endsSentence(split_chunk, next_word) or words >= BookText.MAX_WORDS
                or (words >= BookText.SOFT_WORDS and endsClause(split_chunk)) then
            -- End right after the word's closing punctuation, so the
            -- highlight and the spoken text stop at the full stop, closing
            -- quote or comma (never on the next word or block).
            pos1 = we
            local word_text = doc:getTextFromXPointers(cur, we) or ""
            if word_text ~= "" and chunk:sub(1, #word_text) == word_text then
                local closing = BookText.closingPunctuation(chunk:sub(#word_text + 1))
                if closing ~= "" then
                    local after = advanceOver(doc, we, closing)
                    if after then
                        pos1 = after
                    else
                        trailing = closing   -- at least speak it
                    end
                end
            end
            next_start = nws
            ends_block = new_block or split_chunk:find("\n") ~= nil
            break
        end
        cur = nws
    end
    -- crengine can return text for an empty range at an element boundary
    -- (an xpointer to the first character of an inline element is also the
    -- element's own xpointer), so empty ranges are dropped explicitly.
    local function samePosition(a, b)
        if a == b then return true end
        local ok, cmp = pcall(doc.compareXPointers, doc, a, b)
        return ok and cmp == 0 or false
    end
    local function slice(a, b)
        if samePosition(a, b) then return "" end
        return doc:getTextFromXPointers(a, b) or ""
    end
    local text
    if #cuts > 0 then
        local parts = {}
        local from = pos0
        for _i, c in ipairs(cuts) do
            local start, stop = c[1], c[2]
            if isBefore(doc, start, pos0) then start = pos0 end
            if isAfter(doc, start, pos1) then break end
            if isAfter(doc, stop, pos1) then stop = pos1 end
            table.insert(parts, slice(from, start))
            from = stop
        end
        table.insert(parts, slice(from, pos1))
        text = table.concat(parts)
    else
        text = slice(pos0, pos1)
    end
    text = text .. trailing
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #cuts > 0 then text = BookText.cleanCitationGaps(text) end
    return {
        text = text,
        pos0 = pos0,
        pos1 = pos1,
        next_start = next_start,
        ends_block = ends_block,   -- the paragraph (or other block) ends here
    }
end

--- The sentence starting at (the word containing) `xp`.
function BookText.sentenceAt(ui, xp, opts)
    if not xp then return nil end
    return BookText.sentenceFrom(ui, BookText.wordStart(ui, xp), opts)
end

--- The sentence after `sentence`, or nil at the end of the book.
function BookText.nextSentence(ui, sentence, opts)
    if not sentence.next_start then return nil end
    return BookText.sentenceFrom(ui, sentence.next_start, opts)
end

--- First sentence at the top of the current page.
function BookText.firstSentenceOnPage(ui, opts)
    return BookText.sentenceAt(ui, ui.document:getXPointer(), opts)
end

function BookText.currentPage(ui)
    return ui.document:getCurrentPage()
end

--- Text of pages [from, to] (clamped), whitespace-normalized.
function BookText.pagesText(ui, from, to)
    local doc = ui.document
    local count = doc:getPageCount()
    from = math.max(1, from)
    to = math.min(count, to)
    local text
    if to < count then
        text = doc:getTextFromXPointers(doc:getPageXPointer(from), doc:getPageXPointer(to + 1))
    else
        -- No page after the last one: collect sentences to the end instead.
        text = BookText.sentencesFrom(ui, from)
    end
    return ((text or ""):gsub("%s+", " "))
end

--- Text of up to 200 sentences starting at the top of `page`.
function BookText.sentencesFrom(ui, page)
    local doc = ui.document
    local s = BookText.sentenceAt(ui, doc:getPageXPointer(page))
    local parts = {}
    while s and #parts < 200 do
        table.insert(parts, s.text)
        s = BookText.nextSentence(ui, s)
    end
    return table.concat(parts, " ")
end

--- Book text around the reading position, at most `max_chars`, ending at
-- the current page (text before the position matters most for context).
function BookText.contextText(ui, max_chars)
    if not BookText.isReflowable(ui) then return nil end
    local ok, text = pcall(function()
        local page = BookText.currentPage(ui)
        return BookText.pagesText(ui, page - 3, page)
    end)
    if not ok or not text then return nil end
    if #text > max_chars then
        text = text:sub(-max_chars)
        text = text:gsub("^[\128-\191]+", "")  -- don't start mid UTF-8 char
    end
    return text
end

--- Text of the current page.
function BookText.pageText(ui)
    if not BookText.isReflowable(ui) then return nil end
    local ok, text = pcall(function()
        local page = BookText.currentPage(ui)
        return BookText.pagesText(ui, page, page)
    end)
    return ok and text or nil
end

--- The sentence around a selection, for context (best effort).
function BookText.selectionSentence(ui, selected)
    if not (BookText.isReflowable(ui) and selected and selected.pos0 and selected.pos1) then return nil end
    local ok, text = pcall(function()
        local doc = ui.document
        local a, b = selected.pos0, selected.pos1
        for _i = 1, 40 do
            local p = doc:getPrevVisibleWordStart(a)
            if not p or p == a then break end
            a = p
        end
        for _i = 1, 40 do
            local n = doc:getNextVisibleWordEnd(b)
            if not n or n == b then break end
            b = n
        end
        local before = doc:getTextFromXPointers(a, selected.pos0) or ""
        local middle = doc:getTextFromXPointers(selected.pos0, selected.pos1) or ""
        local after = doc:getTextFromXPointers(selected.pos1, b) or ""
        before = before:match(".*[%.!%?\n][\"'%)]*%s+(.-)$") or before
        after = after:match("^(.-[%.!%?][\"'%)]*)%s") or after
        return ((before .. middle .. after):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
    end)
    return ok and text or nil
end

-- ── Following the reading position across pages ──────────────────────

--- Position right after the last visible page (two in dual-page mode), or
-- nil when the whole rest of the book is visible or the view scrolls.
function BookText.viewEnd(ui)
    local doc = ui.document
    if ui.view and ui.view.view_mode and ui.view.view_mode ~= "page" then return nil end
    local ok, xp = pcall(function()
        local count = doc.getVisiblePageCount and doc:getVisiblePageCount() or 1
        local next_page = doc:getCurrentPage() + math.max(1, count or 1)
        if next_page > doc:getPageCount() then return nil end
        return doc:getPageXPointer(next_page)
    end)
    return ok and xp or nil
end

--- Share of `span` ({pos0, pos1}) that comes before `xp` (0..1), or nil
-- when `xp` is not inside it.
function BookText.fractionBefore(ui, span, xp)
    local doc = ui.document
    local ok, frac = pcall(function()
        -- compareXPointers(a, b) is 1 when b comes after a.
        if doc:compareXPointers(xp, span.pos1) ~= 1 then return nil end
        if doc:compareXPointers(span.pos0, xp) ~= 1 then return nil end
        local before = #(doc:getTextFromXPointers(span.pos0, xp) or "")
        local total = #(doc:getTextFromXPointers(span.pos0, span.pos1) or "")
        if total == 0 then return nil end
        return math.min(1, before / total)
    end)
    return ok and frac or nil
end

-- ── Highlighting the sentence being read ─────────────────────────────

-- Whether the temporary highlight currently shown is ours (so we never
-- clear a selection the user is making).
local owns_highlight = false

function BookText.highlight(ui, sentence)
    local view = ui.view
    if not view or not view.highlight then return end
    local ok, boxes = pcall(ui.document.getScreenBoxesFromPositions, ui.document,
        sentence.pos0, sentence.pos1, true)
    if not ok or not boxes then return end
    view.highlight.temp = { [BookText.currentPage(ui)] = boxes }
    owns_highlight = true
    require("ui/uimanager"):setDirty(view.dialog, "ui")
end

function BookText.clearHighlight(ui)
    local view = ui.view
    if not owns_highlight or not view or not view.highlight then return end
    owns_highlight = false
    view.highlight.temp = {}
    require("ui/uimanager"):setDirty(view.dialog, "ui")
end

return BookText
