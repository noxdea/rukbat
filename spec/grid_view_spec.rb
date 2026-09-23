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

      expect(view.__send__(:export_pdf)).to be(true)
      expect(File.binread(file.path)).to start_with("%PDF-1.7\n".b)
      expect(view.status).to include("Exported")
    end
  end
end
