# frozen_string_literal: true

require "tempfile"

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

    def render(workbook, font:, sheet: workbook.active_sheet)
      font = normalize_font(font)
      current = workbook.sheet(sheet)
      rows, columns = [current.row_count, 1].max, [current.column_count, 1].max
      raise Error, "PDF export exceeds #{MAX_CELLS} cells" if rows * columns > MAX_CELLS

      document = Okab::Document.new(title: "#{sheet} — Rukbat", author: "Yudai Takada", creator: "Rukbat")
      (0...rows).step(ROWS_PER_PAGE) do |row_offset|
        (0...columns).step(COLUMNS_PER_PAGE) do |column_offset|
          render_page(document, workbook, font, sheet, row_offset, column_offset,
            [rows - row_offset, ROWS_PER_PAGE].min, [columns - column_offset, COLUMNS_PER_PAGE].min)
        end
      end
      document.render
    end

    def write(workbook, path, font:, sheet: workbook.active_sheet)
      bytes = render(workbook, font: font, sheet: sheet)
      target = File.expand_path(path)
      stat = File.lstat(target) if File.exist?(target) || File.symlink?(target)
      raise Error, "PDF target must be a regular file" if stat && !stat.file?

      mode = stat ? stat.mode & 0o7777 : 0o666 & ~File.umask
      Tempfile.create([".rukbat-", ".pdf"], File.dirname(target), binmode: true) do |file|
        file.write(bytes)
        file.flush
        file.fsync
        file.chmod(mode)
        File.rename(file.path, target)
      end
      path
    rescue SystemCallError => error
      raise Error, "cannot write PDF: #{error.message}"
    end

    def render_page(document, workbook, font, sheet, row_offset, column_offset, row_count, column_count)
      document.page(width: PAGE_WIDTH, height: PAGE_HEIGHT) do |page|
        page.text("#{sheet} — rows #{row_offset + 1}-#{row_offset + row_count}",
          x: MARGIN, y: PAGE_HEIGHT - MARGIN, font: font, size: 10)
        data_top = PAGE_HEIGHT - MARGIN - 24
        (0..row_count).each do |row_index|
          (0..column_count).each do |column_index|
            x = MARGIN + (column_index.zero? ? 0 : 38 + (column_index - 1) * CELL_WIDTH)
            width = column_index.zero? ? 38 : CELL_WIDTH
            y = data_top - row_index * CELL_HEIGHT
            text, style = cell_text(workbook, sheet, row_offset, column_offset, row_index, column_index)
            paint_cell(page, text, style, font, x, y, width)
          end
        end
      end
    end
    private_class_method :render_page

    def cell_text(workbook, sheet, row_offset, column_offset, row_index, column_index)
      return ["", {}] if row_index.zero? && column_index.zero?
      return [(row_offset + row_index).to_s, {}] if column_index.zero?
      return [Furud::Formula.column_name(column_offset + column_index), {}] if row_index.zero?

      row, column = row_offset + row_index, column_offset + column_index
      workbook.presentation_at(row, column, sheet: sheet)
    end
    private_class_method :cell_text

    def paint_cell(page, text, style, font, x, top, width)
      y = top - CELL_HEIGHT
      if style[:background]
        page.rect(x, y, width, CELL_HEIGHT).fill(rgb(style[:background]))
      end
      page.rect(x, y, width, CELL_HEIGHT).stroke(rgb(style[:border_color] || "#B8BEC8"),
        width: style[:border_width] || 0.5)
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
        page.text(text, x: text_x, y: baseline, font: font, size: size,
          color: rgb(style[:color] || "#20242C"))
      end
    end
    private_class_method :paint_cell

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
