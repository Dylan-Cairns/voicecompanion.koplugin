local ReadAloud = require("voicecompanion/features/readaloud")
local BookText = require("voicecompanion/reader/booktext")

-- Sentences as the book walker returns them; positions are numbers.
local function walker(texts, block_ends)
    local i = 0
    return function()
        i = i + 1
        if not texts[i] then return nil end
        return { text = texts[i], pos0 = i * 10, pos1 = i * 10 + 5, ends_block = block_ends and block_ends[i] }
    end
end

local function drain(next_group)
    local out = {}
    for g in next_group do table.insert(out, g) end
    return out
end

describe("ReadAloud.grouper", function()
    it("keeps one sentence per group when the size is 0", function()
        local groups = drain(ReadAloud.grouper(walker({ "A.", "B.", "C." }), 0))
        assert_eq(#groups, 3)
        assert_eq(groups[2].text, "B.")
        assert_eq(groups[2].pos0, 20)
    end)

    it("fills a group up to the size without exceeding it", function()
        local s = string.rep("x", 40) .. "."      -- 41 characters
        local groups = drain(ReadAloud.grouper(walker({ s, s, s, s, s, s }), 100))
        assert_eq(#groups, 3)                    -- two sentences each
        assert_eq(#groups[1].text, 83)
        assert_eq(groups[1].pos0, 10)
        assert_eq(groups[1].pos1, 25, "spans both sentences")
        assert_eq(groups[1].first.pos0, 10)
        assert_eq(groups[1].last.pos0, 20)
    end)

    it("starts small, then grows to the configured size", function()
        local texts = {}
        for i = 1, 40 do texts[i] = string.rep("w", 29) .. "." end   -- 30 chars each
        local groups = drain(ReadAloud.grouper(walker(texts), 300))
        assert_eq(#groups[1].text, 92)     -- three sentences (limit 120)
        assert_eq(#groups[2].text, 216)    -- seven (limit 240)
        assert_eq(#groups[3].text, 278)    -- nine (limit 300)
    end)

    it("ends a group at a paragraph end, not in the middle of the next one", function()
        local s = string.rep("a", 29) .. "."      -- 30 characters
        -- The second sentence ends a paragraph; the third opens the next.
        local groups = drain(ReadAloud.grouper(walker({ s, s, s, s }, { false, true }), 300))
        assert_eq(groups[1].text, s .. " " .. s)
        assert_eq(groups[1].last.pos0, 20)
        assert_eq(groups[1].pos1, 25)
        assert_eq(groups[2].text, s .. " " .. s)
        assert_eq(groups[2].pos0, 30)
    end)

    it("does not end a group at a break that leaves it mostly empty", function()
        local heading = string.rep("h", 19) .. "."      -- 20 characters
        local s = string.rep("a", 29) .. "."             -- 30 characters
        -- A heading alone must not become a request of its own.
        local groups = drain(ReadAloud.grouper(walker({ heading, s, s, s }, { true }), 300))
        assert_eq(#groups[1].text, 20 + 3 * 31)
        assert_eq(groups[1].text:sub(1, 20), heading)
    end)

    it("keeps a newline between paragraphs and ends at the last break", function()
        local s = string.rep("a", 29) .. "."      -- 30 characters
        local ends = { false, false, false, false, true, false, false, false, true }
        local groups = drain(ReadAloud.grouper(walker({ s, s, s, s, s, s, s, s, s, s }, ends), 300))
        assert_eq(#groups[1].text, 92)            -- three sentences
        -- Group 2 runs to the second paragraph end and keeps the break.
        assert_eq(#groups[2].text, 6 * 30 + 4 + 1)
        assert_eq(groups[2].pos0, 40)
        assert_eq(groups[2].pos1, 95)
        local at = groups[2].text:find("\n", 1, true)
        assert_eq(at, 62, "newline after the first paragraph of the group")
        assert_eq(select(2, groups[2].text:gsub("\n", "\n")), 1)
    end)

    it("never exceeds the size, and keeps an over-long sentence whole", function()
        local texts = {}
        for i = 1, 20 do texts[i] = string.rep("z", 40) .. "." end
        local groups = drain(ReadAloud.grouper(walker(texts), 200))
        local read = 0
        for _, g in ipairs(groups) do
            assert_true(#g.text <= 200, "group of " .. #g.text .. " characters")
            read = read + select(2, g.text:gsub("%.", ""))
        end
        assert_eq(read, 20, "every sentence read once")

        local long = string.rep("q", 499) .. "."
        local one = drain(ReadAloud.grouper(walker({ long }), 200))
        assert_eq(#one, 1)
        assert_eq(one[1].text, long)
    end)
end)

describe("ReadAloud:start citation filtering", function()
    it("passes read_aloud.skip_citations to the sentence walker", function()
        local Config = require("voicecompanion/config")
        local old_load = Config.load
        local old_first = BookText.firstSentenceOnPage
        local old_next = BookText.nextSentence
        local seen = {}
        local ok, err = pcall(function()
            Config.load = function()
                return { read_aloud = {
                    skip_citations = true, chunk_chars = 300, prefetch = 1, parallel = 1,
                } }
            end
            BookText.firstSentenceOnPage = function(_, opts)
                seen.first = opts
                return { text = "First.", pos0 = 1, pos1 = 7, ends_block = true }
            end
            BookText.nextSentence = function(_, _, opts)
                seen.next = opts
                return nil
            end
            local voice = { speakSequence = function(_, get) seen.get = get end }
            local plugin = {
                ui = { rolling = {}, document = { getNextVisibleWordStart = function() end } },
                getVoice = function() return voice end,
            }
            ReadAloud:new(plugin):start()
            assert_eq(seen.first.skip_citations, true)
            assert_eq(seen.get(1), "First.")
            assert_eq(seen.next.skip_citations, true)
        end)
        Config.load = old_load
        BookText.firstSentenceOnPage = old_first
        BookText.nextSentence = old_next
        if not ok then error(err, 0) end
    end)
end)

describe("ReadAloud:start grouping", function()
    it("ends a group where a skipped empty sentence ends the paragraph", function()
        local Config = require("voicecompanion/config")
        local old_load = Config.load
        local old_first = BookText.firstSentenceOnPage
        local old_next = BookText.nextSentence
        local a = string.rep("a", 69) .. "."      -- 70 characters
        local b = string.rep("b", 19) .. "."      -- 20 characters
        local sentences = {
            { text = a, pos0 = 1, pos1 = 71, ends_block = false },
            { text = "", pos0 = 72, pos1 = 73, ends_block = true },   -- skipped label
            { text = b, pos0 = 74, pos1 = 94, ends_block = false },
            { text = b, pos0 = 95, pos1 = 115, ends_block = false },
            { text = b, pos0 = 116, pos1 = 136, ends_block = false },
        }
        local out = {}
        local ok, err = pcall(function()
            Config.load = function()
                return { read_aloud = { chunk_chars = 900, prefetch = 1, parallel = 1 } }
            end
            BookText.firstSentenceOnPage = function() return sentences[1] end
            BookText.nextSentence = function(_, s)
                for i, x in ipairs(sentences) do
                    if x == s then return sentences[i + 1] end
                end
            end
            local voice = {
                speakSequence = function(_, get)
                    out[1], out[2], out[3] = get(1), get(2), get(3)
                end,
            }
            local plugin = {
                ui = { rolling = {}, document = { getNextVisibleWordStart = function() end } },
                getVoice = function() return voice end,
            }
            ReadAloud:new(plugin):start()
        end)
        Config.load = old_load
        BookText.firstSentenceOnPage = old_first
        BookText.nextSentence = old_next
        if not ok then error(err, 0) end
        assert_eq(out[1], a, "the paragraph ends before the skipped label")
        assert_eq(out[2], b .. " " .. b .. " " .. b)
        assert_nil(out[3])
    end)
end)

describe("BookText.fractionBefore / viewEnd", function()
    -- A fake document whose xpointers are character offsets.
    local text = string.rep("a", 100)
    local doc = {
        compareXPointers = function(_, a, b) return b > a and 1 or (b == a and 0 or -1) end,
        getTextFromXPointers = function(_, a, b) return text:sub(a + 1, b) end,
        getCurrentPage = function() return 3 end,
        getVisiblePageCount = function() return 2 end,
        getPageCount = function() return 10 end,
        getPageXPointer = function(_, page) return page * 1000 end,
    }
    local ui = { document = doc, view = { view_mode = "page" } }

    it("gives the share of the text before the page end", function()
        assert_eq(BookText.fractionBefore(ui, { pos0 = 20, pos1 = 60 }, 30), 0.25)
    end)

    it("is nil when the page end is outside the span", function()
        assert_nil(BookText.fractionBefore(ui, { pos0 = 20, pos1 = 60 }, 60))
        assert_nil(BookText.fractionBefore(ui, { pos0 = 20, pos1 = 60 }, 10))
    end)

    it("viewEnd is the start of the page after all visible pages", function()
        assert_eq(BookText.viewEnd(ui), 5000)
    end)

    it("viewEnd is nil in scroll mode", function()
        assert_nil(BookText.viewEnd({ document = doc, view = { view_mode = "scroll" } }))
    end)
end)
