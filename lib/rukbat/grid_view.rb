# frozen_string_literal: true

module Rukbat
  class GridView < Zaniah::UI::Component
    UI = Zaniah::UI
    MAX_FILL_CELLS = 100_000

    attr_reader :grid, :formula_field, :active_cell, :status, :completion_session,
      :completion_candidate

    def initialize(workbook, on_save: nil)
      super()
      @workbook, @on_save = workbook, on_save
      @active_cell, @status = [1, 1], "Ready"
      @formula_field = UI::TextField.new("")
      @formula_field.on_change { |text, cx| update_completion(text); cx.window.request_frame }
      @function_index = Spica::Index.new(Furud::Functions.standard.names)
      @completion_session = @function_index.session
      @completion_button = UI::Button.new("Use completion", size: :sm, variant: :secondary)
        .on_click { apply_completion }
      @apply_button = UI::Button.new("Apply", size: :sm).on_click { apply_edit }
      @save_button = UI::Button.new("Save", size: :sm, variant: :secondary).on_click { save }
      @undo_button = UI::Button.new("Undo", size: :sm, variant: :ghost).on_click { undo }
      @redo_button = UI::Button.new("Redo", size: :sm, variant: :ghost).on_click { redo }
      @add_sheet_button = UI::Button.new("+ Sheet", size: :sm, variant: :secondary).on_click { add_sheet }
      @grid = UI::Grid.new(rows: Workbook::MAX_ROWS + 1, columns: Workbook::MAX_COLUMNS + 1,
        row_height: 24, column_width: ->(index) { index.zero? ? 52 : 112 },
        frozen_rows: 1, frozen_columns: 1) do |row, column, _bounds, _cx|
        render_cell(row, column)
      end
      @grid.on_select { |areas, _event, cx| selection_changed(areas, cx) }
      @grid.on_edit { |row, column, _event, cx| begin_edit(row, column, cx) }
      @grid.on_fill { |source, target, _cx| fill(source, target) }
      sync_formula_field
    end

    def build(cx)
      @cx = cx
      toolbar = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(@undo_button).child(@redo_button).child(@save_button).child(@add_sheet_button)
      sheets = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
      @workbook.sheet_names.each do |name|
        variant = name == @workbook.active_sheet ? :secondary : :ghost
        sheets.child(UI::Button.new(name, size: :sm, variant: variant).on_click do
          @workbook.activate(name)
          sync_formula_field
          update_status
        end)
      end
      formula_row = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(UI::Label.new(cell_address(*@active_cell), size: :sm))
        .child(@formula_field.style(flex_grow: 1, flex_basis: 0))
        .child(UI::Label.new(@completion_candidate || "", tone: :muted, size: :sm))
        .child(@completion_button.disabled(@completion_candidate.nil?))
        .child(@apply_button)
      status_row = Zaniah::Div.new.flex_row.items_center.style(justify_content: :space_between)
        .child(UI::Label.new(@status, tone: :muted, size: :sm)).child(sheets)
      Zaniah::Div.new.flex_col.gap(cx.theme.spacing[1]).p(cx.theme.spacing[2])
        .style(width: percent(100), height: percent(100))
        .child(toolbar).child(formula_row).child(@grid.flex_1).child(status_row)
    end

    def undo
      @status = @workbook.undo ? "Undone" : "Nothing to undo"
      sync_formula_field
      request_frame
    end

    def redo
      @status = @workbook.redo ? "Redone" : "Nothing to redo"
      sync_formula_field
      request_frame
    end

    def handle_shortcut(event, window)
      return false unless event.is_a?(Zaniah::Input::KeyDown)

      case event.keystroke.to_s
      when "ctrl-s", "cmd-s" then save
      when "ctrl-z", "cmd-z"
        return false if focused_text_field?(window)
        undo
      when "ctrl-shift-z", "cmd-shift-z"
        return false if focused_text_field?(window)
        self.redo
      else return false
      end
      true
    end

    def apply_edit
      value = CSVFile.parse_cell(@formula_field.value)
      value.nil? ? @workbook.clear(*@active_cell) : @workbook.set(*@active_cell, value)
      @status = "Applied #{cell_address(*@active_cell)}"
      sync_formula_field
      request_frame
      true
    rescue Rukbat::Error, ArgumentError, TypeError => error
      @status = error.message
      request_frame
      false
    end

    private

    def render_cell(row, column)
      value = if row.zero?
        column.zero? ? "" : column_name(column)
      elsif column.zero?
        row.to_s
      else
        @workbook[row, column]
      end
      UI::Label.new(value.to_s, size: :sm, wrap: :none)
    rescue Rukbat::Error
      UI::Label.new("", size: :sm)
    end

    def selection_changed(areas, cx)
      area = areas.last
      return unless area
      row, column = [area.rows.begin, 1].max, [area.columns.begin, 1].max
      return if row > Workbook::MAX_ROWS || column > Workbook::MAX_COLUMNS

      @active_cell = [row, column]
      sync_formula_field
      update_status(area)
      cx.window.request_frame if cx.respond_to?(:window)
    end

    def begin_edit(row, column, cx)
      return if row.zero? || column.zero?

      @active_cell = [row, column]
      sync_formula_field
      cx.dispatcher.focus(@formula_field.focus_handle) if @formula_field.focus_handle
      request_frame
    end

    def fill(source, target)
      source_top, source_left = [source.rows.begin, 1].max, [source.columns.begin, 1].max
      source_bottom, source_right = source.rows.end, source.columns.end
      return if source_top >= source_bottom || source_left >= source_right

      target_top, target_left = [target.rows.begin, 1].max, [target.columns.begin, 1].max
      fill_cells = (target.rows.end - target_top) * (target.columns.end - target_left)
      if fill_cells > MAX_FILL_CELLS
        @status = "Fill area exceeds #{MAX_FILL_CELLS} cells"
        request_frame
        return false
      end

      source_height, source_width = source_bottom - source_top, source_right - source_left
      changes = []
      (target_top...target.rows.end).each do |row|
        (target_left...target.columns.end).each do |column|
          next if row >= source_top && row < source_bottom && column >= source_left && column < source_right

          from_row = source_top + ((row - source_top) % source_height)
          from_column = source_left + ((column - source_left) % source_width)
          value = @workbook.input_at(from_row, from_column)
          value = translated_formula(value, from_row, from_column, row, column) if value.is_a?(String) && value.start_with?("=")
          changes << [row, column, value]
        end
      end
      @workbook.set_many(changes) unless changes.empty?
      update_status(target)
      request_frame
    end

    def translated_formula(value, from_row, from_column, to_row, to_column)
      from = Furud::Reference.new(sheet: @workbook.active_sheet, row: from_row, column: from_column)
      to = Furud::Reference.new(sheet: @workbook.active_sheet, row: to_row, column: to_column)
      ast = Furud::Formula.parse(value, origin: from)
      invalid_reference = false
      Furud::Formula.visit(ast) do |node|
        next unless %i[reference qualified_reference].include?(node.type)

        reference = node.value
        row = reference.absolute_row ? reference.row : to.row + reference.row - from.row
        column = reference.absolute_column ? reference.column : to.column + reference.column - from.column
        invalid_reference ||= !row.between?(1, Workbook::MAX_ROWS) || !column.between?(1, Workbook::MAX_COLUMNS)
      end
      return "=#REF!" if invalid_reference

      translated = Furud::Formula.translate(ast, from: from, to: to)
      invalid_reference = Furud::Formula.references(translated).any? do |reference|
        if reference.is_a?(Furud::Reference)
          !reference.row.between?(1, Workbook::MAX_ROWS) || !reference.column.between?(1, Workbook::MAX_COLUMNS)
        else
          reference.top < 1 || reference.left < 1 || reference.bottom > Workbook::MAX_ROWS || reference.right > Workbook::MAX_COLUMNS
        end
      end
      invalid_reference ? "=#REF!" : Furud::Formula.render(translated, origin: to)
    rescue Furud::ParseError, ArgumentError
      value
    end

    def update_status(area = @grid.selection.last)
      return @status = "Ready" unless area

      top, left = [area.rows.begin, 1].max, [area.columns.begin, 1].max
      bottom, right = [area.rows.end - 1, top].max, [area.columns.end - 1, left].max
      summary = @workbook.summary(top, left, bottom, right)
      @status = "#{summary.count} cells · Sum #{summary.sum} · Average #{summary.average || "—"} · Numeric #{summary.numeric_count}"
    rescue Rukbat::Error => error
      @status = error.message
    end

    def sync_formula_field
      value = @workbook.input_at(*@active_cell).to_s
      @formula_field.buffer.replace(0...@formula_field.buffer.bytesize, value.encode(Encoding::UTF_8))
      update_completion(value)
    end

    def update_completion(text)
      token = text[/([A-Za-z][A-Za-z0-9_.]*)\z/, 1]
      @completion_candidate = nil
      return unless token && (text.start_with?("=") || text.match?(/[+\-*\/(,]\s*#{Regexp.escape(token)}\z/i))
      return if token.length < 2

      @completion_session.query = token
      match = @completion_session.matches(1).first
      @completion_candidate = match.candidate if match && match.candidate != token.upcase
    end

    def apply_completion
      return unless @completion_candidate
      token = @formula_field.value[/([A-Za-z][A-Za-z0-9_.]*)\z/, 1]
      return unless token

      text = @formula_field.value
      value = text.byteslice(0, text.bytesize - token.bytesize) + @completion_candidate
      @formula_field.buffer.replace(0...@formula_field.buffer.bytesize, value.encode(Encoding::UTF_8))
      update_completion(value)
      request_frame
    end

    def add_sheet
      index = @workbook.sheet_names.length + 1
      name = "Sheet#{index}"
      index += 1 while @workbook.sheet_names.include?(name)
      @workbook.add_sheet(name)
      @active_cell = [1, 1]
      sync_formula_field
      @status = "Added #{name}"
      request_frame
    end

    def save
      @status = @on_save ? @on_save.call.to_s : "Save is unavailable"
      request_frame
      true
    rescue StandardError => error
      @status = "Save failed: #{error.message}"
      request_frame
      false
    end

    def request_frame = @cx&.window&.request_frame

    def focused_text_field?(window)
      window.dispatcher.focused&.ancestors&.any? { |handle| handle.context[:in_text_field] }
    end

    def cell_address(row, column) = "#{column_name(column)}#{row}"

    def column_name(column)
      result = +""
      while column.positive?
        column, remainder = (column - 1).divmod(26)
        result.prepend((65 + remainder).chr)
      end
      result
    end
  end
end
