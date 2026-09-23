# frozen_string_literal: true

module Rukbat
  class CellSource
    def initialize(workbook)
      @workbook = workbook
    end

    def value_at(reference)
      @workbook.input_at(reference.row, reference.column, sheet: reference.sheet)
    end

    def each_in(area)
      return enum_for(__method__, area) unless block_given?

      sheet_name = area.sheet || @workbook.active_sheet
      return self unless @workbook.sheet_names.include?(sheet_name)

      @workbook.sheet(sheet_name).each_in(area.top - 1, area.left - 1, area.bottom - 1, area.right - 1) do |point, value|
        yield Furud::Reference.new(sheet: sheet_name, row: point.row + 1, column: point.column + 1), value
      end
      self
    end
  end
end
