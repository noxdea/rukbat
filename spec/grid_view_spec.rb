# frozen_string_literal: true

RSpec.describe Rukbat::GridView do
  def area(rows, columns)
    Zaniah::UI::Grid::Area.new(rows: rows, columns: columns)
  end

  it "copies blank source cells over destination values" do
    workbook = Rukbat::Workbook.new
    workbook.set(1, 2, 9)
    view = described_class.new(workbook)

    view.__send__(:fill, area(1...2, 1...2), area(1...2, 1...3))

    expect(workbook.input_at(1, 2)).to be_nil
  end

  it "edits cells in place, keeps the formula bar synchronized, and commits with Enter" do
    workbook = Rukbat::Workbook.from_rows([["original", "=1+2"]])
    view = described_class.new(workbook)
    window = Zaniah::Platform::Headless::Window.new(width: 800, height: 600)
    window.on_input { |event| view.handle_shortcut(event, window) }
    context = Zaniah::FrameContext.new(window)
    view.request_layout(context)

    view.__send__(:begin_edit, 1, 1, context)
    view.request_layout(context)
    editor = view.__send__(:render_cell, 1, 1, Zaniah::Bounds.new(0, 0, 112, 24))
    expect(editor).to be_a(Zaniah::Text)
    expect(window.dispatcher.focused).to equal(editor.focus_handle)

    window.input(Zaniah::Input::TextInput.new(" updated"))
    expect(editor.buffer.to_s).to eq("original updated")
    expect(view.formula_field.value).to eq("original updated")
    window.input(Zaniah::Input::KeyDown.new("enter", false))

    expect(workbook.input_at(1, 1)).to eq("original updated")
    expect(view.formula_field.value).to eq("original updated")
    expect(view.instance_variable_get(:@editing_cell)).to be_nil

    view.__send__(:begin_edit, 1, 2, context)
    view.request_layout(context)
    editor = view.__send__(:render_cell, 1, 2, Zaniah::Bounds.new(112, 0, 112, 24))
    expect(editor.buffer.to_s).to eq("=1+2")
    window.input(Zaniah::Input::TextInput.new(" discarded"))
    window.input(Zaniah::Input::KeyDown.new("esc", false))

    expect(workbook.formula(1, 2)).to eq("=1+2")
    expect(view.formula_field.value).to eq("=1+2")
    expect(view.instance_variable_get(:@editing_cell)).to be_nil
  ensure
    window&.close
  end

  it "keeps an invalid inline edit selected instead of losing it on navigation" do
    workbook = Rukbat::Workbook.from_rows([["original", "other"]])
    view = described_class.new(workbook)
    window = Zaniah::Platform::Headless::Window.new(width: 800, height: 600)
    context = Zaniah::FrameContext.new(window)
    view.request_layout(context)
    original = area(1...2, 1...2)
    view.grid.selection = [original]
    view.__send__(:begin_edit, 1, 1, context)
    input = "=SUM("
    view.instance_variable_get(:@inline_buffer).replace(0..."original".bytesize, input)

    view.__send__(:selection_changed, [area(1...2, 2...3)], context)

    expect(view.grid.selection).to eq([original])
    expect(view.active_cell).to eq([1, 1])
    expect(view.instance_variable_get(:@editing_cell)).to eq([1, 1])
    expect(view.instance_variable_get(:@inline_buffer).to_s).to eq(input)
    expect(workbook.input_at(1, 1)).to eq("original")
  ensure
    window&.close
  end

  it "applies and clears whole-number rules for the selected range" do
    workbook = Rukbat::Workbook.new
    view = described_class.new(workbook)
    view.grid.selection = [area(2...4, 3...5)]
    view.validation_min_field.buffer.replace(0...0, "2")
    view.validation_max_field.buffer.replace(0...0, "8")

    expect(view.__send__(:apply_whole_number_validation)).to be(true)
    expect(workbook.input_validation_at(2, 3).minimum).to eq(2)
    expect(workbook.input_validation_at(3, 4).maximum).to eq(8)
    expect(workbook.input_validation_at(1, 3)).to be_nil

    view.grid.selection = [area(2...3, 3...4)]
    expect(view.__send__(:clear_input_validation)).to be(true)
    expect(workbook.input_validation_at(2, 3)).to be_nil
    expect(workbook.input_validation_at(3, 4).minimum).to eq(2)
  end

  it "keeps an invalid cell edit active and reports the validation error" do
    workbook = Rukbat::Workbook.from_rows([[5]])
    workbook.set_whole_number_validation(1, 1, 1, 1, minimum: 1, maximum: 9)
    view = described_class.new(workbook)
    window = Zaniah::Platform::Headless::Window.new(width: 800, height: 600)
    context = Zaniah::FrameContext.new(window)
    view.request_layout(context)

    view.__send__(:begin_edit, 1, 1, context)
    buffer = view.instance_variable_get(:@inline_buffer)
    buffer.replace(0...buffer.bytesize, "10")

    expect(view.__send__(:commit_inline_edit)).to be(false)
    expect(view.instance_variable_get(:@editing_cell)).to eq([1, 1])
    expect(workbook.input_at(1, 1)).to eq(5)
    expect(view.status).to include("A1", "1 and 9")
  ensure
    window&.close
  end

  it "creates a static pivot sheet from the selected range and supports undo" do
    workbook = Rukbat::Workbook.from_rows([
      ["Region", "Sales"], ["East", 10], ["West", 4], ["East", 6]
    ])
    view = described_class.new(workbook)
    view.grid.selection = [area(1...5, 1...3)]
    view.instance_variable_get(:@pivot_key_field).buffer.replace(0...1, "1")
    view.instance_variable_get(:@pivot_value_field).buffer.replace(0...1, "2")

    expect(view.__send__(:create_pivot_table)).to be(true)
    expect(workbook.sheet_names).to eq(["Sheet1", "Pivot"])
    expect(workbook.active_sheet).to eq("Sheet1")
    expect(workbook.input_at(1, 1, sheet: "Pivot")).to eq("Region")
    expect(workbook.input_at(1, 2, sheet: "Pivot")).to eq("Sum of Sales")
    expect(workbook.input_at(2, 1, sheet: "Pivot")).to eq("East")
    expect(workbook.input_at(2, 2, sheet: "Pivot")).to eq(16)
    expect(workbook.input_at(3, 2, sheet: "Pivot")).to eq(4)

    view.undo
    expect(workbook.sheet_names).to eq(["Sheet1"])
  end

  it "keeps leading-equals pivot keys as text in the generated sheet" do
    workbook = Rukbat::Workbook.from_rows([["Key", "Value"], ["placeholder", 3]])
    workbook.set(2, 1, '="=Group"')
    view = described_class.new(workbook)
    view.grid.selection = [area(1...3, 1...3)]

    expect(view.__send__(:create_pivot_table)).to be(true)
    expect(workbook[2, 1, sheet: "Pivot"]).to eq("=Group")
  end

  it "keeps pivot output as a static snapshot after source cells change" do
    workbook = Rukbat::Workbook.from_rows([["Key", "Value"], ["A", 3]])
    view = described_class.new(workbook)
    view.grid.selection = [area(1...3, 1...3)]

    expect(view.__send__(:create_pivot_table)).to be(true)
    workbook.set(2, 2, 99)

    expect(workbook[2, 2, sheet: "Pivot"]).to eq(3)
    expect(workbook[2, 2, sheet: "Sheet1"]).to eq(99)
  end

  it "writes #REF when formula translation leaves the grid" do
    workbook = Rukbat::Workbook.new
    workbook.set(1, 2, "=A1")
    view = described_class.new(workbook)

    view.__send__(:fill, area(1...2, 2...3), area(1...2, 1...3))

    expect(workbook.formula(1, 1)).to eq("=#REF!")
    expect(workbook[1, 1].to_s).to eq("#REF!")
  end

  it "rejects a fill above the cell limit before building changes and shows status" do
    workbook = Rukbat::Workbook.new
    workbook.set(1, 1, 5)
    view = described_class.new(workbook)
    expect(workbook).not_to receive(:set_many)

    result = view.__send__(:fill, area(1...2, 1...2), area(1...319, 1...317))

    expect(result).to be(false)
    expect(view.status).to include("#{described_class::MAX_FILL_CELLS} cells")
    expect(workbook.input_at(1, 2)).to be_nil
  end

  it "rerenders only cells whose calculated values changed" do
    workbook = Rukbat::Workbook.from_rows([["before", "=A1", "unchanged"]])
    view = described_class.new(workbook)
    window = Zaniah::Platform::Headless::Window.new(width: 800, height: 600)
    context = Zaniah::FrameContext.new(window)
    calls = []
    allow(workbook).to receive(:presentation_at).and_wrap_original do |original, row, column, **options|
      calls << [row, column]
      original.call(row, column, **options)
    end

    view.request_layout(context)
    calls.clear
    workbook.set(1, 1, "after")
    view.request_layout(context)

    expect(calls).to contain_exactly([1, 1], [1, 2])
    expect(view.__send__(:render_cell, 1, 1, Zaniah::Bounds.new(0, 0, 112, 24)).text).to eq("after")
    expect(view.__send__(:render_cell, 1, 2, Zaniah::Bounds.new(112, 0, 112, 24)).text).to eq("after")

    calls.clear
    workbook.format_range(1, 1, 1, 1, bold: true)
    view.request_layout(context)
    expect(calls).to eq([[1, 1]])
  ensure
    window&.close
  end

  it "represents formatted rectangles without expanding their coordinates" do
    workbook = Rukbat::Workbook.new
    notification = nil
    workbook.on_cells_changed { |sheet, cells| notification = [sheet, cells] }

    workbook.format_range(1, 1, 100, 100, bold: true)

    expect(notification.first).to eq("Sheet1")
    expect(notification.last).to eq(Rukbat::Workbook::CellRange.new(top: 1, left: 1, bottom: 100, right: 100))
    expect(notification.last.include?(100, 100)).to be(true)
    expect(notification.last.include?(101, 100)).to be(false)
  end

  it "applies a selected-range format and renders a chart from selected columns" do
    workbook = Rukbat::Workbook.new
    workbook.set_many([[1, 1, "Quarter"], [1, 2, "Sales"], [1, 3, "Cost"],
      [2, 1, "Q1"], [2, 2, 0.25], [2, 3, 0.1], [3, 1, "Q2"], [3, 2, 0.5], [3, 3, 0.2]])
    view = described_class.new(workbook)
    app = Zaniah::App.new
    window = app.open_window(backend: :headless) { view }
    begin
      window.tick
      view.grid.selection = [area(1...4, 1...4)]
      expect(view.__send__(:apply_format, number_format: "0.00%", bold: true)).to be(true)
      expect(workbook.presentation_at(2, 2).first).to eq("25.00%")
      expect(view.__send__(:show_chart, :line)).to be(true)
      window.tick
      expect(view.status).to eq("Line chart")

      charts = {
        bar: Zaniah::UI::BarChart, pie: Zaniah::UI::PieChart, donut: Zaniah::UI::DonutChart,
        scatter: Zaniah::UI::ScatterChart, area: Zaniah::UI::AreaChart, stacked_area: Zaniah::UI::AreaChart,
        stacked_bar: Zaniah::UI::StackedBarChart
      }
      charts.each do |type, chart_class|
        expect(view.__send__(:show_chart, type)).to be(true), type.to_s
        chart = view.instance_variable_get(:@chart_component)
        expect(chart).to be_a(chart_class), type.to_s
        expect(chart.points).to eq("Cost" => [[0.25, 0.1], [0.5, 0.2]]) if type == :scatter
      end
      expect(view.status).to eq("Stacked bar chart")
    ensure
      window.close
      app.executor.shutdown
    end
  end

  it "filters rows and keeps workbook-hidden rows separate from the filter" do
    workbook = Rukbat::Workbook.from_rows([["alpha", 1], ["beta", 2], ["alpha", 3]])
    workbook.hide_rows(3)
    view = described_class.new(workbook)
    view.grid.selection = [area(1...4, 1...2)]
    filter = view.instance_variable_get(:@filter_field)
    filter.buffer.replace(0...filter.buffer.bytesize, "alpha")

    expect(view.__send__(:apply_filter)).to be(true)
    expect(view.grid.row_hidden?(1)).to be(false)
    expect(view.grid.row_hidden?(2)).to be(true)
    expect(view.grid.row_hidden?(3)).to be(true)
    expect(view.__send__(:clear_filter)).to be(true)
    expect(view.grid.row_hidden?(2)).to be(false)
    expect(view.grid.row_hidden?(3)).to be(true)
  end

  it "applies row and column visibility from the selected workbook range" do
    workbook = Rukbat::Workbook.new
    view = described_class.new(workbook)
    view.grid.selection = [area(2...4, 3...5)]

    expect(view.__send__(:hide_selected_rows)).to be(true)
    expect(view.__send__(:hide_selected_columns)).to be(true)
    expect([workbook.hidden_rows, workbook.hidden_columns]).to eq([[2, 3], [3, 4]])
    expect(view.grid.row_hidden?(2)).to be(true)
    expect(view.grid.column_hidden?(3)).to be(true)
    view.__send__(:show_hidden)
    expect(view.grid.row_hidden?(2)).to be(false)
    expect(view.grid.column_hidden?(3)).to be(false)
  end

  it "freezes through the selected cell, restores each sheet, and supports undo and unfreeze" do
    workbook = Rukbat::Workbook.new
    workbook.set_frozen_panes(rows: 4, columns: 3, sheet: "Sheet1")
    workbook.add_sheet("Other")
    view = described_class.new(workbook)
    expect(view.grid.instance_variable_get(:@frozen_rows)).to eq(1)

    workbook.activate("Sheet1")
    view.__send__(:sync_frozen_panes)
    expect([view.grid.instance_variable_get(:@frozen_rows), view.grid.instance_variable_get(:@frozen_columns)])
      .to eq([4, 3])
    view.instance_variable_set(:@active_cell, [2, 3])
    expect(view.__send__(:freeze_panes)).to be(true)
    expect(workbook.frozen_panes).to eq([3, 4]) # Include grid row/column zero headers.
    view.undo
    expect(workbook.frozen_panes).to eq([4, 3])
    view.redo
    expect(workbook.frozen_panes).to eq([3, 4])
    expect(view.__send__(:unfreeze_panes)).to be(true)
    expect(workbook.frozen_panes).to eq([0, 0])
  end

  it "clears positive-value conditional formatting from the active sheet" do
    workbook = Rukbat::Workbook.new
    workbook.set(1, 1, 2)
    view = described_class.new(workbook)
    view.grid.selection = [area(1...2, 1...2)]

    expect(view.__send__(:highlight_positive)).to be(true)
    expect(workbook.presentation_at(1, 1).last[:color]).to eq("#008000")
    expect(view.__send__(:clear_highlights)).to be(true)
    expect(workbook.presentation_at(1, 1).last).not_to have_key(:color)
  end

  it "refreshes hidden axes and comments after undo" do
    workbook = Rukbat::Workbook.new
    workbook.set_comment(1, 1, "before")
    view = described_class.new(workbook)
    comment_field = view.instance_variable_get(:@comment_field)
    expect(comment_field.value).to eq("before")

    view.grid.selection = [area(2...3, 1...2)]
    view.__send__(:hide_selected_rows)
    expect(view.grid.row_hidden?(2)).to be(true)
    view.undo
    expect(view.grid.row_hidden?(2)).to be(false)

    workbook.set_comment(1, 1, "after")
    view.undo
    expect(comment_field.value).to eq("before")
  end

  it "inserts rows and deletes selected columns through the grid" do
    workbook = Rukbat::Workbook.from_rows([["A", "B", "C", "D"], ["x", 1, 2, 3]])
    view = described_class.new(workbook)
    view.grid.selection = [area(2...3, 1...5)]

    expect(view.__send__(:edit_structure, :insert_rows)).to be(true)
    expect(workbook.input_at(3, 1)).to eq("x")

    view.grid.selection = [area(1...3, 2...4)]
    expect(view.__send__(:edit_structure, :delete_columns)).to be(true)
    expect([workbook.input_at(1, 1), workbook.input_at(1, 2)]).to eq(["A", "D"])
  end

  it "sets a print area from the selection and exports it from the current workbook" do
    workbook = Rukbat::Workbook.from_rows([["outside", "outside"], ["outside", "inside"]])
    view = described_class.new(workbook)
    view.grid.selection = [area(2...3, 2...3)]
    expect(view.__send__(:set_print_area)).to be(true)
    expect(workbook.print_area).to eq(Furud::Area.new(sheet: "Sheet1", top: 2, left: 2, bottom: 2, right: 2))

    font = File.join(Gem::Specification.find_by_name("zaniah").full_gem_path, "assets/fonts/Abel-Regular.ttf")
    Tempfile.create(["rukbat-export", ".pdf"]) do |file|
      window = double("window")
      allow(window).to receive(:request_frame)
      allow(window).to receive(:prompt_for_paths).and_return([font], [file.path])
      view.instance_variable_set(:@cx, double(window: window))
      file.close

      expect(view.__send__(:export_pdf)).to be(true)
      expect(File.binread(file.path)).to start_with("%PDF-1.7\n".b)
      expect(view.status).to include("Exported")
    end
  end
end
