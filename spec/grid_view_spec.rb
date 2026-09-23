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
end
