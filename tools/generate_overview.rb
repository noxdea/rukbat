# frozen_string_literal: true

require "fileutils"
require "rukbat"

# Synthetic sales data rendered by the real editor's headless backend.
RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)
book = Rukbat::Workbook.from_rows([
  ["Quarter", "Online", "Retail", "Total"],
  ["Q1", 12_000, 8_000, "=SUM(B2:C2)"],
  ["Q2", 18_000, 9_000, "=SUM(B3:C3)"],
  ["Q3", 24_000, 11_000, "=SUM(B4:C4)"],
  ["Q4", 30_000, 14_000, "=SUM(B5:C5)"],
  ["Year", "=SUM(B2:B5)", "=SUM(C2:C5)", "=SUM(D2:D5)"]
])
raise "Example total is incorrect" unless book[6, 4] == 126_000

book.format_range(1, 1, 1, 4, bold: true, background: "#25364A", color: "#FFFFFF")
book.format_range(2, 2, 6, 4, number_format: "#,##0.00")
book.format_range(6, 1, 6, 4, bold: true, background: "#FFF2CC", color: "#20242C")
view = Rukbat::GridView.new(book)
app = Zaniah::App.new
window = app.open_window(backend: :headless, width: 1440, height: 860) { view }
begin
  window.text_system = Zaniah::TextSystem::Renderer.new
  view.grid.selection = [Zaniah::UI::Grid::Area.new(rows: 1...6, columns: 1...4)]
  view.__send__(:show_chart, :bar)
  view.instance_variable_set(:@active_cell, [6, 4])
  view.__send__(:sync_formula_field)
  view.__send__(:update_status)
  window.tick
  output = File.expand_path("../docs/media/overview.png", __dir__)
  FileUtils.mkdir_p(File.dirname(output))
  window.write_png(output)
  puts output
ensure
  window.close
  app.executor.shutdown
end
