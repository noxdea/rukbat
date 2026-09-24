# frozen_string_literal: true

require "set"

module Rukbat
  class Workbook
    MAX_ROWS = 1_048_576
    MAX_COLUMNS = 16_384
    MAX_SORT_CELLS = 100_000
    MAX_FORMAT_CELLS = 100_000
    MAX_HIDDEN_CELLS = 100_000
    MAX_FILTER_ROWS = 100_000
    MAX_PIVOT_ROWS = 100_000
    MAX_PIVOT_GROUPS = 10_000
    MAX_CONDITIONAL_FORMATS = 256
    MAX_INPUT_VALIDATIONS = 256
    FORMAT_KEYS = %i[number_format font_family font_size bold italic color background border_color border_width horizontal_alignment vertical_alignment].freeze
    CONDITIONAL_OPERATORS = %i[greater_than greater_than_or_equal less_than less_than_or_equal equal not_equal contains].freeze
    COLORS = {black: "#000000", blue: "#0000FF", cyan: "#00FFFF", green: "#008000",
      magenta: "#FF00FF", red: "#FF0000", white: "#FFFFFF", yellow: "#FFFF00"}.freeze

    Summary = Data.define(:count, :numeric_count, :sum, :min, :max, :average, :types)
    CellRange = Data.define(:top, :left, :bottom, :right) do
      def include?(row, column)
        row.between?(top, bottom) && column.between?(left, right)
      end
    end
    InputValidation = Data.define(:area, :minimum, :maximum)
    PivotTable = Data.define(:source_area, :row_key_column, :value_column, :aggregate, :headers, :rows)

    attr_reader :active_sheet

    def self.from_rows(rows, sheet: "Sheet1")
      workbook = new(sheet: sheet)
      workbook.__send__(:load_rows, rows, sheet)
      workbook
    end

    def initialize(sheet: "Sheet1")
      name = validate_name(sheet)
      @sheets = {name => Denebola::Sheet.new}
      @calculated = {name => Denebola::Sheet.new}
      @active_sheet = name
      @history = []
      @redo = []
      @names = {}
      @formats = {}
      @comments = {}
      @conditional_formats = [].freeze
      @hidden_rows = {}.freeze
      @hidden_columns = {}.freeze
      @frozen_panes = {name => {rows: 1, columns: 1}.freeze}.freeze
      @print_areas = {}.freeze
      @input_validations = [].freeze
      @change_observers = []
      @source = CellSource.new(self)
      @engine = Furud::Engine.new(@source)
      @source_path = nil
      @source_digest = :absent
    end

    def sheet_names = @sheets.keys.freeze

    def on_cells_changed(&observer)
      raise ArgumentError, "a change observer is required" unless observer

      @change_observers << observer
      observer
    end

    def remove_cells_changed_observer(observer)
      @change_observers.delete(observer)
    end

    def sheet(name = @active_sheet)
      @sheets.fetch(name.to_s) { raise Error, "unknown sheet: #{name}" }
    end

    def activate(name)
      name = name.to_s
      sheet(name)
      @active_sheet = name
    end

    def add_sheet(name)
      name = validate_name(name)
      raise Error, "sheet already exists: #{name}" if @sheets.key?(name)

      record_history
      @sheets = @sheets.merge(name => Denebola::Sheet.new)
      @frozen_panes = @frozen_panes.merge(name => {rows: 1, columns: 1}.freeze).freeze
      rebuild_engine
      @active_sheet = name
      notify_cells_changed(nil)
    end

    def remove_sheet(name)
      name = name.to_s
      raise Error, "cannot remove the last sheet" if @sheets.length == 1
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)
      raise Error, "cannot remove referenced sheet: #{name}" if @names.values.any? { |area| area.sheet == name }
      raise Error, "cannot remove referenced sheet: #{name}" if sheet_referenced?(name)

      record_history
      @sheets = @sheets.reject { |key, _| key == name }
      @formats = @formats.reject { |(sheet_name, _row, _column), _style| sheet_name == name }.freeze
      @comments = @comments.reject { |(sheet_name, _row, _column), _text| sheet_name == name }.freeze
      @conditional_formats = @conditional_formats.reject { |rule| rule[:area].sheet == name }.freeze
      @input_validations = @input_validations.reject { |rule| rule.area.sheet == name }.freeze
      @hidden_rows = @hidden_rows.reject { |sheet_name, _| sheet_name == name }.freeze
      @hidden_columns = @hidden_columns.reject { |sheet_name, _| sheet_name == name }.freeze
      @frozen_panes = @frozen_panes.reject { |sheet_name, _| sheet_name == name }.freeze
      @print_areas = @print_areas.reject { |sheet_name, _| sheet_name == name }.freeze
      @active_sheet = @sheets.keys.first if @active_sheet == name
      rebuild_engine
      notify_cells_changed(nil)
      self
    end

    def [](row, column, sheet: @active_sheet)
      @engine.value(reference(row, column, sheet))
    end

    def input_at(row, column, sheet: @active_sheet)
      name = sheet || @active_sheet
      return nil unless @sheets.key?(name.to_s)
      return nil unless row.is_a?(Integer) && column.is_a?(Integer) && row.between?(1, MAX_ROWS) && column.between?(1, MAX_COLUMNS)

      @sheets.fetch(name.to_s)[row - 1, column - 1]
    end

    def formula(row, column, sheet: @active_sheet)
      @engine.formula(reference(row, column, sheet))
    end

    def set(row, column, value, sheet: @active_sheet)
      ref = reference(row, column, sheet)
      current = input_at(row, column, sheet: ref.sheet)
      return clear(row, column, sheet: ref.sheet) if value.nil?

      validate_formula(value, ref)
      if current == value
        validate_input_values!([ref])
        return self
      end

      updated = update_sheet(@sheets.fetch(ref.sheet), [[row - 1, column - 1, value]])
      @engine.set(ref, value)
      changed = @engine.recalculate
      begin
        validate_input_values!([ref, *changed])
      rescue Error
        rebuild_engine
        raise
      end
      record_history
      @sheets[ref.sheet] = updated
      update_calculated(changed)
      notify_cells_changed(ref.sheet, [[ref.row, ref.column].freeze])
      self
    end

    def set_many(changes, sheet: @active_sheet)
      entries = changes.map do |change|
        raise Error, "each cell change must contain row, column, and value" unless change.respond_to?(:length) && change.length == 3

        row, column, value = change
        [reference(row, column, sheet), value]
      end
      return self if entries.empty?

      ref = entries.first.first
      values = entries.to_h { |cell, value| [[cell.row, cell.column], [cell, value]] }
      current = @sheets.fetch(ref.sheet)
      changes_to_apply = values.filter_map do |(row, column), (cell, value)|
        validate_formula(value, cell)
        [[row, column, value], cell, value] if current[row - 1, column - 1] != value
      end
      if changes_to_apply.empty?
        validate_input_values!(values.values.map(&:first))
        return self
      end

      updated = update_sheet(current, changes_to_apply.map do |(row, column, value), _cell, _input|
        [row - 1, column - 1, value]
      end)
      changes_to_apply.each do |_change, cell, value|
        if value.nil?
          @engine.clear(cell)
        else
          @engine.set(cell, value)
        end
      end
      changed = @engine.recalculate
      begin
        validate_input_values!([*changes_to_apply.map { |_change, cell, _value| cell }, *changed])
      rescue Error
        rebuild_engine
        raise
      end
      record_history
      @sheets[ref.sheet] = updated
      update_calculated(changed)
      notify_cells_changed(ref.sheet, changes_to_apply.map do |_change, cell, _value|
        [cell.row, cell.column].freeze
      end)
      self
    end

    def clear(row, column, sheet: @active_sheet)
      ref = reference(row, column, sheet)
      return self if input_at(row, column, sheet: ref.sheet).nil?

      @engine.clear(ref)
      changed = @engine.recalculate
      begin
        validate_input_values!([ref, *changed])
      rescue Error
        rebuild_engine
        raise
      end
      record_history
      @sheets[ref.sheet] = @sheets.fetch(ref.sheet).delete(row - 1, column - 1)
      update_calculated(changed)
      notify_cells_changed(ref.sheet, [[ref.row, ref.column].freeze])
      self
    end

    def set_whole_number_validation(top, left, bottom, right, minimum:, maximum:, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      minimum, maximum = strict_integer(minimum), strict_integer(maximum)
      raise Error, "minimum must not exceed maximum" if minimum > maximum

      area = Furud::Area.new(sheet: name, top: top, left: left, bottom: bottom, right: right)
      validation = InputValidation.new(area: area, minimum: minimum, maximum: maximum)
      updated = @input_validations.flat_map do |existing|
        existing.area.sheet == name ? subtract_input_validation(existing, top, left, bottom, right) : [existing]
      end
      updated << validation
      raise Error, "input validation limit exceeded" if updated.length > MAX_INPUT_VALIDATIONS
      return self if updated == @input_validations

      record_history
      @input_validations = updated.freeze
      self
    rescue ArgumentError, TypeError
      raise Error, "validation limits must be integers"
    end

    def clear_input_validation(top, left, bottom, right, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      updated = @input_validations.flat_map do |existing|
        existing.area.sheet == name ? subtract_input_validation(existing, top, left, bottom, right) : [existing]
      end
      raise Error, "input validation limit exceeded" if updated.length > MAX_INPUT_VALIDATIONS
      return self if updated == @input_validations

      record_history
      @input_validations = updated.freeze
      self
    end

    def input_validation_at(row, column, sheet: @active_sheet)
      ref = reference(row, column, sheet)
      @input_validations.find do |validation|
        area = validation.area
        area.sheet == ref.sheet && ref.row.between?(area.top, area.bottom) &&
          ref.column.between?(area.left, area.right)
      end
    end

    def each_in(top, left, bottom, right, sheet: @active_sheet, &block)
      return enum_for(__method__, top, left, bottom, right, sheet: sheet) unless block

      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      @calculated.fetch(name)
        .each_in(top - 1, left - 1, bottom - 1, right - 1) do |point, _value|
        ref = Furud::Reference.new(sheet: name, row: point.row + 1, column: point.column + 1)
        block.call(ref, @engine.value(ref))
      end
      self
    end

    def summary(top, left, bottom, right, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      values = @calculated.fetch(name)
        .summary(top - 1, left - 1, bottom - 1, right - 1)
      numeric_count = values.types.sum { |type, count| type <= Numeric ? count : 0 }
      Summary.new(count: values.count, numeric_count: numeric_count, sum: values.sum,
        min: values.min, max: values.max, average: numeric_count.zero? ? nil : values.sum.to_f / numeric_count,
        types: values.types)
    end

    def pivot_table(top, left, bottom, right, row_key_column:, value_column:, aggregate: :sum, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      row_key_column, value_column = strict_integer(row_key_column), strict_integer(value_column)
      width = right - left + 1
      raise Error, "pivot row-key column must be between 1 and #{width}" unless row_key_column.between?(1, width)
      raise Error, "pivot value column must be between 1 and #{width}" unless value_column.between?(1, width)
      raise Error, "pivot aggregate must be :sum or :count" unless %i[sum count].include?(aggregate)
      raise Error, "pivot source exceeds #{MAX_PIVOT_ROWS} data rows" if bottom - top > MAX_PIVOT_ROWS

      key_column, measure_column = left + row_key_column - 1, left + value_column - 1
      groups, keys = {}, []
      ((top + 1)..bottom).each do |row|
        key = @engine.value(Furud::Reference.new(sheet: name, row: row, column: key_column))
        value = @engine.value(Furud::Reference.new(sheet: name, row: row, column: measure_column))
        unless groups.key?(key)
          raise Error, "pivot exceeds #{MAX_PIVOT_GROUPS} groups" if groups.length >= MAX_PIVOT_GROUPS

          keys << (key.is_a?(String) ? key.dup.freeze : key)
          groups[key] = 0
        end
        if aggregate == :count
          groups[key] += 1 unless value.nil?
        elsif finite_pivot_number?(value)
          sum = groups[key] + value
          raise Error, "pivot sum is not finite" unless finite_pivot_number?(sum)

          groups[key] = sum
        end
      end

      key_header = @engine.value(Furud::Reference.new(sheet: name, row: top, column: key_column))
      value_header = @engine.value(Furud::Reference.new(sheet: name, row: top, column: measure_column))
      key_header = "Column #{row_key_column}" if key_header.nil? || key_header.to_s.empty?
      value_header = "Column #{value_column}" if value_header.nil? || value_header.to_s.empty?
      headers = [key_header.to_s, "#{aggregate.to_s.capitalize} of #{value_header}"].freeze
      rows = keys.map { |key| [key, groups.fetch(key)].freeze }.freeze
      area = Furud::Area.new(sheet: name, top: top, left: left, bottom: bottom, right: right)
      PivotTable.new(source_area: area, row_key_column: row_key_column,
        value_column: value_column, aggregate: aggregate, headers: headers, rows: rows)
    rescue ArgumentError, TypeError
      raise Error, "pivot columns must be integers"
    end

    def add_pivot_sheet(name, pivot)
      name = validate_name(name)
      raise Error, "sheet already exists: #{name}" if @sheets.key?(name)
      raise Error, "pivot must be a PivotTable" unless pivot.is_a?(PivotTable)
      raise Error, "pivot source area is invalid" unless pivot.source_area.is_a?(Furud::Area)
      raise Error, "unknown pivot source sheet: #{pivot.source_area.sheet}" unless @sheets.key?(pivot.source_area.sheet)
      range_coordinates(pivot.source_area.top, pivot.source_area.left,
        pivot.source_area.bottom, pivot.source_area.right, pivot.source_area.sheet)
      source_width = pivot.source_area.right - pivot.source_area.left + 1
      raise Error, "pivot columns are invalid" unless
        pivot.row_key_column.is_a?(Integer) && pivot.row_key_column.between?(1, source_width) &&
        pivot.value_column.is_a?(Integer) && pivot.value_column.between?(1, source_width) &&
        %i[sum count].include?(pivot.aggregate)
      raise Error, "pivot must have two headers and at most #{MAX_PIVOT_GROUPS} groups" unless
        pivot.headers.is_a?(Array) && pivot.headers.length == 2 && pivot.rows.is_a?(Array) &&
        pivot.rows.length <= MAX_PIVOT_GROUPS

      rows = pivot.rows.each_with_index.map do |row, index|
        raise Error, "pivot row #{index + 1} must contain a key and value" unless row.is_a?(Array) && row.length == 2

        [row[0], row[1]]
      end
      changes = pivot.headers.each_with_index.map { |value, column| [1, column + 1, value] }
      rows.each_with_index do |(key, value), index|
        changes << [index + 2, 1, key]
        changes << [index + 2, 2, value]
      end
      prepared = changes.map do |row, column, value|
        row, column = strict_integer(row), strict_integer(column)
        raise Error, "pivot output exceeds sheet limits" unless row.between?(1, MAX_ROWS) && column.between?(1, MAX_COLUMNS)

        ref = Furud::Reference.new(sheet: name, row: row, column: column)
        input = pivot_cell_input(value)
        validate_formula(input, ref)
        [row - 1, column - 1, input, ref]
      end
      updated = update_sheet(Denebola::Sheet.new, prepared.map { |row, column, value, _ref| [row, column, value] })
      previous_state = snapshot
      begin
        @sheets = @sheets.merge(name => updated)
        @calculated = @calculated.merge(name => Denebola::Sheet.new)
        @frozen_panes = @frozen_panes.merge(name => {rows: 1, columns: 1}.freeze).freeze
        prepared.each { |_row, _column, value, ref| @engine.set(ref, value) unless value.nil? }
        changed = @engine.recalculate
      rescue StandardError => error
        restore(previous_state)
        raise Error, "could not create pivot sheet: #{error.message}"
      end
      @history << previous_state
      @redo.clear
      update_calculated(changed)
      notify_cells_changed(nil)
      name
    end

    def define_name(name, top, left, bottom, right, sheet: @active_sheet)
      name = name.to_s
      ast = Furud::Formula.parse("=#{name}")
      raise Error, "invalid named range: #{name}" unless ast.type == :name

      top, left, bottom, right, sheet = range_coordinates(top, left, bottom, right, sheet)
      key = name.downcase
      area = Furud::Area.new(sheet: sheet, top: top, left: left, bottom: bottom, right: right)
      return area if @names[key] == area

      record_history
      @names = @names.merge(key => area).freeze
      @engine.define_name(name, area)
      update_calculated(@engine.recalculate)
      area
    rescue Furud::ParseError => error
      raise Error, "invalid named range: #{error.message}"
    end

    def find(query, top: 1, left: 1, bottom: MAX_ROWS, right: MAX_COLUMNS, sheet: @active_sheet)
      query = query.to_s.downcase
      raise Error, "search text must not be empty" if query.empty?

      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      matches = []
      @sheets.fetch(name).each_in(top - 1, left - 1, bottom - 1, right - 1) do |point, input|
        ref = Furud::Reference.new(sheet: name, row: point.row + 1, column: point.column + 1)
        value = @engine.value(ref)
        matches << ref if [input, value].compact.any? { |item| item.to_s.downcase.include?(query) }
      end
      matches.freeze
    end

    def filter_rows(top, bottom, by:, query:, sheet: @active_sheet)
      by = strict_integer(by)
      top, by, bottom, by, name = range_coordinates(top, by, bottom, by, sheet)
      raise Error, "filter exceeds #{MAX_FILTER_ROWS} rows" if bottom - top + 1 > MAX_FILTER_ROWS
      query = query.to_s.downcase
      return (top..bottom).to_a.freeze if query.empty?

      (top..bottom).select do |row|
        value = @engine.value(Furud::Reference.new(sheet: name, row: row, column: by))
        value.to_s.downcase.include?(query)
      end.freeze
    rescue ArgumentError, TypeError
      raise Error, "filter column must be an integer"
    end

    def replace_all(query, replacement, top: 1, left: 1, bottom: MAX_ROWS, right: MAX_COLUMNS, sheet: @active_sheet)
      query = query.to_s
      raise Error, "search text must not be empty" if query.empty?

      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      changes = []
      @sheets.fetch(name).each_in(top - 1, left - 1, bottom - 1, right - 1) do |point, input|
        next unless input.is_a?(String) && input.include?(query)

        updated = input.gsub(query, replacement.to_s)
        changes << [point.row + 1, point.column + 1, updated] if updated != input
      end
      count = changes.length
      set_many(changes, sheet: name)
      count
    end

    def sort(top, left, bottom, right, by:, ascending: true, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      by = strict_integer(by)
      raise Error, "sort column must be within the selected range" unless by.between?(left, right)
      cells = (bottom - top + 1) * (right - left + 1)
      raise Error, "sort area exceeds #{MAX_SORT_CELLS} cells" if cells > MAX_SORT_CELLS

      width = right - left + 1
      rows = (top..bottom).map do |row|
        values = Array.new(width) { |offset| input_at(row, left + offset, sheet: name) }
        key = @engine.value(Furud::Reference.new(sheet: name, row: row, column: by))
        [row, values, key]
      end
      populated, blank = rows.partition { |_row, _values, key| !key.nil? }
      ordered = populated.sort do |a, b|
        comparison = sort_key(a[2]) <=> sort_key(b[2])
        comparison = -comparison if !ascending && comparison
        comparison.zero? ? a[0] <=> b[0] : comparison
      end + blank
      changes = ordered.each_with_index.flat_map do |(source_row, values, _key), offset|
        target_row = top + offset
        values.each_with_index.map do |value, column_offset|
          target_column = left + column_offset
          if value.is_a?(String) && value.start_with?("=")
            value = translate_formula(value,
              from: Furud::Reference.new(sheet: name, row: source_row, column: target_column),
              to: Furud::Reference.new(sheet: name, row: target_row, column: target_column))
          end
          [target_row, target_column, value]
        end
      end
      formats = sort_cell_metadata(@formats, ordered, top, left, right, name)
      comments = sort_cell_metadata(@comments, ordered, top, left, right, name)
      data_changed = changes.any? { |row, column, value| @sheets.fetch(name)[row - 1, column - 1] != value }
      metadata_changed = formats != @formats || comments != @comments
      return self unless data_changed || metadata_changed

      record_history unless data_changed
      set_many(changes, sheet: name) if data_changed
      @formats, @comments = formats, comments
      notify_cells_changed(name)
      self
    rescue ArgumentError, TypeError
      raise Error, "sort column must be an integer"
    end

    def remove_duplicates(top, left, bottom, right, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      cells = (bottom - top + 1) * (right - left + 1)
      raise Error, "duplicate check exceeds #{MAX_SORT_CELLS} cells" if cells > MAX_SORT_CELLS

      seen, duplicates = {}, []
      (top..bottom).each do |row|
        key = (left..right).map do |column|
          @engine.value(Furud::Reference.new(sheet: name, row: row, column: column))
        end.freeze
        duplicates << row if seen.key?(key)
        seen[key] = true
      end
      return 0 if duplicates.empty?

      runs = duplicates.reverse.chunk_while { |previous, current| current == previous - 1 }
        .map { |run| [run.last, run.length] }
      named_ranges = @names.values
      runs.each do |at, count|
        preflight_structural_edit(:delete_rows, at, count, name, MAX_ROWS)
        adjustment = Furud::Adjustment.new(type: :delete_rows, sheet: name, at: at, count: count)
        named_ranges = named_ranges.map { |area| area.sheet == name ? adjusted_area(area, adjustment) : area }
        raise Error, "cannot delete an entire named range" if named_ranges.any?(&:nil?)
      end
      previous_state = snapshot
      runs.each do |at, count|
        @engine.delete_rows(name, at, count)
        @sheets[name] = @sheets.fetch(name).delete_rows(at - 1, count)
        calculated = @calculated.fetch(name)
        @calculated[name] = calculated.delete_rows(at - 1, count) if at - 1 <= calculated.row_count
        adjust_metadata(:delete_rows, at, count, name)
      end
      sync_formula_inputs
      changed = @engine.recalculate
      begin
        validate_input_values!(changed)
      rescue Error
        restore(previous_state)
        raise
      end
      @history << previous_state
      @redo.clear
      update_calculated(changed)
      notify_cells_changed(name)
      duplicates.length
    end

    def translate_formula(value, from:, to:)
      return value unless value.is_a?(String) && value.start_with?("=")

      ast = Furud::Formula.parse(value, origin: from)
      invalid_reference = false
      Furud::Formula.visit(ast) do |node|
        next unless %i[reference qualified_reference].include?(node.type)

        reference = node.value
        row = reference.absolute_row ? reference.row : to.row + reference.row - from.row
        column = reference.absolute_column ? reference.column : to.column + reference.column - from.column
        invalid_reference ||= !row.between?(1, MAX_ROWS) || !column.between?(1, MAX_COLUMNS)
      end
      return "=#REF!" if invalid_reference

      translated = Furud::Formula.translate(ast, from: from, to: to)
      invalid_reference = Furud::Formula.references(translated).any? do |reference|
        if reference.is_a?(Furud::Reference)
          !reference.row.between?(1, MAX_ROWS) || !reference.column.between?(1, MAX_COLUMNS)
        else
          reference.top < 1 || reference.left < 1 || reference.bottom > MAX_ROWS || reference.right > MAX_COLUMNS
        end
      end
      invalid_reference ? "=#REF!" : Furud::Formula.render(translated, origin: to)
    rescue Furud::ParseError, ArgumentError
      value
    end

    def format_range(top, left, bottom, right, sheet: @active_sheet, **properties)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      cells = (bottom - top + 1) * (right - left + 1)
      raise Error, "format area exceeds #{MAX_FORMAT_CELLS} cells" if cells > MAX_FORMAT_CELLS

      style = normalize_format(properties)
      updated = @formats.dup
      (top..bottom).each do |row|
        (left..right).each do |column|
          key = [name, row, column].freeze
          value = updated.fetch(key, {}).merge(style).reject { |_key, entry| entry.nil? }
          value.empty? ? updated.delete(key) : updated[key] = value.freeze
        end
      end
      return self if updated == @formats

      record_history
      @formats = updated.freeze
      notify_cells_changed(name, CellRange.new(top: top, left: left, bottom: bottom, right: right))
      self
    end

    def format_at(row, column, sheet: @active_sheet)
      ref = reference(row, column, sheet)
      @formats.fetch([ref.sheet, ref.row, ref.column], {})
    end

    def presentation_at(row, column, sheet: @active_sheet)
      value = self[row, column, sheet: sheet]
      format = format_at(row, column, sheet: sheet)
      text, number_style = Furud::Format.apply(value,
        Furud::Format.parse(format.fetch(:number_format, "General")))
      style = format.merge(conditional_style_at(row, column, value, sheet: sheet))
      section_color = COLORS[number_style[:color]]
      style = style.merge(color: section_color) if section_color && !style.key?(:color)
      [text, style.freeze]
    end

    def set_comment(row, column, text, sheet: @active_sheet)
      ref = reference(row, column, sheet)
      raise Error, "comment must be a String or nil" unless text.nil? || text.is_a?(String)
      raise Error, "comment exceeds 5,000 characters" if text && text.length > 5_000

      key = [ref.sheet, ref.row, ref.column].freeze
      updated = @comments.dup
      text.nil? || text.empty? ? updated.delete(key) : updated[key] = text.dup.freeze
      return self if updated == @comments

      record_history
      @comments = updated.freeze
      notify_cells_changed(ref.sheet, [[ref.row, ref.column].freeze])
      self
    end

    def comment_at(row, column, sheet: @active_sheet)
      ref = reference(row, column, sheet)
      @comments[[ref.sheet, ref.row, ref.column]]
    end

    def add_conditional_format(top, left, bottom, right, operator:, value:, style:, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      operator = operator.to_sym if operator.is_a?(String) || operator.is_a?(Symbol)
      raise Error, "unsupported conditional format operator" unless CONDITIONAL_OPERATORS.include?(operator)
      raise Error, "conditional format style must be a Hash" unless style.is_a?(Hash)

      rule = {area: Furud::Area.new(sheet: name, top: top, left: left, bottom: bottom, right: right),
        operator: operator, value: value.is_a?(String) ? value.dup.freeze : value,
        style: normalize_format(style)}.freeze
      return self if @conditional_formats.include?(rule)
      raise Error, "conditional format limit exceeded" if @conditional_formats.length >= MAX_CONDITIONAL_FORMATS

      record_history
      @conditional_formats = (@conditional_formats + [rule]).freeze
      notify_cells_changed(name)
      self
    end

    def clear_conditional_formats(sheet: @active_sheet)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)
      updated = @conditional_formats.reject { |rule| rule[:area].sheet == name }
      return self if updated.length == @conditional_formats.length

      record_history
      @conditional_formats = updated.freeze
      notify_cells_changed(name)
      self
    end

    def hide_rows(top, bottom = top, hidden: true, sheet: @active_sheet)
      set_hidden_axis(:rows, top, bottom, hidden, sheet)
    end

    def hide_columns(left, right = left, hidden: true, sheet: @active_sheet)
      set_hidden_axis(:columns, left, right, hidden, sheet)
    end

    def row_hidden?(row, sheet: @active_sheet)
      ref = reference(row, 1, sheet)
      @hidden_rows.fetch(ref.sheet, Set.new).include?(ref.row)
    end

    def hidden_rows(sheet: @active_sheet)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)

      @hidden_rows.fetch(name, Set.new).to_a.sort.freeze
    end

    def column_hidden?(column, sheet: @active_sheet)
      ref = reference(1, column, sheet)
      @hidden_columns.fetch(ref.sheet, Set.new).include?(ref.column)
    end

    def hidden_columns(sheet: @active_sheet)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)

      @hidden_columns.fetch(name, Set.new).to_a.sort.freeze
    end

    def clear_hidden(axis, sheet: @active_sheet)
      state = {rows: @hidden_rows, columns: @hidden_columns}.fetch(axis)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)
      return self unless state.key?(name)

      record_history
      axis == :rows ? @hidden_rows = state.reject { |key, _| key == name }.freeze :
        @hidden_columns = state.reject { |key, _| key == name }.freeze
      self
    rescue KeyError
      raise Error, "hidden axis must be rows or columns"
    end

    def set_frozen_panes(rows:, columns:, sheet: @active_sheet)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)
      rows, columns = strict_integer(rows), strict_integer(columns)
      unless rows.between?(0, MAX_ROWS + 1) && columns.between?(0, MAX_COLUMNS + 1)
        raise Error, "frozen pane counts are outside sheet limits"
      end

      panes = {rows: rows, columns: columns}.freeze
      return self if @frozen_panes[name] == panes

      record_history
      @frozen_panes = @frozen_panes.merge(name => panes).freeze
      self
    rescue ArgumentError, TypeError
      raise Error, "frozen pane counts must be integers"
    end

    def frozen_panes(sheet: @active_sheet)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)

      panes = @frozen_panes.fetch(name, {rows: 1, columns: 1})
      [panes[:rows], panes[:columns]].freeze
    end

    def set_print_area(top, left, bottom, right, sheet: @active_sheet)
      top, left, bottom, right, name = range_coordinates(top, left, bottom, right, sheet)
      area = Furud::Area.new(sheet: name, top: top, left: left, bottom: bottom, right: right)
      return area if @print_areas[name] == area

      record_history
      @print_areas = @print_areas.merge(name => area).freeze
      area
    end

    def clear_print_area(sheet: @active_sheet)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)
      return self unless @print_areas.key?(name)

      record_history
      @print_areas = @print_areas.reject { |sheet_name, _| sheet_name == name }.freeze
      self
    end

    def print_area(sheet: @active_sheet)
      name = sheet.to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)

      @print_areas[name]
    end

    def insert_rows(at, count = 1, sheet: @active_sheet)
      structural_edit(:insert_rows, at, count, sheet)
    end

    def delete_rows(at, count = 1, sheet: @active_sheet)
      structural_edit(:delete_rows, at, count, sheet)
    end

    def insert_columns(at, count = 1, sheet: @active_sheet)
      structural_edit(:insert_columns, at, count, sheet)
    end

    def delete_columns(at, count = 1, sheet: @active_sheet)
      structural_edit(:delete_columns, at, count, sheet)
    end

    def undo
      return false if @history.empty?

      @redo << snapshot
      restore(@history.pop)
      notify_cells_changed(nil)
      true
    end

    def redo
      return false if @redo.empty?

      @history << snapshot
      restore(@redo.pop)
      notify_cells_changed(nil)
      true
    end

    def source_digest_for(path)
      File.expand_path(path) == @source_path ? @source_digest : :absent
    end

    private

    def bind_source(path, digest)
      @source_path, @source_digest = File.expand_path(path).freeze, digest
    end

    def reference(row, column, name)
      row = strict_integer(row)
      column = strict_integer(column)
      name = name.to_s
      raise Error, "row must be between 1 and #{MAX_ROWS}" unless row.between?(1, MAX_ROWS)
      raise Error, "column must be between 1 and #{MAX_COLUMNS}" unless column.between?(1, MAX_COLUMNS)
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)

      Furud::Reference.new(sheet: name, row: row, column: column)
    rescue ArgumentError, TypeError
      raise Error, "row and column must be integers"
    end

    def validate_input_values!(references)
      references.uniq.each do |ref|
        validation = input_validation_at(ref.row, ref.column, sheet: ref.sheet)
        next unless validation

        value = @engine.value(ref)
        next if value.nil?

        whole_number = value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.to_i)
        next if whole_number && value >= validation.minimum && value <= validation.maximum

        address = "#{Furud::Formula.column_name(ref.column)}#{ref.row}"
        raise Error, "#{address} must be a whole number between #{validation.minimum} and #{validation.maximum}"
      end
    end

    def finite_pivot_number?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex) && (!value.respond_to?(:finite?) || value.finite?)
    end

    def pivot_cell_input(value)
      case value
      when String
        value.start_with?("=") ? "=#{Furud::Formula.render_literal(value)}" : value
      when Float
        value.finite? ? value : value.to_s
      when Complex
        value.to_s
      when NilClass, TrueClass, FalseClass, Numeric, Furud::ErrorValue
        value
      else
        value.to_s
      end
    rescue StandardError => error
      raise Error, "pivot value cannot be written: #{error.message}"
    end

    def subtract_input_validation(validation, top, left, bottom, right)
      area = validation.area
      intersect_top, intersect_left = [area.top, top].max, [area.left, left].max
      intersect_bottom, intersect_right = [area.bottom, bottom].min, [area.right, right].min
      return [validation] if intersect_top > intersect_bottom || intersect_left > intersect_right

      ranges = []
      ranges << [area.top, area.left, intersect_top - 1, area.right] if area.top < intersect_top
      ranges << [intersect_bottom + 1, area.left, area.bottom, area.right] if intersect_bottom < area.bottom
      ranges << [intersect_top, area.left, intersect_bottom, intersect_left - 1] if area.left < intersect_left
      ranges << [intersect_top, intersect_right + 1, intersect_bottom, area.right] if intersect_right < area.right
      ranges.map do |range_top, range_left, range_bottom, range_right|
        InputValidation.new(
          area: Furud::Area.new(sheet: area.sheet, top: range_top, left: range_left,
            bottom: range_bottom, right: range_right),
          minimum: validation.minimum, maximum: validation.maximum
        )
      end
    end

    def range_coordinates(top, left, bottom, right, name)
      top, left, bottom, right = [top, left, bottom, right].map { |value| strict_integer(value) }
      name = (name || @active_sheet).to_s
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)
      raise Error, "range coordinates are outside sheet limits" unless top.between?(1, MAX_ROWS) && bottom.between?(top, MAX_ROWS) && left.between?(1, MAX_COLUMNS) && right.between?(left, MAX_COLUMNS)

      [top, left, bottom, right, name]
    rescue ArgumentError, TypeError
      raise Error, "range coordinates must be integers"
    end

    def validate_name(value)
      name = value.to_s
      raise Error, "sheet name must not be empty" if name.empty?
      raise Error, "sheet name must be at most 31 characters" if name.length > 31
      raise Error, "sheet name contains an invalid character" if name.match?(/[\\\/?*\[\]:]/)

      name.freeze
    end

    def structural_edit(type, at, count, name)
      at, count, name = strict_integer(at), strict_integer(count), name.to_s
      raise Error, "count must be positive" unless count.positive?
      raise Error, "unknown sheet: #{name}" unless @sheets.key?(name)
      extent = type.to_s.end_with?("rows") ? MAX_ROWS : MAX_COLUMNS
      raise Error, "insertion exceeds sheet limit" if type.to_s.start_with?("insert") && at + count - 1 > extent
      raise Error, "deletion exceeds sheet limit" if type.to_s.start_with?("delete") && at + count - 1 > extent
      raise Error, "index is outside sheet limits" unless at.between?(1, extent)
      preflight_structural_edit(type, at, count, name, extent)

      previous_state = snapshot
      @engine.public_send(type, name, at, count)
      denebola_at = at - 1
      current = @sheets.fetch(name)
      extent = type.to_s.end_with?("rows") ? current.row_count : current.column_count
      @sheets[name] = current.public_send(type, denebola_at, count) if denebola_at <= extent
      calculated = @calculated.fetch(name)
      calculated_extent = type.to_s.end_with?("rows") ? calculated.row_count : calculated.column_count
      @calculated[name] = calculated.public_send(type, denebola_at, count) if denebola_at <= calculated_extent
      adjust_metadata(type, at, count, name)
      sync_formula_inputs
      changed = @engine.recalculate
      begin
        validate_input_values!(changed)
      rescue Error
        restore(previous_state)
        raise
      end
      @history << previous_state
      @redo.clear
      update_calculated(changed)
      notify_cells_changed(name)
      self
    rescue ArgumentError, TypeError
      raise Error, "index and count must be integers"
    end

    def strict_integer(value)
      return value if value.is_a?(Integer)
      return Integer(value, 10) if value.is_a?(String) && value.match?(/\A[+-]?\d+\z/)

      raise ArgumentError, "expected an integer"
    end

    def sync_formula_inputs
      @sheets.each do |name, current|
        changes = []
        current.each_in(0, 0, current.row_count - 1, current.column_count - 1) do |point, input|
          next unless input.is_a?(String) && input.start_with?("=")

          new_formula = @engine.formula(Furud::Reference.new(sheet: name, row: point.row + 1, column: point.column + 1))
          changes << [point.row, point.column, new_formula] if new_formula && new_formula != input
        end if current.row_count.positive? && current.column_count.positive?
        @sheets[name] = update_sheet(current, changes) unless changes.empty?
      end
    end

    def record_history
      @history << snapshot
      @redo.clear
    end

    def snapshot = [@sheets.dup, @active_sheet, @names.dup, @formats.dup, @comments.dup,
      @conditional_formats.dup, @hidden_rows.dup, @hidden_columns.dup, @frozen_panes.dup, @print_areas.dup,
      @input_validations.dup]

    def restore(state)
      @sheets, @active_sheet, @names, @formats, @comments, @conditional_formats, @hidden_rows,
        @hidden_columns, @frozen_panes, @print_areas, @input_validations = state
      rebuild_engine
    end

    def rebuild_engine
      @engine = Furud::Engine.new(@source)
      @names.each { |name, area| @engine.define_name(name, area) }
      @calculated = @sheets.to_h { |name, _sheet| [name, Denebola::Sheet.new] }
      @sheets.each do |name, current|
        next if current.row_count.zero? || current.column_count.zero?

        current.each_in(0, 0, current.row_count - 1, current.column_count - 1) do |point, value|
          @engine.set(Furud::Reference.new(sheet: name, row: point.row + 1, column: point.column + 1), value)
        end
      end
      update_calculated(@engine.recalculate)
    end

    def load_rows(rows, name)
      changes = []
      rows.each_with_index do |row, row_index|
        raise Error, "CSV exceeds sheet row limit" if row_index >= MAX_ROWS
        row.each_with_index do |value, column_index|
          raise Error, "CSV exceeds sheet column limit" if column_index >= MAX_COLUMNS
          next if value.nil?

          ref = Furud::Reference.new(sheet: name, row: row_index + 1, column: column_index + 1)
          validate_formula(value, ref)
          changes << [row_index, column_index, value]
        end
      end
      current = @sheets.fetch(name)
      @sheets[name] = update_sheet(current, changes) unless changes.empty?
      changes.each do |row, column, value|
        @engine.set(Furud::Reference.new(sheet: name, row: row + 1, column: column + 1), value)
      end
      update_calculated(@engine.recalculate)
    end

    def update_calculated(references)
      changes = references.group_by(&:sheet)
      changes.each do |name, refs|
        current = @calculated[name]
        next unless current

        edits = refs.map do |ref|
          value = @engine.value(ref)
          [ref.row - 1, ref.column - 1, value]
        end
        @calculated[name] = update_sheet(current, edits)
        notify_cells_changed(name, refs.map { |ref| [ref.row, ref.column].freeze })
      end
    end

    def notify_cells_changed(sheet, cells = nil)
      @change_observers.dup.each { |observer| observer.call(sheet, cells) }
    end

    def update_sheet(current, changes)
      return current if changes.empty?
      return current.set_many(changes) if current.respond_to?(:set_many)

      changes.reduce(current) do |sheet, (row, column, value)|
        value.nil? ? sheet.delete(row, column) : sheet.set(row, column, value)
      end
    end

    def validate_formula(value, reference)
      Furud::Formula.parse(value, origin: reference) if value.is_a?(String) && value.start_with?("=")
    rescue Furud::ParseError => error
      raise Error, "invalid formula: #{error.message}"
    end

    def sheet_referenced?(name)
      @sheets.any? do |sheet_name, current|
        next false if current.row_count.zero? || current.column_count.zero?

        referenced = false
        current.each_in(0, 0, current.row_count - 1, current.column_count - 1) do |point, value|
          next unless value.is_a?(String) && value.start_with?("=")

          formula_ref = Furud::Reference.new(sheet: sheet_name, row: point.row + 1, column: point.column + 1)
          referenced ||= Furud::Formula.references(Furud::Formula.parse(value, origin: formula_ref)).any? do |reference|
            reference.sheet == name
          end
          break if referenced
        end
        referenced
      end
    end

    def preflight_structural_edit(type, at, count, name, limit)
      current = @sheets.fetch(name)
      calculated = @calculated.fetch(name)
      occupied_extent = type.to_s.end_with?("rows") ? [current.row_count, calculated.row_count].max : [current.column_count, calculated.column_count].max
      metadata_extent = [@formats, @comments].flat_map do |entries|
        entries.keys.filter_map do |sheet_name, row, column|
          next unless sheet_name == name
          type.to_s.end_with?("rows") ? row : column
        end
      end.max || 0
      area_extent = (@names.values + @conditional_formats.map { |rule| rule[:area] }).filter_map do |area|
        next unless area.sheet == name
        type.to_s.end_with?("rows") ? area.bottom : area.right
      end.max || 0
      validation_extent = @input_validations.filter_map do |rule|
        area = rule.area
        next unless area.sheet == name
        type.to_s.end_with?("rows") ? area.bottom : area.right
      end.max || 0
      print_extent = @print_areas.values.filter_map do |area|
        next unless area.sheet == name
        type.to_s.end_with?("rows") ? area.bottom : area.right
      end.max || 0
      area_extent = [area_extent, print_extent, validation_extent].max
      hidden_extent = (type.to_s.end_with?("rows") ? @hidden_rows : @hidden_columns)
        .fetch(name, Set.new).max || 0
      panes = @frozen_panes.fetch(name, {rows: 1, columns: 1})
      frozen_extent = panes.fetch(type.to_s.end_with?("rows") ? :rows : :columns) - 1
      occupied_extent = [occupied_extent, metadata_extent, area_extent, hidden_extent, frozen_extent].max

      if type.to_s.start_with?("delete")
        operation = Furud::Adjustment.new(type: type, sheet: name, at: at, count: count)
        if @names.values.any? { |area| area.sheet == name && adjusted_area(area, operation).nil? }
          raise Error, "cannot delete an entire named range"
        end
        return
      end

      return unless at - 1 < occupied_extent
      raise Error, "insertion exceeds sheet limit" if occupied_extent + count > limit
    end

    def normalize_format(properties)
      unknown = properties.keys.map(&:to_sym) - FORMAT_KEYS
      raise Error, "unsupported cell format: #{unknown.first}" unless unknown.empty?

      properties.to_h do |key, value|
        key = key.to_sym
        case key
        when :number_format
          raise Error, "number format must be a String or nil" unless value.nil? || (value.is_a?(String) && value.length <= 128)
        when :font_family
          raise Error, "font family must be a nonempty String or nil" unless value.nil? || (value.is_a?(String) && !value.empty? && value.length <= 100)
        when :font_size
          raise Error, "font size must be between 6 and 72" unless value.nil? || (value.is_a?(Numeric) && !value.is_a?(Complex) && value.finite? && value.between?(6, 72))
          value = value&.to_f
        when :bold, :italic
          raise Error, "#{key} must be true, false, or nil" unless value.nil? || value == true || value == false
        when :color, :background, :border_color
          raise Error, "#{key} must be a six-digit hex color or nil" unless value.nil? || (value.is_a?(String) && value.match?(/\A#[0-9a-fA-F]{6}\z/))
        when :border_width
          raise Error, "border width must be between 0 and 4" unless value.nil? || (value.is_a?(Numeric) && !value.is_a?(Complex) && value.finite? && value.between?(0, 4))
          value = value&.to_f
        when :horizontal_alignment
          raise Error, "horizontal alignment must be left, center, right, or nil" unless value.nil? || ((value.is_a?(String) || value.is_a?(Symbol)) && %i[left center right].include?(value.to_sym))
          value = value&.to_sym
        when :vertical_alignment
          raise Error, "vertical alignment must be top, middle, bottom, or nil" unless value.nil? || ((value.is_a?(String) || value.is_a?(Symbol)) && %i[top middle bottom].include?(value.to_sym))
          value = value&.to_sym
        end
        [key, value.is_a?(String) ? value.dup.freeze : value]
      end.freeze
    end

    def conditional_style_at(row, column, value, sheet:)
      @conditional_formats.each_with_object({}) do |rule, style|
        area = rule[:area]
        next unless area.sheet == sheet && row.between?(area.top, area.bottom) && column.between?(area.left, area.right)
        next unless conditional_match?(value, rule[:operator], rule[:value])

        style.merge!(rule[:style])
      end
    end

    def conditional_match?(value, operator, expected)
      return value.to_s.downcase.include?(expected.to_s.downcase) if operator == :contains
      return false if value.nil?
      return false if value.is_a?(Numeric) != expected.is_a?(Numeric) && !%i[equal not_equal].include?(operator)

      comparison = value <=> expected
      return comparison.nil? ? (operator == :not_equal && value != expected) :
        {greater_than: comparison.positive?, greater_than_or_equal: comparison >= 0,
         less_than: comparison.negative?, less_than_or_equal: comparison <= 0,
         equal: comparison.zero?, not_equal: !comparison.zero?}.fetch(operator)
    rescue ArgumentError, TypeError
      false
    end

    def adjust_metadata(type, at, count, sheet)
      @formats = move_cell_metadata(@formats, type, at, count, sheet).freeze
      @comments = move_cell_metadata(@comments, type, at, count, sheet).freeze
      @hidden_rows = move_hidden_indices(@hidden_rows, type, at, count, sheet, :rows).freeze
      @hidden_columns = move_hidden_indices(@hidden_columns, type, at, count, sheet, :columns).freeze
      operation = Furud::Adjustment.new(type: type, sheet: sheet, at: at, count: count)
      @names = @names.to_h do |name, area|
        [name, area.sheet == sheet ? adjusted_area(area, operation) : area]
      end.freeze
      @conditional_formats = @conditional_formats.filter_map do |rule|
        area = adjusted_area(rule[:area], operation)
        area && rule.merge(area: area).freeze
      end.freeze
      @input_validations = @input_validations.filter_map do |validation|
        area = adjusted_area(validation.area, operation)
        InputValidation.new(area: area, minimum: validation.minimum, maximum: validation.maximum) if area
      end.freeze
      @print_areas = @print_areas.filter_map do |sheet_name, area|
        adjusted = sheet_name == sheet ? adjusted_area(area, operation) : area
        [sheet_name, adjusted] if adjusted
      end.to_h.freeze
      panes = @frozen_panes.fetch(sheet, {rows: 1, columns: 1})
      axis = type.to_s.end_with?("rows") ? :rows : :columns
      @frozen_panes = @frozen_panes.merge(sheet => panes.merge(axis => adjust_frozen_count(panes.fetch(axis), type, at, count)).freeze).freeze
      @names.each { |name, area| @engine.define_name(name, area) }
    end

    def adjust_frozen_count(frozen_count, type, at, count)
      frozen_cells = frozen_count - 1 # Grid row/column zero is the header.
      if type.to_s.start_with?("insert")
        at <= frozen_cells ? frozen_count + count : frozen_count
      elsif at <= frozen_cells
        frozen_count - [frozen_cells - at + 1, count].min
      else
        frozen_count
      end
    end

    def move_hidden_indices(hidden, type, at, count, target_sheet, axis)
      insertion = type.to_s.start_with?("insert")
      hidden.to_h do |sheet_name, indices|
        moved = indices.filter_map do |index|
          next index unless sheet_name == target_sheet && ((axis == :rows) == type.to_s.end_with?("rows"))
          next index + count if insertion && index >= at
          next if !insertion && index.between?(at, at + count - 1)
          next index - count if !insertion && index > at + count - 1

          index
        end
        [sheet_name, moved.to_set.freeze]
      end
    end

    def set_hidden_axis(axis, first, last, hidden, sheet)
      raise Error, "hidden state must be boolean" unless hidden == true || hidden == false
      limit = axis == :rows ? MAX_ROWS : MAX_COLUMNS
      first, last = strict_integer(first), strict_integer(last)
      sheet = sheet.to_s
      raise Error, "unknown sheet: #{sheet}" unless @sheets.key?(sheet)
      raise Error, "hidden range is outside sheet limits" unless first.between?(1, limit) && last.between?(first, limit)
      raise Error, "hidden range exceeds #{MAX_HIDDEN_CELLS} entries" if last - first + 1 > MAX_HIDDEN_CELLS

      state = axis == :rows ? @hidden_rows : @hidden_columns
      indices = state.fetch(sheet, Set.new)
      updated_indices = indices.dup
      hidden ? (first..last).each { |index| updated_indices.add(index) } : (first..last).each { |index| updated_indices.delete(index) }
      return self if updated_indices == indices

      record_history
      updated = state.merge(sheet => updated_indices.freeze).freeze
      axis == :rows ? @hidden_rows = updated : @hidden_columns = updated
      self
    rescue ArgumentError, TypeError
      raise Error, "hidden range coordinates must be integers"
    end

    def move_cell_metadata(metadata, type, at, count, target_sheet)
      axis = type.to_s.end_with?("rows") ? 1 : 2
      insertion = type.to_s.start_with?("insert")
      deleted_end = at + count - 1
      metadata.each_with_object({}) do |((sheet_name, row, column), value), moved|
        coordinate = axis == 1 ? row : column
        if sheet_name == target_sheet
          if insertion
            coordinate += count if coordinate >= at
          elsif coordinate.between?(at, deleted_end)
            next
          elsif coordinate > deleted_end
            coordinate -= count
          end
        end
        key = axis == 1 ? [sheet_name, coordinate, column] : [sheet_name, row, coordinate]
        moved[key.freeze] = value
      end
    end

    def sort_cell_metadata(metadata, ordered, top, left, right, sheet)
      updated = metadata.reject do |(sheet_name, row, column), _value|
        sheet_name == sheet && row.between?(top, top + ordered.length - 1) && column.between?(left, right)
      end
      ordered.each_with_index do |(source_row, _values, _key), offset|
        target_row = top + offset
        (left..right).each do |column|
          value = metadata[[sheet, source_row, column]]
          updated[[sheet, target_row, column].freeze] = value if value
        end
      end
      updated.freeze
    end

    def adjusted_area(area, operation)
      return area unless area.sheet == operation.sheet

      axis = operation.type.to_s.end_with?("rows") ? :row : :column
      first = area.public_send(axis == :row ? :top : :left)
      last = area.public_send(axis == :row ? :bottom : :right)
      if operation.type.to_s.start_with?("insert")
        if operation.at <= first
          first += operation.count
          last += operation.count
        elsif operation.at <= last
          last += operation.count
        end
      else
        deleted_end = operation.at + operation.count - 1
        overlap = [last, deleted_end].min - [first, operation.at].max + 1
        if overlap >= last - first + 1
          return nil
        elsif overlap.positive?
          last -= overlap
          first = operation.at if first >= operation.at
        elsif first > deleted_end
          first -= operation.count
          last -= operation.count
        end
      end
      axis == :row ? Furud::Area.new(sheet: area.sheet, top: first, left: area.left, bottom: last, right: area.right) :
        Furud::Area.new(sheet: area.sheet, top: area.top, left: first, bottom: area.bottom, right: last)
    end

    def sort_key(value)
      case value
      when Numeric
        number = value.to_f unless value.is_a?(Complex)
        [number&.finite? ? 0 : 2, number&.finite? ? number : value.to_s.downcase]
      when Date, Time then [1, value.to_s]
      else [2, value.to_s.downcase]
      end
    end
  end
end
