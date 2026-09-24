# frozen_string_literal: true

require "tempfile"
require "zaniah/vector"
require "okab/zaniah_vector"

module Rukbat
  module PDFFile
    PAGE_WIDTH = 842
    PAGE_HEIGHT = 595
    ROWS_PER_PAGE = 28
    COLUMNS_PER_PAGE = 8
    MAX_CELLS = 100_000
    CELL_WIDTH = 94
    CELL_HEIGHT = 17
    MARGIN = 20

    module_function

    def render(workbook, font:, sheet: workbook.active_sheet, font_db: nil)
      font = normalize_font(font)
      font_cache = {}
      current = workbook.sheet(sheet)
      area = workbook.print_area(sheet: sheet)
      origin_row, origin_column = area ? [area.top - 1, area.left - 1] : [0, 0]
      rows = area ? area.bottom - area.top + 1 : [current.row_count, 1].max
      columns = area ? area.right - area.left + 1 : [current.column_count, 1].max
      raise Error, "PDF export exceeds #{MAX_CELLS} cells" if rows * columns > MAX_CELLS

      renderer = Zaniah::TextSystem::Renderer.new(font: font.face)
      document = Okab::Document.new(title: "#{sheet} — Rukbat", author: "Yudai Takada", creator: "Rukbat")
      (0...rows).step(ROWS_PER_PAGE) do |row_offset|
        (0...columns).step(COLUMNS_PER_PAGE) do |column_offset|
          render_page(document, workbook, font, renderer, font_db, font_cache, sheet, origin_row, origin_column, row_offset, column_offset,
            [rows - row_offset, ROWS_PER_PAGE].min, [columns - column_offset, COLUMNS_PER_PAGE].min)
        end
      end
      document.render
    ensure
      renderer&.close
    end

    def write(workbook, path, font:, sheet: workbook.active_sheet, font_db: nil)
      bytes = render(workbook, font: font, sheet: sheet, font_db: font_db)
      target = File.expand_path(path)
      stat = File.lstat(target) if File.exist?(target) || File.symlink?(target)
      raise Error, "PDF target must be a regular file" if stat && !stat.file?

      mode = stat ? stat.mode & 0o7777 : 0o666 & ~File.umask
      Tempfile.create([".rukbat-", ".pdf"], File.dirname(target), binmode: true) do |file|
        file.write(bytes)
        file.flush
        file.fsync
        file.chmod(mode)
        file.close
        AtomicFile.install(file.path, target, replace: true)
      end
      path
    rescue SystemCallError => error
      raise Error, "cannot write PDF: #{error.message}"
    end

    def render_page(document, workbook, font, renderer, font_db, font_cache, sheet, origin_row, origin_column,
      row_offset, column_offset, row_count, column_count)
      styled_text = []
      vector = Zaniah::Vector.record(width: PAGE_WIDTH, height: PAGE_HEIGHT, text_system: renderer) do
        Zaniah::Canvas.new do |_bounds, cx|
          scene = cx.scene
          first_row = origin_row + row_offset + 1
          last_row = first_row + row_count - 1
          header = "#{sheet} — rows #{first_row}-#{last_row}"
          renderer.paint_line(scene, renderer.layout_line(header, font: font.face, size: 10),
            x: MARGIN, y: MARGIN, color: "#000000")
          data_top = PAGE_HEIGHT - MARGIN - 24
          (0..row_count).each do |row_index|
            (0..column_count).each do |column_index|
              x = MARGIN + (column_index.zero? ? 0 : 38 + (column_index - 1) * CELL_WIDTH)
              width = column_index.zero? ? 38 : CELL_WIDTH
              y = data_top - row_index * CELL_HEIGHT
              text, style = cell_text(workbook, sheet, origin_row, origin_column,
                row_offset, column_offset, row_index, column_index)
              paint_cell(scene, styled_text, renderer, text, style,
                font_for_style(style, font, font_db, font_cache), x, y, width)
            end
          end
        end.w(PAGE_WIDTH).h(PAGE_HEIGHT)
      end
      document.page(width: PAGE_WIDTH, height: PAGE_HEIGHT) do |page|
        Okab::ZaniahVector.draw(page, vector)
        styled_text.each do |text, x, y, font, size, color, bold, italic|
          page.text(text, x: x, y: y, font: font, size: size, color: color, bold: bold, italic: italic)
        end
      end
    end
    private_class_method :render_page

    def cell_text(workbook, sheet, origin_row, origin_column, row_offset, column_offset, row_index, column_index)
      return ["", {}] if row_index.zero? && column_index.zero?
      return [(origin_row + row_offset + row_index).to_s, {}] if column_index.zero?
      return [Furud::Formula.column_name(origin_column + column_offset + column_index), {}] if row_index.zero?

      row = origin_row + row_offset + row_index
      column = origin_column + column_offset + column_index
      workbook.presentation_at(row, column, sheet: sheet)
    end
    private_class_method :cell_text

    def paint_cell(scene, styled_text, renderer, text, style, font, x, top, width)
      y = top - CELL_HEIGHT
      scene.quad(x, PAGE_HEIGHT - top, width, CELL_HEIGHT,
        color: style[:background] || "#0000", border_color: style[:border_color] || "#B8BEC8",
        border_width: style[:border_width] || 0.5)
      text = text.to_s.lines.first.to_s.chomp
      text = text.encode(Encoding::UTF_8)
      # ponytail: fixed-height PDF rows cap text at 13pt; variable page geometry can lift the ceiling.
      size = [[style[:font_size] || 8, 6].max, CELL_HEIGHT - 4].min
      text = fit_text(text, font, size, width - 6)
      unless text.empty?
        text_width = font.measure(text, size: size)
        text_x = case style[:horizontal_alignment]
        when :center then x + (width - text_width) / 2
        when :right then x + width - text_width - 3
        else x + 3
        end
        baseline = case style[:vertical_alignment]
        when :top then y + CELL_HEIGHT - size - 2
        when :bottom then y + 2
        else y + (CELL_HEIGHT - size) / 2
        end
        color = style[:color] || "#20242C"
        if style[:bold] || style[:italic]
          # GlyphRun has no synthetic-style fields; retain Okab's searchable
          # faux-bold/italic text operator for those cells only.
          styled_text << [text, text_x, baseline, font, size, rgb(color), !!style[:bold], !!style[:italic]]
        else
          renderer.paint_line(scene, renderer.layout_line(text, font: font.face, size: size),
            x: text_x, y: PAGE_HEIGHT - baseline, color: color)
        end
      end
    end
    private_class_method :paint_cell

    def font_for_style(style, fallback, font_db, cache)
      family = style[:font_family]
      return fallback unless family

      key = family.unicode_normalize(:nfkc).downcase(:fold).gsub(/\s+/, " ").strip
      cache[key] ||= begin
        database = font_db || Zaniah::TextSystem::FontDB.new
        face = database.faces.find do |candidate|
          candidate.families.any? { |name| name.unicode_normalize(:nfkc).downcase(:fold).gsub(/\s+/, " ").strip == key }
        end
        raise Error, "font family is not installed: #{family}" unless face

        Okab::Font.new(database.open(face.path, index: face.index))
      end
    end
    private_class_method :font_for_style

    def fit_text(text, font, size, width)
      return text if font.measure(text, size: size) <= width

      result = +""
      text.each_char do |character|
        break if font.measure(result + character + "…", size: size) > width
        result << character
      end
      result + "…"
    end
    private_class_method :fit_text

    def rgb(color)
      color.delete_prefix("#").scan(/../).map { |channel| channel.to_i(16) / 255.0 }
    end
    private_class_method :rgb

    def normalize_font(font)
      font = Okab::Font.load(font) if font.is_a?(String)
      font = Okab::Font.new(font) if font.is_a?(Alhena::Font)
      raise ArgumentError, "font must be an Okab::Font, Alhena::Font, or font path" unless font.is_a?(Okab::Font)

      font
    end
    private_class_method :normalize_font
  end
end
