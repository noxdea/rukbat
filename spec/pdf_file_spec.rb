# frozen_string_literal: true

require "tempfile"

RSpec.describe Rukbat::PDFFile do
  let(:font_path) do
    File.join(Gem::Specification.find_by_name("zaniah").full_gem_path, "assets/fonts/Abel-Regular.ttf")
  end

  it "renders formatted workbook values as searchable, deterministic PDF" do
    workbook = Rukbat::Workbook.from_rows([["Name", "Amount"], ["Widget", 42]])
    workbook.format_range(2, 2, 2, 2, number_format: "#,##0.00", color: "#123456",
      background: "#FFF2CC", border_color: "#000000", border_width: 1,
      horizontal_alignment: :right)

    pdf = described_class.render(workbook, font: font_path)

    expect(pdf).to start_with("%PDF-1.7\n".b)
    expect(pdf).to include("/Count 1".b)
    expect(pdf).to include("0.07058823529411765 0.20392156862745098 0.33725490196078434 rg".b)
    expect(described_class.render(workbook, font: font_path)).to eq(pdf)
    if system("pdftotext", "-v", out: File::NULL, err: File::NULL)
      Tempfile.create(["rukbat", ".pdf"]) do |file|
        file.binmode
        file.write(pdf)
        file.flush
        extracted = IO.popen(["pdftotext", file.path, "-"], &:read)
        expect(extracted).to include("Widget", "42.00")
      end
    end
  end

  it "paginates wide and tall sparse workbooks" do
    workbook = Rukbat::Workbook.new
    workbook.set(29, 9, "end")

    pdf = described_class.render(workbook, font: font_path)

    expect(pdf).to include("/Count 4".b)
  end

  it "rejects invalid cell text instead of emitting a broken PDF" do
    workbook = Rukbat::Workbook.new
    workbook.set(1, 1, "\xFF".b)

    expect { described_class.render(workbook, font: font_path) }.to raise_error(EncodingError)
  end

  it "preserves Japanese text extraction with a supplied Japanese font" do
    japanese_font = ENV["RUKBAT_TEST_JP_FONT"]
    skip "Set RUKBAT_TEST_JP_FONT to validate Japanese PDF extraction" unless japanese_font
    skip "pdftotext is unavailable" unless system("pdftotext", "-v", out: File::NULL, err: File::NULL)

    workbook = Rukbat::Workbook.from_rows([["項目", "値"], ["四半期報告", 1234]])
    Tempfile.create(["rukbat-japanese", ".pdf"]) do |file|
      file.binmode
      file.write(described_class.render(workbook, font: japanese_font))
      file.flush
      extracted = IO.popen(["pdftotext", file.path, "-"], &:read)
      expect(extracted).to include("四半期報告")
    end
  end

  it "atomically writes only to regular file targets" do
    workbook = Rukbat::Workbook.from_rows([["ok"]])
    Tempfile.create(["rukbat-target", ".pdf"]) do |file|
      path = file.path
      expect(described_class.write(workbook, path, font: font_path)).to eq(path)
      expect(File.binread(path)).to start_with("%PDF-1.7\n".b)
    end
  end
end
