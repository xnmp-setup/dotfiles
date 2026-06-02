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

local main = {}

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
    local h_level, h_text = line:match("^(#+)%s+(.+)$")
    if h_level then
      table.insert(blocks, { type = "heading", level = #h_level, text = h_text })
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
  self.target_size = 500 * SCALE
  self.initial_active_view = core.active_view
  self.text_content = ""
  self.blocks = {}
  self.scrollable = true
  self.scrollable_size = 0

  local size = style.code_font:get_size()
  local font_path = style.code_font:get_path()
  if type(font_path) == "table" then font_path = font_path[1] end

  self.fonts = {
    regular = renderer.font.load(font_path, size),
    bold = renderer.font.load(font_path, size, { bold = true }),
    italic = renderer.font.load(font_path, size, { italic = true }),
    bold_italic = renderer.font.load(font_path, size, { bold = true, italic = true }),
    strikethrough = renderer.font.load(font_path, size, { strikethrough = true }),
    code = renderer.font.load(font_path, size),
    h = {}
  }
  local h_scales = { 1.8, 1.5, 1.25, 1.1, 1.0, 0.9 }
  for i, s in ipairs(h_scales) do
    self.fonts.h[i] = renderer.font.load(font_path, size * s, { bold = true })
  end
end

function MarkdownView:get_name()
  local v = self.initial_active_view or core.active_view
  return "Preview " .. (v.doc and (v.doc.abs_name or v.doc:get_name()) or "untitled")
end

function MarkdownView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function MarkdownView:try_close(...)
  MarkdownView.super.try_close(self, ...)
  main.view = nil
end

function MarkdownView:get_scrollable_size()
  return self.scrollable_size + self.size.y
end

function MarkdownView:update(...)
  local new_content = self.initial_active_view.doc:get_text(1, 1, math.huge, math.huge)
  if self.text_content ~= new_content then
    self.blocks = parse_blocks(new_content)
    self.text_content = new_content
  end
  MarkdownView.super.update(self, ...)
end

-- Draw inline spans with word-wrapping
function MarkdownView:draw_spans(spans, x, y, max_width)
  local cx = x
  local start_x = x

  -- Use the tallest font in the spans for line height
  local line_height = self.fonts.regular:get_height()
  for _, span in ipairs(spans) do
    local h = span.font:get_height()
    if h > line_height then line_height = h end
  end

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

      renderer.draw_text(font, draw_text, cx, y, color)

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

  local ox, oy = self:get_content_offset()
  local padding_x = style.padding.x
  local padding_y = style.padding.y
  local x = ox + padding_x
  local y = oy + padding_y
  local max_width = self.size.x - padding_x * 2
  local line_height = self.fonts.regular:get_height()

  for _, block in ipairs(self.blocks) do

    -- Empty line
    if block.type == "empty" then
      y = y + line_height * 0.5

    -- Heading
    elseif block.type == "heading" then
      local level = math.min(block.level, 6)
      local font = self.fonts.h[level]
      y = y + padding_y
      local h_size = font:get_size()
      local font_path = style.code_font:get_path()
      if type(font_path) == "table" then font_path = font_path[1] end
      local spans = parse_inline(block.text, {
        regular = font,
        bold = font,
        italic = renderer.font.load(font_path, h_size, { bold = true, italic = true }),
        bold_italic = renderer.font.load(font_path, h_size, { bold = true, italic = true }),
        strikethrough = renderer.font.load(font_path, h_size, { strikethrough = true }),
        code = renderer.font.load(font_path, h_size * 0.85),
      }, style.syntax["keyword"])
      y = self:draw_spans(spans, x, y, max_width)
      -- Underline for H1 and H2
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
      y = y + line_height * 0.3

    -- Code block
    elseif block.type == "code_block" then
      local code_font = self.fonts.code
      local code_height = #block.lines * code_font:get_height() + padding_y
      local bg_x = x - padding_x * 0.5
      local bg_w = max_width + padding_x
      renderer.draw_rect(bg_x, y, bg_w, code_height, style.background2)
      -- Border
      local bw = math.max(1, SCALE)
      renderer.draw_rect(bg_x, y, bw, code_height, style.divider)
      renderer.draw_rect(bg_x + bg_w - bw, y, bw, code_height, style.divider)
      renderer.draw_rect(bg_x, y, bg_w, bw, style.divider)
      renderer.draw_rect(bg_x, y + code_height - bw, bg_w, bw, style.divider)
      y = y + padding_y * 0.5
      local code_color = style.syntax and style.syntax["string"] or style.text
      for _, code_line in ipairs(block.lines) do
        renderer.draw_text(code_font, code_line, x + padding_x * 0.5, y, code_color)
        y = y + code_font:get_height()
      end
      y = y + padding_y * 0.5

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
      y = y + line_height * 0.3

    -- Unordered list
    elseif block.type == "ul" then
      local bullets = { "\u{2022}", "\u{25E6}", "\u{2023}" }
      local bullet_color = style.syntax and style.syntax["keyword"] or style.accent
      for _, item in ipairs(block.items) do
        local level = math.floor(item.indent / 2)
        local indent = padding_x + level * padding_x * 1.5
        local bullet = bullets[(level % #bullets) + 1]
        renderer.draw_text(self.fonts.regular, bullet, x + indent - padding_x, y, bullet_color)
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
        renderer.draw_text(self.fonts.regular, num_text, x + indent - padding_x, y, num_color)
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

      -- Helper: wrap text into lines that fit a given width
      local function wrap_text(text, font, wrap_width)
        local wrapped = {}
        local words = {}
        for word in text:gmatch("%S+") do
          table.insert(words, word)
        end
        if #words == 0 then return { "" } end

        local current_line = words[1]
        for i = 2, #words do
          local test = current_line .. " " .. words[i]
          if font:get_width(test) <= wrap_width then
            current_line = test
          else
            table.insert(wrapped, current_line)
            current_line = words[i]
          end
        end
        table.insert(wrapped, current_line)
        return wrapped
      end

      -- Calculate row heights with wrapping
      local row_heights = {}
      local row_wrapped = {}
      for ri, row in ipairs(rows) do
        local is_header = (ri == 1)
        local row_font = is_header and self.fonts.bold or self.fonts.regular
        local max_lines = 1
        row_wrapped[ri] = {}
        for c = 1, num_cols do
          local cell_text = row[c] or ""
          local wrap_width = col_widths[c] - cell_pad * 2
          local lines = wrap_text(cell_text, row_font, wrap_width)
          row_wrapped[ri][c] = lines
          if #lines > max_lines then max_lines = #lines end
        end
        row_heights[ri] = max_lines * line_height + padding_y
      end

      -- Draw table
      for ri, row in ipairs(rows) do
        local cell_x = table_x
        local is_header = (ri == 1)
        local row_font = is_header and self.fonts.bold or self.fonts.regular
        local cell_h = row_heights[ri]

        -- Row background for header
        if is_header then
          local total_w = 0
          for c = 1, num_cols do total_w = total_w + col_widths[c] end
          renderer.draw_rect(cell_x, y, total_w + border_w * (num_cols + 1), cell_h, style.background2)
        end

        for c = 1, num_cols do
          local cw = col_widths[c]
          local wrapped_lines = row_wrapped[ri][c]

          -- Cell borders
          renderer.draw_rect(cell_x, y, border_w, cell_h, style.divider)
          renderer.draw_rect(cell_x, y, cw + border_w, border_w, style.divider)

          -- Draw wrapped text lines
          local text_y = y + padding_y * 0.5
          for _, line_text in ipairs(wrapped_lines) do
            local text_w = row_font:get_width(line_text)
            local text_x = cell_x + border_w + cell_pad
            local align = aligns[c] or "left"
            local inner_w = cw - cell_pad * 2
            if align == "center" then
              text_x = cell_x + border_w + (cw - text_w) / 2
            elseif align == "right" then
              text_x = cell_x + border_w + cw - text_w - cell_pad
            end
            renderer.draw_text(row_font, line_text, text_x, text_y, style.text)
            text_y = text_y + line_height
          end

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

    ::draw_next::
  end

  self.scrollable_size = y - oy
  self:draw_scrollbar()
end

-- ============================================================================
-- Plugin entry
-- ============================================================================

function main.start_markdown()
  main.view = MarkdownView()
  local node = core.root_view:get_active_node()
  node:split("right")
  node = core.root_view:get_active_node_default()
  node:add_view(main.view)
  core.root_view.root_node:update_layout()

  local treeview_loaded, treeview = core.try(require, "plugins.treeview")
  local treeview_target_size = treeview_loaded and treeview.target_size or 0

  function main.view:update(...)
    local dest = (self.target_size or 0) + treeview_target_size
    self:move_towards(self.size, "x", dest)
    MarkdownView.update(self, ...)
  end
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

keymap.add {
  ["alt+shift+m"] = "markdown:show",
}

return main
