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
      @rendered_cells = {}
      @editing_cell = @inline_buffer = @inline_editor = nil
      @inline_focus_pending = false
      @formula_field = UI::TextField.new("")
      @formula_field.on_change do |text, cx|
        update_completion(text)
        @inline_buffer.replace(0...@inline_buffer.bytesize, text.encode(Encoding::UTF_8)) if @inline_buffer
        cx.window.request_frame
      end
      @function_index = Spica::Index.new(Furud::Functions.standard.names)
      @completion_session = @function_index.session
      @completion_button = UI::Button.new("Use completion", size: :sm, variant: :secondary)
        .on_click { apply_completion }
      @apply_button = UI::Button.new("Apply", size: :sm).on_click { apply_edit }
      @save_button = UI::Button.new("Save", size: :sm, variant: :secondary).on_click { save }
      @undo_button = UI::Button.new("Undo", size: :sm, variant: :ghost).on_click { undo }
      @redo_button = UI::Button.new("Redo", size: :sm, variant: :ghost).on_click { redo }
      @add_sheet_button = UI::Button.new("+ Sheet", size: :sm, variant: :secondary).on_click { add_sheet }
      @number_button = UI::Button.new("#,##0.00", size: :sm, variant: :ghost).on_click { apply_format(number_format: "#,##0.00") }
      @percent_button = UI::Button.new("%", size: :sm, variant: :ghost).on_click { apply_format(number_format: "0.00%") }
      @bold_button = UI::Button.new("Bold", size: :sm, variant: :ghost).on_click { toggle_bold }
      @fill_button = UI::Button.new("Fill", size: :sm, variant: :ghost).on_click { apply_format(background: "#FFF2CC") }
      @freeze_button = UI::Button.new("Freeze", size: :sm, variant: :ghost).on_click { freeze_panes }
      @unfreeze_button = UI::Button.new("Unfreeze", size: :sm, variant: :ghost).on_click { unfreeze_panes }
      @clear_conditional_button = UI::Button.new("Clear highlights", size: :sm, variant: :ghost).on_click { clear_highlights }
      @line_chart_button = UI::Button.new("Line", size: :sm, variant: :ghost).on_click { show_chart(:line) }
      @bar_chart_button = UI::Button.new("Bar", size: :sm, variant: :ghost).on_click { show_chart(:bar) }
      @pie_chart_button = UI::Button.new("Pie", size: :sm, variant: :ghost).on_click { show_chart(:pie) }
      @font_down_button = UI::Button.new("A−", size: :sm, variant: :ghost).on_click { change_font_size(-1) }
      @font_up_button = UI::Button.new("A+", size: :sm, variant: :ghost).on_click { change_font_size(1) }
      @align_button = UI::Button.new("Align", size: :sm, variant: :ghost).on_click { cycle_alignment }
      @text_color_button = UI::Button.new("Text color", size: :sm, variant: :ghost).on_click { apply_format(color: "#C00000") }
      @border_button = UI::Button.new("Border", size: :sm, variant: :ghost).on_click do
        apply_format(border_color: "#7F8793", border_width: 1)
      end
      @sort_button = UI::Button.new("Sort ↑", size: :sm, variant: :ghost).on_click { sort_selection }
      @filter_field = UI::TextField.new("")
      @filter_button = UI::Button.new("Filter", size: :sm, variant: :ghost).on_click { apply_filter }
      @clear_filter_button = UI::Button.new("Show all", size: :sm, variant: :ghost).on_click { clear_filter }
      @remove_duplicates_button = UI::Button.new("Unique", size: :sm, variant: :ghost).on_click { remove_duplicates }
      @hide_rows_button = UI::Button.new("Hide rows", size: :sm, variant: :ghost).on_click { hide_selected_rows }
      @hide_columns_button = UI::Button.new("Hide cols", size: :sm, variant: :ghost).on_click { hide_selected_columns }
      @show_hidden_button = UI::Button.new("Show hidden", size: :sm, variant: :ghost).on_click { show_hidden }
      @insert_row_button = UI::Button.new("Insert row", size: :sm, variant: :ghost).on_click { edit_structure(:insert_rows) }
      @delete_rows_button = UI::Button.new("Delete rows", size: :sm, variant: :ghost).on_click { edit_structure(:delete_rows) }
      @insert_column_button = UI::Button.new("Insert col", size: :sm, variant: :ghost).on_click { edit_structure(:insert_columns) }
      @delete_columns_button = UI::Button.new("Delete cols", size: :sm, variant: :ghost).on_click { edit_structure(:delete_columns) }
      @set_print_area_button = UI::Button.new("Set print area", size: :sm, variant: :ghost).on_click { set_print_area }
      @clear_print_area_button = UI::Button.new("Clear print area", size: :sm, variant: :ghost).on_click { clear_print_area }
      @export_pdf_button = UI::Button.new("Export PDF", size: :sm, variant: :ghost).on_click { export_pdf }
      @find_field = UI::TextField.new("")
      @replace_field = UI::TextField.new("")
      @find_button = UI::Button.new("Find", size: :sm, variant: :ghost).on_click { find_selection }
      @replace_button = UI::Button.new("Replace", size: :sm, variant: :ghost).on_click { replace_selection }
      @comment_field = UI::TextField.new("")
      @comment_button = UI::Button.new("Comment", size: :sm, variant: :ghost).on_click { save_comment }
      @name_field = UI::TextField.new("")
      @name_button = UI::Button.new("Name range", size: :sm, variant: :ghost).on_click { name_selection }
      @highlight_button = UI::Button.new("> 0", size: :sm, variant: :ghost).on_click { highlight_positive }
      @sort_ascending = true
      @filter_hidden_rows = []
      @applied_hidden_rows = []
      @applied_hidden_columns = []
      @change_observer = @workbook.on_cells_changed do |sheet, cells|
        invalidate_rendered_cells(sheet, cells)
        request_frame if sheet.nil? || sheet == @workbook.active_sheet
      end
      frozen_rows, frozen_columns = @workbook.frozen_panes
      @grid = UI::Grid.new(rows: Workbook::MAX_ROWS + 1, columns: Workbook::MAX_COLUMNS + 1,
        row_height: 24, column_width: ->(index) { index.zero? ? 52 : 112 },
        frozen_rows: frozen_rows, frozen_columns: frozen_columns) do |row, column, bounds, _cx|
        render_cell(row, column, bounds)
      end
      @grid.on_select { |areas, _event, cx| selection_changed(areas, cx) }
      @grid.on_edit { |row, column, _event, cx| begin_edit(row, column, cx) }
      @grid.on_fill { |source, target, _cx| fill(source, target) }
      sync_grid_visibility
      sync_formula_field
    end

    def request_layout(cx)
      @rendered_cells_used = {}
      layout = super
      if @inline_focus_pending && @inline_editor&.focus_handle
        cx.dispatcher.focus(@inline_editor.focus_handle)
        @inline_focus_pending = false
      end
      layout
    ensure
      if @rendered_cells_used
        @rendered_cells.delete_if { |key, _cell| !@rendered_cells_used.key?(key) }
        @rendered_cells_used = nil
      end
    end

    def build(cx)
      @cx = cx
      render_context = [cx.theme, cx.text_system]
      if @render_context != render_context
        @rendered_cells.clear
        @render_context = render_context
      end
      toolbar = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(@undo_button).child(@redo_button).child(@save_button).child(@add_sheet_button)
        .child(@number_button).child(@percent_button).child(@bold_button).child(@fill_button)
        .child(@freeze_button).child(@unfreeze_button).child(@clear_conditional_button)
        .child(@line_chart_button).child(@bar_chart_button).child(@pie_chart_button)
      format_toolbar = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(@font_down_button).child(@font_up_button).child(@align_button)
        .child(@text_color_button).child(@border_button)
      data_toolbar = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(@sort_button).child(@remove_duplicates_button)
        .child(@filter_field.style(width: 120)).child(@filter_button).child(@clear_filter_button)
        .child(@hide_rows_button).child(@hide_columns_button).child(@show_hidden_button)
      structure_toolbar = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(@insert_row_button).child(@delete_rows_button)
        .child(@insert_column_button).child(@delete_columns_button)
        .child(@set_print_area_button).child(@clear_print_area_button).child(@export_pdf_button)
      annotation_toolbar = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(@highlight_button).child(@comment_field.style(width: 150)).child(@comment_button)
        .child(@name_field.style(width: 120)).child(@name_button)
      find_toolbar = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
        .child(@find_field.style(width: 140)).child(@find_button)
        .child(@replace_field.style(width: 140)).child(@replace_button)
      sheets = Zaniah::Div.new.flex_row.items_center.gap(cx.theme.spacing[1])
      @workbook.sheet_names.each do |name|
        variant = name == @workbook.active_sheet ? :secondary : :ghost
        sheets.child(UI::Button.new(name, size: :sm, variant: variant).on_click do
          clear_filter
          @workbook.activate(name)
          sync_grid_visibility
          sync_frozen_panes
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
      content = Zaniah::Div.new.flex_col.gap(cx.theme.spacing[1]).p(cx.theme.spacing[2])
        .style(width: percent(100), height: percent(100))
        .child(toolbar).child(format_toolbar).child(data_toolbar).child(structure_toolbar).child(annotation_toolbar)
        .child(find_toolbar).child(formula_row).child(@grid.flex_1)
      content.child(@chart_component) if @chart_component
      content.child(status_row)
      content
    end

    def undo
      @status = @workbook.undo ? "Undone" : "Nothing to undo"
      sync_grid_visibility
      sync_frozen_panes
      sync_formula_field
      request_frame
    end

    def redo
      @status = @workbook.redo ? "Redone" : "Nothing to redo"
      sync_grid_visibility
      sync_frozen_panes
      sync_formula_field
      request_frame
    end

    def handle_shortcut(event, window)
      return false unless event.is_a?(Zaniah::Input::KeyDown)

      if @editing_cell
        case event.keystroke.to_s
        when "enter" then return commit_inline_edit
        when "esc", "escape" then return cancel_inline_edit
        end
      end

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
      if @editing_cell
        @inline_buffer.replace(0...@inline_buffer.bytesize, @formula_field.value.encode(Encoding::UTF_8))
        return commit_inline_edit
      end

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

    def sort_selection
      clear_filter
      top, left, bottom, right = selected_coordinates
      by = left
      @workbook.sort(top, left, bottom, right, by: by, ascending: @sort_ascending)
      @sort_ascending = !@sort_ascending
      @sort_button.text = @sort_ascending ? "Sort ↑" : "Sort ↓" if @sort_button.respond_to?(:text=)
      @status = "Sorted #{cell_address(top, left)}:#{cell_address(bottom, right)}"
      sync_formula_field
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def apply_filter
      top, left, bottom, = selected_coordinates
      clear_filter
      return true if top > bottom

      rows = @workbook.filter_rows(top, bottom, by: left, query: @filter_field.value)
      matching = rows.to_h { |row| [row, true] }
      @filter_hidden_rows = (top..bottom).reject { |row| matching.key?(row) }
      @grid.hide_rows(@filter_hidden_rows, hidden: true) unless @filter_hidden_rows.empty?
      @status = "Showing #{rows.length} matching rows"
      request_frame
      true
    rescue Rukbat::Error, ArgumentError => error
      @status = error.message
      request_frame
      false
    end

    def clear_filter
      @grid.hide_rows(@filter_hidden_rows, hidden: false) unless @filter_hidden_rows.empty?
      @filter_hidden_rows = []
      sync_grid_visibility
      @status = "Filter cleared"
      request_frame
      true
    end

    def remove_duplicates
      clear_filter
      top, left, bottom, right = selected_coordinates
      removed = @workbook.remove_duplicates(top, left, bottom, right)
      sync_grid_visibility
      sync_formula_field
      @status = "Removed #{removed} duplicate rows"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def find_selection
      top, left, bottom, right = selected_coordinates
      matches = @workbook.find(@find_field.value, top: top, left: left, bottom: bottom, right: right)
      @grid.selection = matches.map do |reference|
        UI::Grid::Area.new(rows: reference.row...(reference.row + 1),
          columns: reference.column...(reference.column + 1))
      end
      @active_cell = [matches.first.row, matches.first.column] unless matches.empty?
      sync_formula_field unless matches.empty?
      @status = "Found #{matches.length} cells"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def replace_selection
      top, left, bottom, right = selected_coordinates
      count = @workbook.replace_all(@find_field.value, @replace_field.value,
        top: top, left: left, bottom: bottom, right: right)
      sync_formula_field
      @status = "Replaced #{count} cells"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def save_comment
      @workbook.set_comment(*@active_cell, @comment_field.value)
      @status = "Comment saved for #{cell_address(*@active_cell)}"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def name_selection
      top, left, bottom, right = selected_coordinates
      @workbook.define_name(@name_field.value, top, left, bottom, right)
      @status = "Named range #{@name_field.value}"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def change_font_size(delta)
      current = @workbook.format_at(*@active_cell).fetch(:font_size, 12)
      apply_format(font_size: (current + delta).clamp(6, 72))
    end

    def cycle_alignment
      current = @workbook.format_at(*@active_cell).fetch(:horizontal_alignment, :left)
      alignment = {left: :center, center: :right, right: :left}.fetch(current, :left)
      apply_format(horizontal_alignment: alignment)
    end

    def hide_selected_rows
      top, _left, bottom, = selected_coordinates
      @workbook.hide_rows(top, bottom)
      sync_grid_visibility
      @status = "Hidden rows #{top}-#{bottom}"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def hide_selected_columns
      _top, left, _bottom, right = selected_coordinates
      @workbook.hide_columns(left, right)
      sync_grid_visibility
      @status = "Hidden columns #{left}-#{right}"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def show_hidden
      clear_filter
      @workbook.clear_hidden(:rows)
      @workbook.clear_hidden(:columns)
      sync_grid_visibility
      @status = "All rows and columns are visible"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def edit_structure(operation)
      top, left, bottom, right = selected_coordinates
      if operation == :insert_rows || operation == :delete_rows
        start = top
        count = operation == :insert_rows ? 1 : bottom - top + 1
      else
        start = left
        count = operation == :insert_columns ? 1 : right - left + 1
      end
      @workbook.public_send(operation, start, count)
      sync_grid_visibility
      sync_formula_field
      @status = "#{operation.to_s.tr('_', ' ').capitalize} at #{start} (#{count})"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def set_print_area
      top, left, bottom, right = selected_coordinates
      @workbook.set_print_area(top, left, bottom, right)
      @status = "Print area set to #{cell_address(top, left)}:#{cell_address(bottom, right)}"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def clear_print_area
      @workbook.clear_print_area
      @status = "Print area cleared"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def export_pdf
      window = @cx&.window
      raise Rukbat::Error, "PDF export requires an interactive window" unless window&.respond_to?(:prompt_for_paths)

      font = window.prompt_for_paths.first
      return false unless font
      path = window.prompt_for_paths(save: true).first
      return false unless path
      path = "#{path}.pdf" if File.extname(path).empty?

      PDFFile.write(@workbook, path, font: font)
      @status = "Exported #{File.basename(path)}"
      request_frame
      true
    rescue Rukbat::Error, ArgumentError => error
      @status = error.message
      request_frame
      false
    end

    def sync_grid_visibility
      @grid.hide_rows(@applied_hidden_rows, hidden: false) unless @applied_hidden_rows.empty?
      @grid.hide_columns(@applied_hidden_columns, hidden: false) unless @applied_hidden_columns.empty?
      @applied_hidden_rows = @workbook.hidden_rows
      @applied_hidden_columns = @workbook.hidden_columns
      @grid.hide_rows(@applied_hidden_rows, hidden: true) unless @applied_hidden_rows.empty?
      @grid.hide_columns(@applied_hidden_columns, hidden: true) unless @applied_hidden_columns.empty?
    end

    def highlight_positive
      top, left, bottom, right = selected_coordinates
      @workbook.add_conditional_format(top, left, bottom, right, operator: :greater_than,
        value: 0, style: {color: "#008000"})
      @status = "Added positive-value highlight"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def clear_highlights
      @workbook.clear_conditional_formats
      @status = "Conditional formatting cleared"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    private

    def render_cell(row, column, bounds)
      key = [@workbook.active_sheet, row, column, bounds.height]
      @rendered_cells_used[key] = true if @rendered_cells_used
      return @rendered_cells[key] if @rendered_cells.key?(key)

      content = if row.zero?
        UI::Label.new(column.zero? ? "" : column_name(column), size: :sm, wrap: :none)
      elsif column.zero?
        UI::Label.new(row.to_s, size: :sm, wrap: :none)
      else
        render_data_cell(row, column, bounds)
      end
      @rendered_cells[key] = content
    rescue Rukbat::Error
      @rendered_cells[key] = UI::Label.new("", size: :sm)
    end

    def render_data_cell(row, column, bounds)
      return @inline_editor if @editing_cell == [row, column]

      text, style = @workbook.presentation_at(row, column)
      comment = @workbook.comment_at(row, column)
      if style.empty? && comment.nil?
        line_height = 12 * 1.4
        return Zaniah::Text.new(text, size: 12, color: @cx.theme.colors.text, wrap: :none)
          .style(margin_top: [(bounds.height - line_height) / 2, 0].max)
      end

      font = if style[:font_family] || style[:bold] || style[:italic]
        @cx.text_system&.font_db&.find(family: style[:font_family],
          weight: style[:bold] ? 700 : 400, style: style[:italic] ? :italic : :normal)
      end
      alignment = {left: :start, center: :center, right: :end}.fetch(style[:horizontal_alignment], :start)
      vertical = {top: :start, middle: :center, bottom: :end}.fetch(style[:vertical_alignment], :center)
      content = Zaniah::Text.new(text, size: style[:font_size] || 12, color: style[:color] || @cx.theme.colors.text,
        font: font, wrap: :none, align: alignment)
      cell = Zaniah::Div.new.flex_row.w_full.h_full.p([1, 4])
        .style(align_items: vertical, background: style[:background] || "#0000",
          border: style[:border_width] || 0, border_color: style[:border_color])
        .child(content)
      cell.tooltip(comment) if comment
      cell
    end

    def invalidate_rendered_cells(sheet, cells)
      if cells.nil?
        @rendered_cells.delete_if { |key, _cell| sheet.nil? || key[0] == sheet }
        return
      end

      if cells.is_a?(Workbook::CellRange)
        @rendered_cells.delete_if do |key, _cell|
          key[0] == sheet && cells.include?(key[1], key[2])
        end
        return
      end

      changed = cells.to_h { |row, column| [[sheet, row, column], true] }
      @rendered_cells.delete_if { |key, _cell| changed.key?(key.first(3)) }
    end

    def selection_changed(areas, cx)
      area = areas.last
      return unless area
      row, column = [area.rows.begin, 1].max, [area.columns.begin, 1].max
      return if row > Workbook::MAX_ROWS || column > Workbook::MAX_COLUMNS

      if @editing_cell && @editing_cell != [row, column] && !commit_inline_edit
        edited_row, edited_column = @editing_cell
        @grid.selection = [UI::Grid::Area.new(rows: edited_row...(edited_row + 1),
          columns: edited_column...(edited_column + 1))]
        cx.window.request_frame if cx.respond_to?(:window)
        return
      end
      @active_cell = [row, column]
      sync_formula_field unless @editing_cell == @active_cell
      update_status(area)
      cx.window.request_frame if cx.respond_to?(:window)
    end

    def begin_edit(row, column, cx)
      return if row.zero? || column.zero?
      return if @editing_cell == [row, column]
      return unless commit_inline_edit if @editing_cell && @editing_cell != [row, column]

      @active_cell = [row, column]
      sync_formula_field
      @editing_cell = [row, column]
      @inline_buffer = Zaniah::TextBuffer.new(@workbook.input_at(row, column).to_s.encode(Encoding::UTF_8))
      @inline_editor = Zaniah::Text.new(@inline_buffer.to_s, size: 12, color: cx.theme.colors.text, wrap: :none)
        .editable(@inline_buffer)
        .style(width: percent(100), height: percent(100), padding: [0, 4])
        .on_change do |text|
          @formula_field.buffer.replace(0...@formula_field.buffer.bytesize, text.encode(Encoding::UTF_8))
          update_completion(text)
          cx.window.request_frame
        end
      @inline_editor.selection = Zaniah::TextSelection.new(@inline_buffer.bytesize)
      @inline_focus_pending = true
      @rendered_cells.delete_if { |key, _cell| key[0] == @workbook.active_sheet && key[1] == row && key[2] == column }
      cx.dispatcher.focus(@formula_field.focus_handle) if @formula_field.focus_handle
      request_frame
    end

    def commit_inline_edit
      return false unless @editing_cell

      row, column = @editing_cell
      value = CSVFile.parse_cell(@inline_buffer.to_s)
      value.nil? ? @workbook.clear(row, column) : @workbook.set(row, column, value)
      @editing_cell = @inline_buffer = @inline_editor = nil
      @inline_focus_pending = false
      @status = "Applied #{cell_address(row, column)}"
      @rendered_cells.delete_if { |key, _cell| key[0] == @workbook.active_sheet && key[1] == row && key[2] == column }
      sync_formula_field
      @cx&.dispatcher&.focus(@grid.focus_handle)
      request_frame
      true
    rescue Rukbat::Error, ArgumentError, TypeError => error
      @status = error.message
      request_frame
      false
    end

    def cancel_inline_edit
      return false unless @editing_cell

      row, column = @editing_cell
      @editing_cell = @inline_buffer = @inline_editor = nil
      @inline_focus_pending = false
      @rendered_cells.delete_if { |key, _cell| key[0] == @workbook.active_sheet && key[1] == row && key[2] == column }
      sync_formula_field
      @cx&.dispatcher&.focus(@grid.focus_handle)
      request_frame
      true
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
      @workbook.translate_formula(value, from: from, to: to)
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
      comment = @workbook.comment_at(*@active_cell).to_s
      @comment_field.buffer.replace(0...@comment_field.buffer.bytesize, comment.encode(Encoding::UTF_8))
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

    def apply_format(**properties)
      coordinates = selected_coordinates
      @workbook.format_range(*coordinates, sheet: @workbook.active_sheet, **properties)
      @status = "Formatted #{cell_address(coordinates[0], coordinates[1])}"
      request_frame
      true
    rescue Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def toggle_bold
      value = !@workbook.format_at(*@active_cell).fetch(:bold, false)
      apply_format(bold: value)
    end

    def freeze_panes
      rows, columns = @active_cell[0] + 1, @active_cell[1] + 1
      @workbook.set_frozen_panes(rows: rows, columns: columns)
      @grid.freeze_panes(rows: rows, columns: columns)
      @status = "Frozen through #{cell_address(*@active_cell)}"
      request_frame
      true
    end

    def unfreeze_panes
      @workbook.set_frozen_panes(rows: 0, columns: 0)
      @grid.freeze_panes(rows: 0, columns: 0)
      @status = "Unfrozen panes"
      request_frame
      true
    end

    def sync_frozen_panes
      rows, columns = @workbook.frozen_panes
      @grid.freeze_panes(rows: rows, columns: columns)
    end

    def show_chart(type)
      top, left, bottom, right = selected_coordinates
      if bottom == top
        @status = "Select a header and at least one data row"
        request_frame
        return false
      end
      series = chart_series(top, left, bottom, right)
      @chart_component = case type
      when :line then UI::LineChart.new(series, width: 480, height: 180)
      when :bar then UI::BarChart.new(series, width: 480, height: 180)
      when :pie then UI::PieChart.new(pie_values(top, left, bottom, right), width: 320, height: 180)
      else raise ArgumentError, "unsupported chart type"
      end
      @status = "#{type.to_s.capitalize} chart"
      request_frame
      true
    rescue ArgumentError, Rukbat::Error => error
      @status = error.message
      request_frame
      false
    end

    def selected_coordinates
      area = @grid.selection.last
      return [*@active_cell, *@active_cell] unless area

      top, left = [area.rows.begin, 1].max, [area.columns.begin, 1].max
      bottom, right = [area.rows.end - 1, top].max, [area.columns.end - 1, left].max
      [top, left, bottom, right]
    end

    def chart_series(top, left, bottom, right)
      columns = left == right ? [left] : ((left + 1)..right).to_a
      raise ArgumentError, "select at least one numeric series column" if columns.empty?

      columns.to_h do |column|
        name = @workbook.input_at(top, column).to_s
        name = "Series #{column_name(column)}" if name.empty?
        values = ((top + 1)..bottom).map do |row|
          value = @workbook[row, column]
          value.nil? ? 0 : Float(value)
        rescue ArgumentError, TypeError
          0
        end
        [name, values]
      end
    end

    def pie_values(top, left, bottom, right)
      column = right > left ? left + 1 : left
      (top + 1..bottom).to_h do |row|
        label = right > left ? @workbook[row, left].to_s : row.to_s
        value = @workbook[row, column]
        number = value.nil? ? 0 : Float(value)
        [label.empty? ? row.to_s : label, number]
      rescue ArgumentError, TypeError
        [label.empty? ? row.to_s : label, 0]
      end
    end

    def add_sheet
      index = @workbook.sheet_names.length + 1
      name = "Sheet#{index}"
      index += 1 while @workbook.sheet_names.include?(name)
      @workbook.add_sheet(name)
      sync_grid_visibility
      sync_frozen_panes
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
