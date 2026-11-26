local BookText = require("voicecompanion/reader/booktext")

describe("BookText.endsSentence", function()
    local cases = {
        { "him. ", "The", true },
        { "Mr. ", "Smith", false },
        { "J. ", "Smith", false },
        { "e.g. ", "x", false },
        { "said, ", "and", false },
        { "noticed.\n", "It", true },
        { "wait\226\128\166 ", "Then", true },
        { "\226\128\156Hello!\226\128\157 ", "She", true },
        { "\226\128\156hello\226\128\157 ", "and", false },
        { "end?) ", "Next", true },
        { "him. ", "and", false },          -- lowercase next word continues
        { "Wait... ", "Then", true },
        { "Dr. ", "Who", false },
        { "no. ", "Then", true },           -- "no" ends a sentence
        { "No. ", "5", false },             -- but "No. 5" does not
        { "laughed. \226\128\156", "It", true },  -- next sentence's opening quote
        { "said, \226\128\156", "It", false },
    }
    for _, c in ipairs(cases) do
        it(string.format("%q + %s -> %s", c[1], tostring(c[2]), tostring(c[3])):gsub("\n", "\\n"), function()
            assert_eq(BookText.endsSentence(c[1], c[2]), c[3])
        end)
    end

    it("ends at the end of the book (no next word)", function()
        assert_eq(BookText.endsSentence("the end. ", nil), true)
    end)
end)

describe("BookText.closingPunctuation", function()
    it("returns the leading run of closing marks", function()
        assert_eq(BookText.closingPunctuation(".\226\128\157 Next"), ".\226\128\157")
        assert_eq(BookText.closingPunctuation("?!) word"), "?!)")
    end)

    it("stops at an opening quote or letters", function()
        assert_eq(BookText.closingPunctuation("\226\128\156Hello"), "")
        assert_eq(BookText.closingPunctuation(".abc."), ".")
    end)

    it("handles empty input", function()
        assert_eq(BookText.closingPunctuation(""), "")
    end)
end)

describe("BookText.blockPath", function()
    it("strips text() and inline elements", function()
        assert_eq(BookText.blockPath("/body/DocFragment/body/p[3]/em/text().4"),
            "/body/DocFragment/body/p[3]")
    end)

    it("keeps block elements", function()
        assert_eq(BookText.blockPath("/body/DocFragment/body/p[3]/text().0"),
            "/body/DocFragment/body/p[3]")
        assert_eq(BookText.blockPath("/body/DocFragment/body/div[2]/p[1]"),
            "/body/DocFragment/body/div[2]/p[1]")
    end)

    it("strips nested inline elements", function()
        assert_eq(BookText.blockPath("/body/DocFragment/body/p[1]/b/i/text().2"),
            "/body/DocFragment/body/p[1]")
    end)

    it("tolerates nil", function()
        assert_eq(BookText.blockPath(nil), "")
    end)
end)

describe("BookText.anchorPath", function()
    it("finds the nearest enclosing anchor", function()
        assert_eq(BookText.anchorPath("/body/DocFragment[1]/body/p[1]/a[2]/sup[1]/text().3"),
            "/body/DocFragment[1]/body/p[1]/a[2]")
        assert_eq(BookText.anchorPath("/body/DocFragment[1]/body/p[1]/a[1]/text().0"),
            "/body/DocFragment[1]/body/p[1]/a[1]")
    end)

    it("is nil outside anchors", function()
        assert_nil(BookText.anchorPath("/body/DocFragment[1]/body/p[1]/text().0"))
        assert_nil(BookText.anchorPath(nil))
    end)
end)

describe("BookText.cleanCitationGaps", function()
    it("removes empty brackets and spaces left by a removed label", function()
        assert_eq(BookText.cleanCitationGaps("A claim ( ) is here ."), "A claim is here.")
        assert_eq(BookText.cleanCitationGaps("A claim [] is here."), "A claim is here.")
    end)

    it("removes a separator that only separated the citation", function()
        assert_eq(BookText.cleanCitationGaps(", Next point."), "Next point.")
    end)
end)

-- A fake crengine document: xpointers encode character offsets, and one or
-- more character ranges are inside anchors (or other inline elements).
local function fake_document(text, spans, opts)
    spans = spans or {}
    opts = opts or {}
    local base = "/body/DocFragment[1]/body/p[1]"

    local function offset(xp)
        return xp and tonumber(xp:match("%.(%d+)$"))
    end

    local function span_at(pos)
        for i, span in ipairs(spans) do
            if pos >= span.from and pos < span.to then return i, span end
        end
    end

    local function xp_at(pos)
        local i = span_at(pos)
        local path = i and (base .. "/a[" .. i .. "]") or base
        return path .. "/text()." .. pos
    end

    local doc = {}

    function doc:xp_at(pos) return xp_at(pos) end

    function doc:getTextFromXPointers(a, b)
        local x, y = offset(a), offset(b)
        if not x or not y then return "" end
        if x == y then
            -- crengine can report a character for a zero-width range at an
            -- element boundary.
            if opts.quirk_equal_range then return text:sub(x + 1, x + 1) end
            return ""
        end
        if y < x then return "" end
        return text:sub(x + 1, y)
    end

    function doc:getPrevVisibleChar(xp)
        local p = offset(xp)
        if p and p > 0 then return xp_at(p - 1) end
    end

    function doc:getNextVisibleChar(xp)
        local p = offset(xp)
        if p and p < #text then return xp_at(p + 1) end
    end

    function doc:getNextVisibleWordEnd(xp)
        local p = offset(xp)
        if not p then return nil end
        local s = text:find("[%w]", p + 1)
        if not s then return nil end
        local e = text:find("[^%w]", s)
        return xp_at(e and e - 1 or #text)
    end

    function doc:getNextVisibleWordStart(xp)
        local p = offset(xp)
        if not p then return nil end
        local s = text:find("[%w]", p + 1)
        if not s then return nil end
        return xp_at(s - 1)
    end

    function doc:getPrevVisibleWordStart(xp)
        local p = offset(xp)
        if not p then return nil end
        local i = p
        while i > 0 and not text:sub(i, i):match("[%w]") do i = i - 1 end
        if i == 0 then return nil end
        while i > 1 and text:sub(i - 1, i - 1):match("[%w]") do i = i - 1 end
        return xp_at(i - 1)
    end

    function doc:compareXPointers(a, b)
        local x, y = offset(a), offset(b)
        if x == y then return 0 end
        return x < y and 1 or -1
    end

    function doc:getHTMLFromXPointer(path)
        local i = tonumber(path and path:match("/a%[(%d+)%]$"))
        if not i then return nil end
        return spans[i].html
            or '<a epub:type="noteref" role="doc-noteref"><sup>' .. i .. "</sup></a>"
    end

    function doc:getXPointer() return xp_at(0) end

    return doc
end

local function span_of(text, label)
    local s = assert(text:find(label, 1, true))
    return s - 1, s - 1 + #label
end

local function span_from(text, label, init)
    local s = assert(text:find(label, init, true))
    return s - 1, s - 1 + #label
end

describe("BookText.sentenceFrom with citations", function()
    local function fixture(text, label, html)
        local from, to = span_of(text, label)
        local doc = fake_document(text, { { from = from, to = to, html = html } })
        return { doc = doc, ui = { document = doc } }
    end

    it("recognises only noteref anchors", function()
        local f = fixture("See [1] here.", "[1]")
        assert_true(BookText.isCitationAnchor(f.ui, f.doc:xp_at(span_of("See [1] here.", "[1]"))))
        local ordinary = fixture("See [the note] here.", "[the note]",
            '<a href="#note">the note</a>')
        assert_true(not BookText.isCitationAnchor(ordinary.ui,
            ordinary.doc:xp_at(span_of("See [the note] here.", "[the note]"))))
    end)

    it("leaves a citation label out of the spoken text, not the highlight", function()
        local f = fixture("A claim [1] is here. Next.", "[1]")
        local s = BookText.sentenceFrom(f.ui, f.doc:xp_at(0), { skip_citations = true })
        assert_eq(s.text, "A claim is here.")
        -- The highlight still covers the visible citation.
        assert_eq(f.doc:getTextFromXPointers(s.pos0, s.pos1), "A claim [1] is here.")
    end)

    it("keeps the citation when the option is off", function()
        local f = fixture("A claim [1] is here. Next.", "[1]")
        local s = BookText.sentenceFrom(f.ui, f.doc:xp_at(0))
        assert_eq(s.text, "A claim [1] is here.")
    end)

    it("removes a multi-word label without splitting the sentence", function()
        local text = "A claim [Example, passage one] is here. Next. End."
        local f = fixture(text, "[Example, passage one]")
        local s = BookText.sentenceFrom(f.ui, f.doc:xp_at(0), { skip_citations = true })
        assert_eq(s.text, "A claim is here.")
        assert_eq(BookText.nextSentence(f.ui, s, { skip_citations = true }).text, "Next.")
    end)

    it("does not end a sentence at punctuation inside a label", function()
        local f = fixture("They agreed [Ref.] Then left. Next. End.", "[Ref.]")
        local s = BookText.sentenceFrom(f.ui, f.doc:xp_at(0), { skip_citations = true })
        assert_eq(s.text, "They agreed Then left.")
        assert_eq(BookText.nextSentence(f.ui, s, { skip_citations = true }).text, "Next.")

        local plain = BookText.sentenceFrom(f.ui, f.doc:xp_at(0))
        assert_eq(plain.text, "They agreed [Ref.]", "the period still ends it when not skipping")
    end)

    it("keeps ordinary links and superscript text", function()
        local f = fixture("See [the note] here. Next.", "[the note]",
            '<a href="#note">the note</a>')
        local s = BookText.sentenceFrom(f.ui, f.doc:xp_at(0), { skip_citations = true })
        assert_eq(s.text, "See [the note] here.")

        local sup = fixture("Einstein said E = mc2. Next.", "2",
            '<a href="#fn"><sup>2</sup></a>')
        local s2 = BookText.sentenceFrom(sup.ui, sup.doc:xp_at(0), { skip_citations = true })
        assert_eq(s2.text, "Einstein said E = mc2.")
    end)

    it("is opt-in: sentenceAt (explicit selection path) keeps citations", function()
        local f = fixture("A claim [1] is here. Next.", "[1]")
        local s = BookText.sentenceAt(f.ui, f.doc:xp_at(0))
        assert_eq(s.text, "A claim [1] is here.")
    end)

    it("drops a label that starts the sentence, even when an empty range reports text", function()
        -- A paragraph of nothing but citations (the device showed this for
        -- vault-reader source lists) must speak nothing, not the label's
        -- first letter.
        local label = "Nkrumah, 1965, Introduction"
        local text = label .. " " .. label
        local a1, a2 = span_from(text, label, 1)
        local b1, b2 = span_from(text, label, a2 + 2)
        local doc = fake_document(text, {
            { from = a1, to = a2 },
            { from = b1, to = b2 },
        }, { quirk_equal_range = true })
        local s = BookText.sentenceFrom({ document = doc }, doc:xp_at(0), { skip_citations = true })
        assert_eq(s.text, "")

        local text2 = "A claim [1] is here. Next."
        local from, to = span_of(text2, "[1]")
        local doc2 = fake_document(text2, { { from = from, to = to } },
            { quirk_equal_range = true })
        local s2 = BookText.sentenceFrom({ document = doc2 }, doc2:xp_at(0), { skip_citations = true })
        assert_eq(s2.text, "A claim is here.")
    end)
end)
