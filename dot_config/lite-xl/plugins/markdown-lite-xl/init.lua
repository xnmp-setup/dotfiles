-- mod-version:3 -- lite-xl 2.0
--
-- Markdown previewer with full GFM support
--

local core = require "core"
local keymap = require "core.keymap"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local common = require "core.common"
local tokenizer = require "core.tokenizer"
local syntax = require "core.syntax"

local main = {}

local lang_to_ext = {
  lua = "_.lua", python = "_.py", py = "_.py",
  javascript = "_.js", js = "_.js", typescript = "_.ts", ts = "_.ts",
  c = "_.c", cpp = "_.cpp", ["c++"] = "_.cpp", h = "_.h",
  rust = "_.rs", rs = "_.rs", go = "_.go",
  sh = "_.sh", bash = "_.sh", zsh = "_.sh",
  json = "_.json", yaml = "_.yaml", yml = "_.yaml", toml = "_.toml",
  html = "_.html", css = "_.css", xml = "_.xml",
  java = "_.java", ruby = "_.rb", rb = "_.rb",
  sql = "_.sql", markdown = "_.md", md = "_.md",
}

local function get_syntax_for_lang(lang)
  if not lang or lang == "" then return nil end
  local fake = lang_to_ext[lang:lower()]
  if fake then return syntax.get(fake) end
  for i = #syntax.items, 1, -1 do
    if syntax.items[i].name:lower() == lang:lower() then
      return syntax.items[i]
    end
  end
  return nil
end

-- ============================================================================
-- Inline parser
-- ============================================================================

local function parse_inline(text, fonts, base_color)
  local spans = {}
  local i = 1
  local len = #text

  while i <= len do
    -- Inline code
    if text:sub(i, i) == "`" then
      local end_pos = text:find("`", i + 1, true)
      if end_pos then
        table.insert(spans, {
          text = text:sub(i + 1, end_pos - 1),
          font = fonts.code,
          color = style.syntax and style.syntax["string"] or style.accent,
          bg = style.background2,
        })
        i = end_pos + 1
        goto continue
      end
    end

    -- Bold + italic (*** or ___)
    if text:sub(i, i + 2) == "***" or text:sub(i, i + 2) == "___" then
      local marker = text:sub(i, i + 2)
      local end_pos = text:find(marker, i + 3, true)
      if end_pos then
        table.insert(spans, {
          text = text:sub(i + 3, end_pos - 1),
          font = fonts.bold_italic,
          color = base_color,
        })
        i = end_pos + 3
        goto continue
      end
    end

    -- Strikethrough
    if text:sub(i, i + 1) == "~~" then
      local end_pos = text:find("~~", i + 2, true)
      if end_pos then
        table.insert(spans, {
          text = text:sub(i + 2, end_pos - 1),
          font = fonts.strikethrough,
          color = style.dim,
        })
        i = end_pos + 2
        goto continue
      end
    end

    -- Bold (** or __)
    if text:sub(i, i + 1) == "**" or text:sub(i, i + 1) == "__" then
      local marker = text:sub(i, i + 1)
      local end_pos = text:find(marker, i + 2, true)
      if end_pos then
        table.insert(spans, {
          text = text:sub(i + 2, end_pos - 1),
          font = fonts.bold,
          color = base_color,
        })
        i = end_pos + 2
        goto continue
      end
    end

    -- Italic (* or _) — must not be followed by space
    if (text:sub(i, i) == "*" or text:sub(i, i) == "_") then
      local marker = text:sub(i, i)
      -- Avoid matching ** or __
      if text:sub(i + 1, i + 1) ~= marker then
        local end_pos = text:find(marker, i + 1, true)
        if end_pos and text:sub(i + 1, i + 1) ~= " " then
          table.insert(spans, {
            text = text:sub(i + 1, end_pos - 1),
            font = fonts.italic,
            color = base_color,
          })
          i = end_pos + 1
          goto continue
        end
      end
    end

    -- Link [text](url)
    if text:sub(i, i) == "[" then
      local bracket_end = text:find("]", i + 1, true)
      if bracket_end and text:sub(bracket_end + 1, bracket_end + 1) == "(" then
        local paren_end = text:find(")", bracket_end + 2, true)
        if paren_end then
          local link_color = style.syntax and style.syntax["keyword2"] or style.accent
          table.insert(spans, {
            text = text:sub(i + 1, bracket_end - 1),
            font = fonts.regular,
            color = link_color,
            underline = true,
          })
          i = paren_end + 1
          goto continue
        end
      end
    end

    -- Plain text — accumulate until next special character
    local next_special = len + 1
    for _, pat in ipairs({"`", "**", "__", "***", "___", "~~", "*", "_", "["}) do
      local pos = text:find(pat, i + 1, true)
      if pos and pos < next_special then
        next_special = pos
      end
    end
    table.insert(spans, {
      text = text:sub(i, next_special - 1),
      font = fonts.regular,
      color = base_color,
    })
    i = next_special

    ::continue::
  end

  return spans
end

-- ============================================================================
-- Block parser
-- ============================================================================

local function parse_blocks(text)
  local blocks = {}
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end

  local i = 1
  local n = #lines

  while i <= n do
    local line = lines[i]

    -- Fenced code block
    if line:match("^```") then
      local lang = line:match("^```(%w*)")
      local code_lines = {}
      i = i + 1
      while i <= n and not lines[i]:match("^```") do
        table.insert(code_lines, lines[i])
        i = i + 1
      end
      table.insert(blocks, { type = "code_block", lines = code_lines, lang = lang or "" })
      i = i + 1
      goto next_block
    end

    -- Horizontal rule
    if line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") or line:match("^%s*___+%s*$") then
      table.insert(blocks, { type = "hr" })
      i = i + 1
      goto next_block
    end

    -- Heading
    local h_level, h_text = line:match("^(#+)%s(.*)$")
    if h_level then
      table.insert(blocks, { type = "heading", level = #h_level, text = h_text or "" })
      i = i + 1
      goto next_block
    end

    -- Table (line contains | and next line is separator)
    if line:match("|") and i + 1 <= n and lines[i + 1]:match("^[|%s%-:]+$") then
      local header = line
      local separator = lines[i + 1]
      local rows = { header }
      -- Parse alignment from separator
      local aligns = {}
      for cell in separator:gmatch("[^|]+") do
        cell = cell:match("^%s*(.-)%s*$")
        if cell:match("^:.*:$") then
          table.insert(aligns, "center")
        elseif cell:match(":$") then
          table.insert(aligns, "right")
        else
          table.insert(aligns, "left")
        end
      end
      i = i + 2
      while i <= n and lines[i]:match("|") do
        table.insert(rows, lines[i])
        i = i + 1
      end
      -- Parse cells
      local parsed_rows = {}
      for _, row in ipairs(rows) do
        local cells = {}
        -- Strip leading/trailing pipes
        local inner = row:match("^%s*|?(.-)%|?%s*$")
        for cell in inner:gmatch("[^|]+") do
          table.insert(cells, cell:match("^%s*(.-)%s*$"))
        end
        table.insert(parsed_rows, cells)
      end
      table.insert(blocks, { type = "table", rows = parsed_rows, aligns = aligns })
      goto next_block
    end

    -- Blockquote
    if line:match("^>") then
      local bq_lines = {}
      while i <= n and lines[i]:match("^>") do
        table.insert(bq_lines, lines[i]:match("^>%s?(.*)$") or "")
        i = i + 1
      end
      table.insert(blocks, { type = "blockquote", text = table.concat(bq_lines, "\n") })
      goto next_block
    end

    -- Unordered list
    if line:match("^%s*[%-%*%+]%s+") then
      local items = {}
      while i <= n and lines[i]:match("^%s*[%-%*%+]%s+") do
        local indent, item_text = lines[i]:match("^(%s*)[%-%*%+]%s+(.*)$")
        table.insert(items, { text = item_text, indent = #indent })
        i = i + 1
      end
      table.insert(blocks, { type = "ul", items = items })
      goto next_block
    end

    -- Ordered list
    if line:match("^%s*%d+[%.%)]%s+") then
      local items = {}
      while i <= n and lines[i]:match("^%s*%d+[%.%)]%s+") do
        local indent, num, item_text = lines[i]:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
        table.insert(items, { text = item_text, indent = #indent, num = tonumber(num) })
        i = i + 1
      end
      table.insert(blocks, { type = "ol", items = items })
      goto next_block
    end

    -- Empty line
    if line:match("^%s*$") then
      table.insert(blocks, { type = "empty" })
      i = i + 1
      goto next_block
    end

    -- Paragraph (collect consecutive non-empty, non-special lines)
    local para_lines = {}
    while i <= n do
      local l = lines[i]
      if l:match("^%s*$") or l:match("^```") or l:match("^#+%s") or l:match("^>")
         or l:match("^%s*[%-%*%+]%s+") or l:match("^%s*%d+[%.%)]%s+")
         or l:match("^%s*%-%-%-+%s*$") or l:match("^%s*%*%*%*+%s*$") or l:match("^%s*___+%s*$")
         or (l:match("|") and i + 1 <= n and lines[i + 1] and lines[i + 1]:match("^[|%s%-:]+$")) then
        break
      end
      table.insert(para_lines, l)
      i = i + 1
    end
    if #para_lines > 0 then
      table.insert(blocks, { type = "paragraph", text = table.concat(para_lines, " ") })
    else
      i = i + 1
    end

    ::next_block::
  end

  return blocks
end

-- ============================================================================
-- MarkdownView
-- ============================================================================

local MarkdownView = View:extend()

function MarkdownView:new()
  MarkdownView.super.new(self)
  self.initial_active_view = core.active_view
  self.text_content = ""
  self.blocks = {}
  self.scrollable = true
  self.scrollable_size = 0
  self.segments = {}
  self.sel_start = nil
  self.sel_end = nil
  self.mouse_selecting = false

  local size = style.code_font:get_size()
  local home = os.getenv("HOME")
  local inter = home .. "/Library/Fonts/Inter-"
  local code_path = style.code_font:get_path()
  if type(code_path) == "table" then code_path = code_path[1] end

  self.fonts = {
    regular = renderer.font.load(inter .. "Regular.otf", size),
    bold = renderer.font.load(inter .. "Bold.otf", size),
    italic = renderer.font.load(inter .. "Italic.otf", size),
    bold_italic = renderer.font.load(inter .. "BoldItalic.otf", size),
    strikethrough = renderer.font.load(inter .. "Regular.otf", size, { strikethrough = true }),
    code = renderer.font.load(code_path, size * 0.9),
    h = {},
    h_inline = {},
  }
  local h_scales = { 1.8, 1.5, 1.25, 1.1, 1.0, 0.9 }
  for i, s in ipairs(h_scales) do
    local h_size = size * s
    self.fonts.h[i] = renderer.font.load(inter .. "Bold.otf", h_size)
    self.fonts.h_inline[i] = {
      regular = self.fonts.h[i],
      bold = self.fonts.h[i],
      italic = renderer.font.load(inter .. "BoldItalic.otf", h_size),
      bold_italic = renderer.font.load(inter .. "BoldItalic.otf", h_size),
      strikethrough = renderer.font.load(inter .. "Bold.otf", h_size, { strikethrough = true }),
      code = renderer.font.load(code_path, h_size * 0.85),
    }
  end
end

function MarkdownView:get_name()
  local v = self.initial_active_view or core.active_view
  return "Preview " .. (v.doc and (v.doc.abs_name or v.doc:get_name()) or "untitled")
end

function MarkdownView:try_close(...)
  MarkdownView.super.try_close(self, ...)
  main.view = nil
end

function MarkdownView:get_scrollable_size()
  return self.scrollable_size
end

function MarkdownView:scroll_by(delta)
  self.scroll.to.y = self.scroll.to.y + delta
  self.scroll.to.y = math.max(0, math.min(self.scroll.to.y, self:get_scrollable_size() - self.size.y))
end

function MarkdownView:scroll_to_pos(pos)
  self.scroll.to.y = pos
  self.scroll.to.y = math.max(0, math.min(self.scroll.to.y, self:get_scrollable_size() - self.size.y))
end

function MarkdownView:update(...)
  local view = self.initial_active_view
  if view and view.doc then
    local ok, new_content = pcall(view.doc.get_text, view.doc, 1, 1, math.huge, math.huge)
    if ok and new_content and self.text_content ~= new_content then
      self.blocks = parse_blocks(new_content)
      self.text_content = new_content
      self.sel_start = nil
      self.sel_end = nil
      self.block_height_cache = {}
    end
  end
  MarkdownView.super.update(self, ...)
end

function MarkdownView:draw_text_seg(font, text, x, y, color, line_height)
  local w = font:get_width(text)
  table.insert(self.segments, { x = x, y = y, w = w, h = line_height, text = text })
  return renderer.draw_text(font, text, x, y, color)
end

function MarkdownView:resolve_segment(px, py)
  local best = nil
  local best_dist = math.huge
  for i, seg in ipairs(self.segments) do
    if py >= seg.y and py < seg.y + seg.h then
      if px >= seg.x and px < seg.x + seg.w then
        return i
      end
      local dist = math.min(math.abs(px - seg.x), math.abs(px - (seg.x + seg.w)))
      if dist < best_dist then
        best_dist = dist
        best = i
      end
    end
  end
  if best then return best end
  -- Find closest segment by y
  for i, seg in ipairs(self.segments) do
    local dy = math.abs(py - (seg.y + seg.h * 0.5))
    if dy < best_dist then
      best_dist = dy
      best = i
    end
  end
  return best
end

function MarkdownView:on_mouse_pressed(button, x, y, clicks)
  if MarkdownView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  if button == "left" then
    local idx = self:resolve_segment(x, y)
    if idx then
      self.sel_start = idx
      self.sel_end = idx
      self.mouse_selecting = true
    end
    return true
  end
end

function MarkdownView:on_mouse_moved(x, y, dx, dy)
  MarkdownView.super.on_mouse_moved(self, x, y, dx, dy)
  if self.mouse_selecting then
    local idx = self:resolve_segment(x, y)
    if idx then
      self.sel_end = idx
    end
  end
end

function MarkdownView:on_mouse_released(button, x, y)
  MarkdownView.super.on_mouse_released(self, button, x, y)
  self.mouse_selecting = false
end

function MarkdownView:get_selection_text()
  if not self.sel_start or not self.sel_end then return nil end
  local s = math.min(self.sel_start, self.sel_end)
  local e = math.max(self.sel_start, self.sel_end)
  local parts = {}
  local prev_y = nil
  for i = s, e do
    local seg = self.segments[i]
    if seg then
      if prev_y and seg.y > prev_y + seg.h * 0.5 then
        table.insert(parts, "\n")
      end
      local text = seg.text
      if i == s then text = text:gsub("^%s+", "") end
      table.insert(parts, text)
      prev_y = seg.y
    end
  end
  return table.concat(parts)
end

-- Draw inline spans with word-wrapping
function MarkdownView:draw_spans(spans, x, y, max_width)
  local cx = x
  local start_x = x

  -- Use the tallest font in the spans for line height, with 1.3x spacing
  local line_height = self.fonts.regular:get_height()
  for _, span in ipairs(spans) do
    local h = span.font:get_height()
    if h > line_height then line_height = h end
  end
  line_height = line_height * 1.3

  for _, span in ipairs(spans) do
    local font = span.font
    local color = span.color
    local words = {}
    for word in span.text:gmatch("%S+") do
      table.insert(words, word)
    end
    if #words == 0 and #span.text > 0 then
      table.insert(words, span.text)
    end

    for wi, word in ipairs(words) do
      local space = (cx > start_x) and " " or ""
      local draw_text = space .. word
      local tw = font:get_width(draw_text)

      if cx + tw > start_x + max_width and cx > start_x then
        cx = start_x
        y = y + line_height
        draw_text = word
        tw = font:get_width(draw_text)
      end

      if span.bg then
        local pad = 2 * SCALE
        renderer.draw_rect(cx, y, tw + pad * 2, line_height, span.bg)
        cx = cx + pad
      end

      self:draw_text_seg(font, draw_text, cx, y, color, line_height)

      if span.underline then
        local uh = math.max(1, SCALE)
        renderer.draw_rect(cx, y + font:get_height() - uh, tw, uh, color)
      end

      cx = cx + tw
      if span.bg then
        cx = cx + 2 * SCALE
      end
    end
  end

  return y + line_height
end


function MarkdownView:draw()
  self:draw_background(style.background)
  self.segments = {}

  local ox, oy = self:get_content_offset()
  local padding_x = style.padding.x
  local padding_y = style.padding.y
  local x = ox + padding_x
  local y = oy + padding_y
  local max_width = self.size.x - padding_x * 2
  local line_height = self.fonts.regular:get_height()

  local view_top = self.scroll.y
  local cache = self.block_height_cache or {}

  local y_before = y
  for bi, block in ipairs(self.blocks) do
    local block_y_rel = y - oy
    local cached_h = cache[bi]
    if cached_h and block_y_rel + cached_h < view_top then
      y = y + cached_h
      goto draw_next
    end
    y_before = y

    -- Empty line
    if block.type == "empty" then
      y = y + line_height * 0.7

    -- Heading
    elseif block.type == "heading" then
      local level = math.min(block.level, 6)
      y = y + padding_y * 1.2
      local spans = parse_inline(block.text, self.fonts.h_inline[level], style.syntax["keyword"])
      y = self:draw_spans(spans, x, y, max_width)
      if level <= 2 then
        local uh = math.max(1, SCALE)
        y = y + padding_y * 0.3
        renderer.draw_rect(x, y, max_width, uh, style.divider)
        y = y + uh + padding_y * 0.5
      end
      y = y + padding_y * 0.5

    -- Paragraph
    elseif block.type == "paragraph" then
      local spans = parse_inline(block.text, self.fonts, style.text)
      y = self:draw_spans(spans, x, y, max_width)
      y = y + line_height * 0.5

    -- Code block
    elseif block.type == "code_block" then
      local code_font = self.fonts.code
      local code_line_h = code_font:get_height() * 1.3
      local code_height = #block.lines * code_line_h + padding_y * 1.5
      local bg_x = x - padding_x * 0.5
      local bg_w = max_width + padding_x
      renderer.draw_rect(bg_x, y, bg_w, code_height, style.background2)
      -- Border
      local bw = math.max(1, SCALE)
      renderer.draw_rect(bg_x, y, bw, code_height, style.divider)
      renderer.draw_rect(bg_x + bg_w - bw, y, bw, code_height, style.divider)
      renderer.draw_rect(bg_x, y, bg_w, bw, style.divider)
      renderer.draw_rect(bg_x, y + code_height - bw, bg_w, bw, style.divider)
      y = y + padding_y * 0.75

      local syn = get_syntax_for_lang(block.lang)
      if syn then
        local state = string.char(0)
        for _, code_line in ipairs(block.lines) do
          local tokens, new_state = tokenizer.tokenize(syn, code_line .. "\n", state)
          state = new_state
          local tx = x + padding_x * 0.5
          for _, type, text in tokenizer.each_token(tokens) do
            text = text:gsub("\n$", "")
            if #text > 0 then
              local color = style.syntax[type] or style.syntax["normal"] or style.text
              tx = self:draw_text_seg(code_font, text, tx, y, color, code_line_h)
            end
          end
          y = y + code_line_h
        end
      else
        local code_color = style.syntax and style.syntax["normal"] or style.text
        for _, code_line in ipairs(block.lines) do
          self:draw_text_seg(code_font, code_line, x + padding_x * 0.5, y, code_color, code_line_h)
          y = y + code_line_h
        end
      end
      y = y + padding_y * 0.75

    -- Horizontal rule
    elseif block.type == "hr" then
      y = y + line_height * 0.5
      local uh = math.max(2, 2 * SCALE)
      local hr_color = style.syntax and style.syntax["comment"] or style.divider
      renderer.draw_rect(x, y, max_width, uh, hr_color)
      y = y + uh + line_height * 0.5

    -- Blockquote
    elseif block.type == "blockquote" then
      local bar_w = math.max(3, 3 * SCALE)
      local indent = bar_w + padding_x * 0.75
      local bq_color = style.syntax and style.syntax["comment"] or style.dim
      local bq_fonts = {
        regular = self.fonts.italic,
        bold = self.fonts.bold_italic,
        italic = self.fonts.italic,
        bold_italic = self.fonts.bold_italic,
        strikethrough = self.fonts.strikethrough,
        code = self.fonts.code,
      }
      local bq_spans = parse_inline(block.text, bq_fonts, bq_color)
      local bq_start_y = y
      y = self:draw_spans(bq_spans, x + indent, y, max_width - indent)
      local bar_color = style.syntax and style.syntax["string"] or style.accent
      renderer.draw_rect(x, bq_start_y, bar_w, y - bq_start_y, bar_color)
      y = y + line_height * 0.5

    -- Unordered list
    elseif block.type == "ul" then
      local bullets = { "\u{2022}", "\u{25E6}", "\u{2023}" }
      local bullet_color = style.syntax and style.syntax["keyword"] or style.accent
      for _, item in ipairs(block.items) do
        local level = math.floor(item.indent / 2)
        local indent = padding_x + level * padding_x * 1.5
        local bullet = bullets[(level % #bullets) + 1]
        self:draw_text_seg(self.fonts.regular, bullet, x + indent - padding_x, y, bullet_color, line_height)
        local spans = parse_inline(item.text, self.fonts, style.text)
        y = self:draw_spans(spans, x + indent, y, max_width - indent)
      end
      y = y + line_height * 0.2

    -- Ordered list
    elseif block.type == "ol" then
      local num_color = style.syntax and style.syntax["number"] or style.accent
      for _, item in ipairs(block.items) do
        local level = math.floor(item.indent / 2)
        local indent = padding_x + level * padding_x * 1.5
        local num_text = tostring(item.num) .. "."
        self:draw_text_seg(self.fonts.regular, num_text, x + indent - padding_x, y, num_color, line_height)
        local spans = parse_inline(item.text, self.fonts, style.text)
        y = self:draw_spans(spans, x + indent, y, max_width - indent)
      end
      y = y + line_height * 0.2

    -- Table
    elseif block.type == "table" then
      local rows = block.rows
      local aligns = block.aligns
      if #rows == 0 then goto draw_next end

      local num_cols = 0
      for _, row in ipairs(rows) do
        num_cols = math.max(num_cols, #row)
      end
      if num_cols == 0 then goto draw_next end

      local border_w = math.max(1, SCALE)
      local cell_pad = padding_x * 0.75
      local table_x = x

      -- Calculate natural column widths
      local col_widths = {}
      local total_natural = 0
      for c = 1, num_cols do
        col_widths[c] = 0
        for _, row in ipairs(rows) do
          if row[c] then
            local w = self.fonts.bold:get_width(row[c])
            col_widths[c] = math.max(col_widths[c], w)
          end
        end
        col_widths[c] = col_widths[c] + cell_pad * 2
        total_natural = total_natural + col_widths[c]
      end

      -- Constrain columns to available width:
      -- Short columns keep natural width, wide columns share remaining space
      local available = max_width - border_w * (num_cols + 1)
      if total_natural > available then
        local avg = available / num_cols
        local small_total = 0
        local large_cols = {}
        for c = 1, num_cols do
          if col_widths[c] <= avg then
            small_total = small_total + col_widths[c]
          else
            table.insert(large_cols, c)
          end
        end
        local remaining = available - small_total
        local large_share = #large_cols > 0 and (remaining / #large_cols) or avg
        for _, c in ipairs(large_cols) do
          col_widths[c] = math.max(large_share, cell_pad * 4)
        end
      end

      -- Measure height of a cell with inline formatting and wrapping
      local cell_line_height = line_height * 1.3
      local function measure_cell_height(text, fonts_set, cell_width)
        local spans = parse_inline(text, fonts_set, style.text)
        local cx = 0
        local lines_count = 1
        for _, span in ipairs(spans) do
          local words = {}
          for word in span.text:gmatch("%S+") do
            table.insert(words, word)
          end
          if #words == 0 and #span.text > 0 then
            table.insert(words, span.text)
          end
          for _, word in ipairs(words) do
            local space = (cx > 0) and " " or ""
            local tw = span.font:get_width(space .. word)
            if cx + tw > cell_width and cx > 0 then
              cx = 0
              lines_count = lines_count + 1
            end
            local actual = (cx > 0) and tw or span.font:get_width(word)
            cx = cx + actual
          end
        end
        return lines_count * cell_line_height + padding_y
      end

      -- Calculate row heights
      local row_heights = {}
      for ri, row in ipairs(rows) do
        local is_header = (ri == 1)
        local cell_fonts = {
          regular = is_header and self.fonts.bold or self.fonts.regular,
          bold = self.fonts.bold,
          italic = self.fonts.italic,
          bold_italic = self.fonts.bold_italic,
          strikethrough = self.fonts.strikethrough,
          code = self.fonts.code,
        }
        local max_h = cell_line_height + padding_y
        for c = 1, num_cols do
          local cell_text = row[c] or ""
          local inner_w = col_widths[c] - cell_pad * 2
          local h = measure_cell_height(cell_text, cell_fonts, inner_w)
          if h > max_h then max_h = h end
        end
        row_heights[ri] = max_h
      end

      -- Draw table
      for ri, row in ipairs(rows) do
        local cell_x = table_x
        local is_header = (ri == 1)
        local cell_h = row_heights[ri]
        local cell_fonts = {
          regular = is_header and self.fonts.bold or self.fonts.regular,
          bold = self.fonts.bold,
          italic = self.fonts.italic,
          bold_italic = self.fonts.bold_italic,
          strikethrough = self.fonts.strikethrough,
          code = self.fonts.code,
        }

        -- Row background for header
        if is_header then
          local total_w = 0
          for c = 1, num_cols do total_w = total_w + col_widths[c] end
          renderer.draw_rect(cell_x, y, total_w + border_w * (num_cols + 1), cell_h, style.background2)
        end

        for c = 1, num_cols do
          local cw = col_widths[c]
          local cell_text = row[c] or ""

          -- Cell borders
          renderer.draw_rect(cell_x, y, border_w, cell_h, style.divider)
          renderer.draw_rect(cell_x, y, cw + border_w, border_w, style.divider)

          -- Draw cell content with inline formatting
          local inner_w = cw - cell_pad * 2
          local text_x = cell_x + border_w + cell_pad
          local text_y = y + padding_y * 0.5
          self:draw_spans(
            parse_inline(cell_text, cell_fonts, style.text),
            text_x, text_y, inner_w
          )

          -- Right border of last column
          if c == num_cols then
            renderer.draw_rect(cell_x + cw + border_w, y, border_w, cell_h, style.divider)
          end

          cell_x = cell_x + cw + border_w
        end

        -- Bottom border of row
        local total_w = cell_x - table_x
        renderer.draw_rect(table_x, y + cell_h, total_w, border_w, style.divider)

        y = y + cell_h
      end
      y = y + border_w + padding_y
    end

    cache[bi] = y - y_before
    ::draw_next::
  end
  self.block_height_cache = cache

  self.scrollable_size = y - oy

  -- Draw selection highlights
  if self.sel_start and self.sel_end then
    local s = math.min(self.sel_start, self.sel_end)
    local e = math.max(self.sel_start, self.sel_end)
    for i = s, e do
      local seg = self.segments[i]
      if seg then
        renderer.draw_rect(seg.x, seg.y, seg.w, seg.h, style.selection)
      end
    end
  end

  self:draw_scrollbar()
end

-- ============================================================================
-- Plugin entry
-- ============================================================================

function main.start_markdown()
  main.view = MarkdownView()
  local node = core.root_view:get_active_node()
  node:add_view(main.view)
end

command.add(nil, {
  ["markdown:show"] = function()
    if main.view == nil then
      main.start_markdown()
    else
      core.log("Markdown preview already open")
    end
  end,
  ["markdown:close"] = function()
    if main.view then
      main.view:try_close()
    end
  end,
})

local function is_markdown_view()
  return core.active_view:is(MarkdownView)
end

command.add(is_markdown_view, {
  ["markdown:scroll-up"] = function()
    local lh = core.active_view.fonts.regular:get_height() * 1.3
    core.active_view:scroll_by(-lh * 3)
  end,
  ["markdown:scroll-down"] = function()
    local lh = core.active_view.fonts.regular:get_height() * 1.3
    core.active_view:scroll_by(lh * 3)
  end,
  ["markdown:page-up"] = function()
    local lh = core.active_view.fonts.regular:get_height() * 1.3
    core.active_view:scroll_by(-lh * 15)
  end,
  ["markdown:page-down"] = function()
    local lh = core.active_view.fonts.regular:get_height() * 1.3
    core.active_view:scroll_by(lh * 15)
  end,
  ["markdown:scroll-to-top"] = function()
    core.active_view:scroll_to_pos(0)
  end,
  ["markdown:scroll-to-bottom"] = function()
    core.active_view:scroll_to_pos(core.active_view:get_scrollable_size())
  end,
  ["markdown:copy"] = function()
    local text = core.active_view:get_selection_text()
    if text then
      system.set_clipboard(text)
    end
  end,
  ["markdown:select-all"] = function()
    local view = core.active_view
    if #view.segments > 0 then
      view.sel_start = 1
      view.sel_end = #view.segments
    end
  end,
})

keymap.add {
  ["alt+shift+m"] = "markdown:show",
  ["up"] = "markdown:scroll-up",
  ["down"] = "markdown:scroll-down",
  ["pageup"] = "markdown:page-up",
  ["pagedown"] = "markdown:page-down",
  ["ctrl+c"] = "markdown:copy",
  ["ctrl+a"] = "markdown:select-all",
  ["ctrl+up"] = "markdown:scroll-to-top",
  ["ctrl+down"] = "markdown:scroll-to-bottom",
}

return main
