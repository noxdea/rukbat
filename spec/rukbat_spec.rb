# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rukbat::Workbook do
  subject(:workbook) { described_class.new }

  it "stores sparse cell inputs and recalculates formulas through Furud" do
    workbook.set(1, 1, 12)
    workbook.set(2, 1, 30)
    workbook.set(1, 2, "=SUM(A1:A2)")

    expect(workbook[1, 2]).to eq(42)
    expect(workbook.formula(1, 2)).to eq("=SUM(A1:A2)")
    expect(workbook.sheet.cell_count).to eq(3)
    expect(workbook.each_in(1, 1, 2, 2).to_a).to include([Furud::Reference.new(sheet: "Sheet1", row: 1, column: 2), 42])
  end

  it "recalculates dependents when a source cell changes" do
    workbook.set(1, 1, 4)
    workbook.set(1, 2, "=A1*3")
    workbook.set(1, 1, 5)

    expect(workbook[1, 2]).to eq(15)
  end

  it "supports named sheets and cross-sheet formulas" do
    workbook.add_sheet("Annual Plan")
    workbook.set(1, 1, 25, sheet: "Annual Plan")
    workbook.activate("Sheet1")
    workbook.set(1, 1, "='Annual Plan'!A1+2")

    expect(workbook[1, 1]).to eq(27)
  end

  it "supports named ranges through undo and redo" do
    workbook.set(1, 1, 12)
    workbook.define_name("TaxRate", 1, 1, 1, 1)
    workbook.set(1, 2, "=TaxRate*2")

    expect(workbook[1, 2]).to eq(24)
    expect(workbook.undo).to be(true)
    expect(workbook.input_at(1, 2)).to be_nil
    expect(workbook.redo).to be(true)
    expect(workbook[1, 2]).to eq(24)
  end

  it "resolves named ranges case-insensitively and recalculates on redefinition and row insertion" do
    workbook.set_many([[1, 1, 7], [2, 1, 9], [1, 2, "=taxrate"]])
    workbook.define_name("TaxRate", 1, 1, 1, 1)
    expect(workbook[1, 2]).to eq(7)

    workbook.define_name("TAXRATE", 2, 1, 2, 1)
    expect(workbook[1, 2]).to eq(9)
    workbook.insert_rows(1)
    expect(workbook[2, 2]).to eq(9)
  end

  it "finds and replaces sparse input without partially applying invalid formulas" do
    workbook.set(1, 1, "hello").set(2, 1, "hello")
    workbook.set(1, 2, "=A1+1")

    expect(workbook.find("hello").map(&:row)).to eq([1, 2])
    expect(workbook.replace_all("hello", "goodbye")).to eq(2)
    expect(workbook.input_at(1, 1)).to eq("goodbye")
    expect(workbook.input_at(2, 1)).to eq("goodbye")
    expect { workbook.replace_all("A1+1", "1+") }.to raise_error(Rukbat::Error, /invalid formula/)
    expect(workbook.input_at(1, 2)).to eq("=A1+1")
  end

  it "sorts a bounded range and adjusts formulas with their rows" do
    workbook.set_many([[1, 1, 3], [1, 2, "=A1*10"], [2, 1, 1], [2, 2, "=A2*10"], [3, 1, 2], [3, 2, "=A3*10"]])

    workbook.sort(1, 1, 3, 2, by: 1)

    expect((1..3).map { |row| workbook[row, 1] }).to eq([1, 2, 3])
    expect((1..3).map { |row| workbook.formula(row, 2) }).to eq(["=A1*10", "=A2*10", "=A3*10"])
    expect((1..3).map { |row| workbook[row, 2] }).to eq([10, 20, 30])
  end

  it "sorts cell comments and formats with their row values" do
    workbook = described_class.from_rows([["Name", "Score"], ["B", 2], ["A", 1]])
    workbook.format_range(2, 1, 2, 1, bold: true)
    workbook.set_comment(2, 1, "belongs to B")

    workbook.sort(2, 1, 3, 2, by: 1)

    expect(workbook.input_at(3, 1)).to eq("B")
    expect(workbook.format_at(3, 1)).to include(bold: true)
    expect(workbook.comment_at(3, 1)).to eq("belongs to B")
    expect(workbook.undo).to be(true)
    expect(workbook.comment_at(2, 1)).to eq("belongs to B")
  end

  it "filters calculated values and removes duplicate rows without losing formula references" do
    workbook = described_class.from_rows([["Name", "Count"], ["A", 3], ["B", 4], ["A", 3], ["Total", "=SUM(B2:B4)"]])

    expect(workbook.filter_rows(2, 5, by: 1, query: "b")).to eq([3])
    expect(workbook.remove_duplicates(2, 1, 4, 2)).to eq(1)
    expect(workbook.input_at(4, 2)).to eq("=SUM(B2:B3)")
    expect(workbook[4, 2]).to eq(7)
    expect(workbook.undo).to be(true)
    expect(workbook.input_at(5, 2)).to eq("=SUM(B2:B4)")
  end

  it "rejects duplicate removal that would delete a named range entirely" do
    workbook = described_class.from_rows([["A"], ["A"]])
    workbook.define_name("OnlyDuplicate", 2, 1, 2, 1)

    expect { workbook.remove_duplicates(1, 1, 2, 1) }.to raise_error(Rukbat::Error, /named range/)
    expect(workbook.input_at(2, 1)).to eq("A")
  end

  it "formats values and keeps comments and conditional styles through row edits and undo" do
    workbook.set(2, 1, 1234.5)
    workbook.format_range(2, 1, 2, 1, number_format: "$#,##0.00", bold: true,
      color: "#112233", background: "#EEEEEE", border_color: "#000000", border_width: 1,
      horizontal_alignment: :right, vertical_alignment: :middle)
    workbook.set_comment(2, 1, "Reviewed")
    workbook.add_conditional_format(2, 1, 2, 1, operator: :greater_than, value: 1000,
      style: {background: "#CCFFCC"})

    presentation = workbook.presentation_at(2, 1)
    expect(presentation.first).to eq("$1,234.50")
    expect(presentation.last).to include(bold: true, background: "#CCFFCC")
    expect(workbook.comment_at(2, 1)).to eq("Reviewed")
    workbook.insert_rows(1)
    expect(workbook.presentation_at(3, 1).first).to eq("$1,234.50")
    expect(workbook.format_at(3, 1)[:bold]).to be(true)
    expect(workbook.comment_at(3, 1)).to eq("Reviewed")
    expect(workbook.presentation_at(3, 1).last[:background]).to eq("#CCFFCC")
    expect(workbook.undo).to be(true)
    expect(workbook.comment_at(2, 1)).to eq("Reviewed")
  end

  it "deduplicates conditional rules, validates their styles, and clears them with undo" do
    workbook.set(1, 1, 5)
    rule = {operator: :greater_than, value: 0, style: {color: "#008000"}}
    workbook.add_conditional_format(1, 1, 1, 1, **rule)
    workbook.add_conditional_format(1, 1, 1, 1, **rule)
    expect(workbook.presentation_at(1, 1).last[:color]).to eq("#008000")

    workbook.clear_conditional_formats
    expect(workbook.presentation_at(1, 1).last).not_to have_key(:color)
    expect(workbook.undo).to be(true)
    expect(workbook.presentation_at(1, 1).last[:color]).to eq("#008000")
    expect { workbook.add_conditional_format(1, 1, 1, 1, operator: :equal, value: 5, style: nil) }
      .to raise_error(Rukbat::Error, /style must be a Hash/)
  end

  it "keeps freeze panes per sheet and adjusts them through structural edits and history" do
    workbook.set_frozen_panes(rows: 3, columns: 4)
    workbook.add_sheet("Other")
    expect(workbook.frozen_panes).to eq([1, 1])
    expect(workbook.frozen_panes(sheet: "Sheet1")).to eq([3, 4])
    expect(workbook.undo).to be(true)

    workbook.insert_rows(2, 2)
    workbook.insert_columns(2)
    expect(workbook.frozen_panes).to eq([5, 5])
    workbook.delete_rows(2, 3)
    workbook.delete_columns(3, 2)
    expect(workbook.frozen_panes).to eq([2, 3])
    expect(workbook.undo).to be(true)
    expect(workbook.frozen_panes).to eq([2, 5])
    expect { workbook.set_frozen_panes(rows: -1, columns: 1) }
      .to raise_error(Rukbat::Error, /outside sheet limits/)
  end

  it "keeps hidden row and column state through structural edits and history" do
    workbook = described_class.new
    workbook.hide_rows(3)
    workbook.hide_columns(2)
    workbook.insert_rows(1)
    workbook.insert_columns(1)

    expect(workbook.row_hidden?(4)).to be(true)
    expect(workbook.column_hidden?(3)).to be(true)
    expect(workbook.hidden_rows).to eq([4])
    expect(workbook.undo).to be(true)
    expect(workbook.column_hidden?(2)).to be(true)
    expect(workbook.row_hidden?(4)).to be(true)
    expect(workbook.undo).to be(true)
    expect(workbook.row_hidden?(3)).to be(true)
    workbook.clear_hidden(:rows)
    expect(workbook.hidden_rows).to be_empty
  end

  it "keeps per-sheet print areas through edits, undo, redo, and clearing" do
    workbook.set(5, 3, "end")
    workbook.set_print_area(2, 2, 5, 3)
    expect(workbook.print_area).to eq(Furud::Area.new(sheet: "Sheet1", top: 2, left: 2, bottom: 5, right: 3))

    workbook.insert_rows(3)
    expect(workbook.print_area.bottom).to eq(6)
    expect(workbook.undo).to be(true)
    expect(workbook.print_area.bottom).to eq(5)
    expect(workbook.redo).to be(true)
    expect(workbook.print_area.bottom).to eq(6)
    workbook.insert_columns(2)
    expect([workbook.print_area.left, workbook.print_area.right]).to eq([3, 4])
    expect(workbook.undo).to be(true)
    expect([workbook.print_area.left, workbook.print_area.right]).to eq([2, 3])
    expect(workbook.redo).to be(true)
    expect([workbook.print_area.left, workbook.print_area.right]).to eq([3, 4])

    workbook.add_sheet("Notes")
    workbook.set_print_area(1, 1, 1, 1, sheet: "Notes")
    expect(workbook.print_area(sheet: "Sheet1").bottom).to eq(6)
    workbook.remove_sheet("Notes")
    expect(workbook.print_area(sheet: "Sheet1").bottom).to eq(6)

    workbook.clear_print_area
    expect(workbook.print_area).to be_nil
    expect(workbook.undo).to be(true)
    expect(workbook.print_area.bottom).to eq(6)
  end

  it "drops a print area deleted in full and validates its coordinates" do
    workbook.set_print_area(2, 1, 3, 1)
    workbook.delete_rows(2, 2)

    expect(workbook.print_area).to be_nil
    expect { workbook.set_print_area(0, 1, 1, 1) }.to raise_error(Rukbat::Error, /range coordinates/)
  end

  it "summarizes a selected rectangle from Denebola" do
    workbook.set(1, 1, 10)
    workbook.set(2, 1, 20)
    workbook.set(2, 2, "label")
    workbook.set(1, 2, "=A1+A2")

    expect(workbook.summary(1, 1, 2, 2)).to have_attributes(
      count: 4, numeric_count: 3, sum: 60, min: 10, max: 30, average: 20.0)
  end

  it "pivots an explicit range by relative key/value columns using sum or nonblank count" do
    workbook.set_many([[1, 1, "Region"], [1, 2, "Sales"],
      [2, 1, "East"], [2, 2, 10], [3, 1, "West"], [3, 2, 4],
      [4, 1, "East"], [4, 2, "=2*3"], [5, 1, "East"], [5, 2, "n/a"],
      [6, 1, "West"], [7, 1, "West"], [7, 2, Float::INFINITY],
      [8, 1, "East"], [8, 2, Float::NAN], [9, 2, 3]])

    pivot = workbook.pivot_table(1, 1, 9, 2, row_key_column: 1, value_column: 2)
    expect(pivot).to have_attributes(
      source_area: Furud::Area.new(sheet: "Sheet1", top: 1, left: 1, bottom: 9, right: 2),
      row_key_column: 1, value_column: 2, aggregate: :sum,
      headers: ["Region", "Sum of Sales"], rows: [["East", 16], ["West", 4], [nil, 3]])

    counts = workbook.pivot_table(1, 1, 9, 2, row_key_column: 1, value_column: 2, aggregate: :count)
    expect(counts.aggregate).to eq(:count)
    expect(counts.headers).to eq(["Region", "Count of Sales"])
    expect(counts.rows).to eq([["East", 4], ["West", 2], [nil, 1]])
    expect { workbook.pivot_table(1, 1, 9, 2, row_key_column: 3, value_column: 2) }
      .to raise_error(Rukbat::Error, /row-key column/)
  end

  it "writes formula error keys and atomically rejects malformed pivot output" do
    workbook.set(1, 1, "Key")
    workbook.set(1, 2, "Value")
    workbook.set(2, 1, "=1/0")
    workbook.set(2, 2, 7)
    pivot = workbook.pivot_table(1, 1, 2, 2, row_key_column: 1, value_column: 2)

    expect(pivot.rows.first.first).to be_a(Furud::ErrorValue)
    expect(workbook.add_pivot_sheet("Pivot", pivot)).to eq("Pivot")
    expect(workbook.input_at(2, 1, sheet: "Pivot")).to be_a(Furud::ErrorValue)
    expect(workbook.undo).to be(true)
    expect(workbook.sheet_names).to eq(["Sheet1"])

    malformed = Rukbat::Workbook::PivotTable.new(source_area: pivot.source_area,
      row_key_column: 1, value_column: 2, aggregate: :sum,
      headers: ["Key", "Sum of Value"], rows: [["missing value"]])
    expect { workbook.add_pivot_sheet("Broken", malformed) }
      .to raise_error(Rukbat::Error, /must contain a key and value/)
    expect(workbook.sheet_names).to eq(["Sheet1"])
    expect(workbook.redo).to be(true)
    expect(workbook.sheet_names).to eq(["Sheet1", "Pivot"])

    invalid_aggregate = Rukbat::Workbook::PivotTable.new(source_area: pivot.source_area,
      row_key_column: 1, value_column: 2, aggregate: :average,
      headers: ["Key", "Average of Value"], rows: [["A", 7]])
    expect { workbook.add_pivot_sheet("Invalid", invalid_aggregate) }
      .to raise_error(Rukbat::Error, /pivot columns are invalid/)
    expect(workbook.sheet_names).to eq(["Sheet1", "Pivot"])
  end

  it "rejects pivot sums that overflow to a non-finite value" do
    workbook.set_many([[1, 1, "Key"], [1, 2, "Value"],
      [2, 1, "A"], [2, 2, Float::MAX], [3, 1, "A"], [3, 2, Float::MAX]])

    expect { workbook.pivot_table(1, 1, 3, 2, row_key_column: 1, value_column: 2) }
      .to raise_error(Rukbat::Error, /pivot sum is not finite/)
    expect(workbook.sheet_names).to eq(["Sheet1"])
  end

  it "rolls back a pivot sheet when calculation fails during installation" do
    workbook.set(1, 1, "Key")
    workbook.set(1, 2, "Value")
    workbook.set(2, 1, "A")
    workbook.set(2, 2, 3)
    pivot = workbook.pivot_table(1, 1, 2, 2, row_key_column: 1, value_column: 2)
    workbook.set(10, 10, 1)
    workbook.set(10, 10, 2)
    workbook.undo
    engine = workbook.instance_variable_get(:@engine)
    allow(engine).to receive(:recalculate).and_raise(StandardError, "simulated calculation failure")

    expect { workbook.add_pivot_sheet("Pivot", pivot) }
      .to raise_error(Rukbat::Error, /simulated calculation failure/)
    expect(workbook.sheet_names).to eq(["Sheet1"])
    expect(workbook.summary(1, 1, 2, 2).sum).to eq(3)
    expect(workbook.redo).to be(true)
    expect(workbook.input_at(10, 10)).to eq(2)
  end

  it "rejects pivots that exceed the group limit" do
    rows = [["Key", "Value"], *Array.new(Rukbat::Workbook::MAX_PIVOT_GROUPS + 1) { |index| ["group#{index}"] }]
    workbook = described_class.from_rows(rows)

    expect { workbook.pivot_table(1, 1, rows.length, 2, row_key_column: 1, value_column: 2) }
      .to raise_error(Rukbat::Error, /#{Rukbat::Workbook::MAX_PIVOT_GROUPS} groups/)
  end

  it "preserves and adjusts formula references during row insertion" do
    workbook.set(5, 1, 9)
    workbook.set(1, 2, "=A5")
    workbook.insert_rows(2)

    expect(workbook.formula(1, 2)).to eq("=A6")
    expect(workbook[1, 2]).to eq(9)
    expect(workbook[6, 1]).to eq(9)
  end

  it "replaces deleted cell references with #REF! and moves column data" do
    workbook.set(4, 1, 9)
    workbook.set(1, 2, "=A4")
    workbook.delete_rows(4)
    expect(workbook.formula(1, 2)).to eq("=#REF!")
    expect(workbook[1, 2].to_s).to eq("#REF!")

    workbook.set(1, 1, "left")
    workbook.insert_columns(1)
    expect(workbook[1, 2]).to eq("left")
  end

  it "adjusts formulas inside and outside a sheet during column edits" do
    workbook.add_sheet("Budget")
    workbook.set(1, 3, 8, sheet: "Budget")
    workbook.set(1, 5, "=C1", sheet: "Budget")
    workbook.set(1, 2, "=Budget!C1", sheet: "Sheet1")

    workbook.insert_columns(2, sheet: "Budget")

    expect(workbook.formula(1, 6, sheet: "Budget")).to eq("=D1")
    expect(workbook[1, 6, sheet: "Budget"]).to eq(8)
    expect(workbook.formula(1, 2, sheet: "Sheet1")).to eq("=Budget!D1")
    expect(workbook[1, 2, sheet: "Sheet1"]).to eq(8)

    workbook.delete_columns(4, sheet: "Budget")

    expect(workbook.formula(1, 5, sheet: "Budget")).to eq("=#REF!")
    expect(workbook.formula(1, 2, sheet: "Sheet1")).to eq("=#REF!")
  end

  it "undoes and redoes edits using persistent sheet snapshots" do
    workbook.set(1, 1, 3)
    workbook.set(1, 1, 8)
    expect(workbook[1, 1]).to eq(8)

    expect(workbook.undo).to be(true)
    expect(workbook[1, 1]).to eq(3)
    expect(workbook.redo).to be(true)
    expect(workbook[1, 1]).to eq(8)
  end

  it "rejects invalid formulas without changing workbook or redo state" do
    workbook.set(1, 1, 3)
    workbook.set(1, 1, 8)
    expect(workbook.undo).to be(true)

    expect { workbook.set(1, 1, "=1+") }.to raise_error(Rukbat::Error, /invalid formula/)
    expect(workbook.input_at(1, 1)).to eq(3)
    expect(workbook[1, 1]).to eq(3)
    expect(workbook.redo).to be(true)
    expect(workbook[1, 1]).to eq(8)
  end

  it "validates every formula in a batch before applying any changes" do
    expect { workbook.set_many([[1, 1, 4], [1, 2, "=1+"]]) }
      .to raise_error(Rukbat::Error, /invalid formula/)

    expect(workbook.input_at(1, 1)).to be_nil
    expect(workbook.input_at(1, 2)).to be_nil
    expect(workbook[1, 1]).to be_nil
  end

  it "applies a group of cell changes as one undoable recalculation" do
    workbook.set_many([[1, 1, 4], [1, 2, "=A1*2"], [2, 1, 8]])
    expect(workbook[1, 2]).to eq(8)
    expect(workbook.input_at(1, 1)).to eq(4)
    expect(workbook.input_at(1, 2)).to eq("=A1*2")
    expect(workbook.input_at(2, 1)).to eq(8)
    expect(workbook.undo).to be(true)
    expect(workbook[1, 1]).to be_nil
    expect(workbook[1, 2]).to be_nil
  end

  it "applies rectangular whole-number rules and replaces or clears only selected cells" do
    workbook.set_whole_number_validation(1, 1, 4, 4, minimum: 1, maximum: 9)
    workbook.set_whole_number_validation(2, 2, 3, 3, minimum: 10, maximum: 20)

    expect(workbook.input_validation_at(1, 1).minimum).to eq(1)
    expect(workbook.input_validation_at(2, 2).minimum).to eq(10)
    expect(workbook.input_validation_at(3, 3).maximum).to eq(20)

    workbook.clear_input_validation(2, 2, 2, 2)

    expect(workbook.input_validation_at(2, 2)).to be_nil
    expect(workbook.input_validation_at(2, 3).minimum).to eq(10)
    expect(workbook.input_validation_at(4, 4).maximum).to eq(9)
  end

  it "bounds the number of range validations" do
    Rukbat::Workbook::MAX_INPUT_VALIDATIONS.times do |offset|
      workbook.set_whole_number_validation(1, offset + 1, 1, offset + 1, minimum: 1, maximum: 9)
    end

    expect { workbook.set_whole_number_validation(1, 257, 1, 257, minimum: 1, maximum: 9) }
      .to raise_error(Rukbat::Error, /input validation limit/)
    expect(workbook.input_validation_at(1, 257)).to be_nil
  end

  it "enforces validation atomically for direct edits, batches, and formula results" do
    workbook.set_whole_number_validation(1, 2, 1, 2, minimum: 1, maximum: 10)
    workbook.set(1, 2, 10)

    expect { workbook.set(1, 2, 11) }.to raise_error(Rukbat::Error, /B1.*1 and 10/)
    expect { workbook.set(1, 2, "text") }.to raise_error(Rukbat::Error, /B1.*whole number/)
    expect { workbook.set(1, 2, 1.5) }.to raise_error(Rukbat::Error, /B1.*whole number/)
    expect { workbook.set_many([[2, 1, 8], [1, 2, 12]]) }
      .to raise_error(Rukbat::Error, /B1.*1 and 10/)
    expect(workbook.input_at(2, 1)).to be_nil

    workbook.set(1, 1, 5)
    workbook.set(1, 2, "=A1")
    expect(workbook[1, 2]).to eq(5)
    expect { workbook.set(1, 1, 12) }.to raise_error(Rukbat::Error, /B1.*1 and 10/)
    expect(workbook.input_at(1, 1)).to eq(5)
    expect(workbook[1, 2]).to eq(5)
    expect(workbook.summary(1, 1, 1, 2).sum).to eq(10)
    expect { workbook.set(1, 2, "=11") }.to raise_error(Rukbat::Error, /B1.*1 and 10/)
  end

  it "keeps validation ranges through undo, redo, and structural edits" do
    workbook.set_whole_number_validation(2, 1, 3, 2, minimum: -2, maximum: 2)

    expect(workbook.undo).to be(true)
    expect(workbook.input_validation_at(2, 1)).to be_nil
    expect(workbook.redo).to be(true)
    expect(workbook.input_validation_at(3, 2).minimum).to eq(-2)

    workbook.insert_rows(1)
    expect(workbook.input_validation_at(2, 1)).to be_nil
    expect(workbook.input_validation_at(3, 1).maximum).to eq(2)
    expect(workbook.undo).to be(true)
    expect(workbook.input_validation_at(2, 1).minimum).to eq(-2)
  end

  it "preserves redo and rolls back structure edits that violate formula validation" do
    workbook.set_whole_number_validation(1, 2, 1, 2, minimum: 1, maximum: 9)
    workbook.set(1, 2, 5)
    workbook.set(1, 2, 6)
    expect(workbook.undo).to be(true)
    expect { workbook.set(1, 2, 10) }.to raise_error(Rukbat::Error, /B1.*1 and 9/)
    expect(workbook.redo).to be(true)
    expect(workbook.input_at(1, 2)).to eq(6)

    workbook.set(1, 1, 5)
    workbook.set(2, 2, "=A1")
    workbook.set_whole_number_validation(2, 2, 2, 2, minimum: 1, maximum: 9)
    expect { workbook.delete_rows(1) }.to raise_error(Rukbat::Error, /B1.*whole number/)
    expect(workbook.formula(2, 2)).to eq("=A1")
    expect(workbook.input_validation_at(2, 2).minimum).to eq(1)
    expect(workbook.undo).to be(true)
    expect(workbook.formula(2, 2)).to eq("=A1")
  end

  it "validates sheet names and spreadsheet coordinates" do
    expect { workbook.add_sheet("Bad/Name") }.to raise_error(Rukbat::Error)
    expect { workbook.set(0, 1, 1) }.to raise_error(Rukbat::Error)
    expect { workbook.set(1, 16_385, 1) }.to raise_error(Rukbat::Error)
    expect { workbook.set(1.5, 1, 1) }.to raise_error(Rukbat::Error)
  end

  it "validates selection rectangles before summary and sparse iteration" do
    expect { workbook.summary(0, 1, 1, 1) }.to raise_error(Rukbat::Error, /range coordinates/)
    expect { workbook.summary(2, 1, 1, 1) }.to raise_error(Rukbat::Error, /range coordinates/)
    expect { workbook.each_in(1, 1, 1, 16_385).to_a }.to raise_error(Rukbat::Error, /range coordinates/)
  end

  it "prevents removing a sheet that is explicitly referenced by a formula" do
    workbook.add_sheet("Data")
    workbook.set(1, 1, 42, sheet: "Data")
    workbook.activate("Sheet1")
    workbook.set(1, 1, "=Data!A1+1")

    expect { workbook.remove_sheet("Data") }.to raise_error(Rukbat::Error, /referenced sheet/)
    expect(workbook[1, 1]).to eq(43)
    expect(workbook.sheet_names).to include("Data")
  end

  it "rejects structural insertions that would move cells past the sheet boundary" do
    workbook.set(Rukbat::Workbook::MAX_ROWS, 1, 9)
    expect { workbook.insert_rows(1) }.to raise_error(Rukbat::Error, /sheet limit/)
    expect(workbook.sheet.row_count).to eq(Rukbat::Workbook::MAX_ROWS)
    expect(workbook.input_at(Rukbat::Workbook::MAX_ROWS, 1)).to eq(9)
    expect(workbook.input_at(Rukbat::Workbook::MAX_ROWS + 1, 1)).to be_nil

    workbook.set(1, Rukbat::Workbook::MAX_COLUMNS, 9)
    expect { workbook.insert_columns(1) }.to raise_error(Rukbat::Error, /sheet limit/)
    expect(workbook.sheet.column_count).to eq(Rukbat::Workbook::MAX_COLUMNS)
    expect(workbook.input_at(1, Rukbat::Workbook::MAX_COLUMNS + 1)).to be_nil
  end
end

RSpec.describe Rukbat::CSVFile do
  it "imports Shift_JIS CSV without corrupting Japanese text and writes UTF-8 CSV" do
    Dir.mktmpdir do |directory|
      input = File.join(directory, "input.csv")
      output = File.join(directory, "output.csv")
      File.binwrite(input, "商品,価格\r\nりんご,120\r\n合計,=B2*2\r\n".encode(Encoding::Windows_31J))

      workbook = described_class.read(input)
      expect(workbook[1, 1]).to eq("商品")
      expect(workbook[2, 1]).to eq("りんご")
      expect(workbook[2, 2]).to eq(120)
      expect(workbook[3, 2]).to eq(240)
      workbook.set(3, 2, "=B2*2")
      described_class.write(workbook, output)
      output_text = File.binread(output).force_encoding(Encoding::UTF_8)
      expect(output_text).to include("りんご,120")
      expect(output_text).to include(",240")
    end
  end

  it "supports tab-delimited files" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "input.tsv")
      File.binwrite(path, "a\tb\n1\t2\n")

      workbook = described_class.read(path, delimiter: :tsv)
      expect(workbook[2, 2]).to eq(2)
    end
  end

  it "stores empty CSV fields as sparse blank cells" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sparse.csv")
      File.write(path, "name,value\nitem,\n")

      workbook = described_class.read(path)
      expect(workbook.input_at(2, 2)).to be_nil
      expect(workbook.sheet.cell_count).to eq(3)
    end
  end

  it "does not overwrite a CSV changed by another process" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "shared.csv")
      File.write(path, "original")
      digest = Digest::SHA256.file(path).hexdigest
      File.write(path, "external edit")

      expect { described_class.write(Rukbat::Workbook.new, path, expected_digest: digest) }
        .to raise_error(Rukbat::Error, /changed since it was loaded/)
      expect(File.read(path)).to eq("external edit")
    end
  end

  it "parses blank, integer, decimal, formula, and text cell input" do
    expect(described_class.parse_cell("")).to be_nil
    expect(described_class.parse_cell("42")).to eq(42)
    expect(described_class.parse_cell("1.25")).to eq(1.25)
    expect(described_class.parse_cell("=A1+1")).to eq("=A1+1")
    expect(described_class.parse_cell("001")).to eq("001")
    expect(described_class.parse_cell("1e999")).to eq("1e999")
  end

  it "tracks the imported file digest and rejects external changes on save" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "book.csv")
      File.write(path, "1,2\n")
      workbook = described_class.read(path)
      workbook.set(1, 1, 3)
      File.write(path, "outside edit\n")

      expect { described_class.write(workbook, path) }.to raise_error(Rukbat::Error, /changed since it was loaded/)
      expect(File.read(path)).to eq("outside edit\n")
    end
  end

  it "refuses to replace a file that appeared after an unsaved workbook was created" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "book.csv")
      workbook = Rukbat::Workbook.new
      File.write(path, "outside edit\n")

      expect { described_class.write(workbook, path) }.to raise_error(Rukbat::Error, /appeared since/)
      expect(File.read(path)).to eq("outside edit\n")
    end
  end
end

RSpec.describe Rukbat::GridView do
  it "renders only a viewport from a million-row by sixteen-thousand-column grid" do
    view = described_class.new(Rukbat::Workbook.new)
    app = Zaniah::App.new
    window = app.open_window(backend: :headless, width: 640, height: 360) { view }
    begin
      window.tick

      expect(view.grid.visible_rows.size).to be_between(1, 40)
      expect(view.grid.visible_columns.size).to be_between(1, 20)
      expect(view.grid.accessibility_node(nil).states).to include(rows: Rukbat::Workbook::MAX_ROWS + 1,
        columns: Rukbat::Workbook::MAX_COLUMNS + 1)
    ensure
      window.close
      app.executor.shutdown
    end
  end

  it "completes function names and applies numeric formula-bar edits" do
    view = described_class.new(Rukbat::Workbook.new)
    app = Zaniah::App.new
    window = app.open_window(backend: :headless) { view }
    begin
      window.tick
      view.formula_field.buffer.replace(0...view.formula_field.buffer.bytesize, "=SU")
      view.__send__(:update_completion, "=SU")

      expect(view.completion_candidate).to eq("SUM")
      view.__send__(:apply_completion)
      expect(view.formula_field.value).to eq("=SUM")
      view.formula_field.buffer.replace(0...view.formula_field.buffer.bytesize, "12")
      expect(view.apply_edit).to be(true)
      expect(view.instance_variable_get(:@workbook)[1, 1]).to eq(12)
    ensure
      window.close
      app.executor.shutdown
    end
  end

  it "fills a repeated source pattern and translates relative formulas in one step" do
    workbook = Rukbat::Workbook.new
    workbook.set(1, 1, 2)
    workbook.set(1, 2, "=A1+1")
    view = described_class.new(workbook)
    source = Zaniah::UI::Grid::Area.new(rows: 1...2, columns: 1...3)
    target = Zaniah::UI::Grid::Area.new(rows: 1...2, columns: 1...5)
    view.__send__(:fill, source, target)

    expect(workbook[1, 3]).to eq(2)
    expect(workbook.formula(1, 4)).to eq("=C1+1")
    expect(workbook[1, 4]).to eq(3)
    expect(workbook.undo).to be(true)
    expect(workbook[1, 3]).to be_nil
    expect(workbook[1, 4]).to be_nil
  end
end

RSpec.describe Rukbat::Application do
  it "saves a new workbook without replacing a path that appeared later" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "new.csv")
      workbook = Rukbat::Workbook.new
      workbook.set(1, 1, "hello")
      app = described_class.new(workbook: workbook, path: path, backend: :headless)
      expect(app.save).to eq("Saved new.csv")
      expect(File.binread(path)).to eq("hello\r\n".b)
      workbook.set(1, 1, "updated")
      expect(app.save).to eq("Saved new.csv")
      expect(File.binread(path)).to eq("updated\r\n".b)
    end
  end
end
