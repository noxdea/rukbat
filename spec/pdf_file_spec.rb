# frozen_string_literal: true

require "tempfile"
require "tmpdir"

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

  it "records PDF pages as semantic vectors before drawing through Okab" do
    workbook = Rukbat::Workbook.from_rows([["hello", 123]])
    vectors = []
    allow(Okab::ZaniahVector).to receive(:draw).and_wrap_original do |original, page, vector|
      expect(vector).to be_a(Zaniah::Vector::Document)
      expect([vector.width, vector.height]).to eq([842, 595])
      vectors << vector
      original.call(page, vector)
    end

    described_class.render(workbook, font: font_path)

    expect(vectors.length).to eq(1)
    expect(vectors.first.commands).to include(a_kind_of(Zaniah::Vector::Quad), a_kind_of(Zaniah::Vector::GlyphRun))
  end

  it "keeps the PDF raster close to the recorded UI page" do
    skip "pdftoppm is unavailable" unless system("pdftoppm", "-v", out: File::NULL, err: File::NULL)
    workbook = Rukbat::Workbook.from_rows([["Visual", "123"]])
    workbook.format_range(1, 2, 1, 2, background: "#FFF2CC", border_color: "#123456")
    raster = nil
    original_record = Zaniah::Vector.method(:record)
    allow(Zaniah::Vector).to receive(:record) do |**options, &build|
      element = build.call
      window = Zaniah::Platform.open_window(width: options.fetch(:width), height: options.fetch(:height))
      begin
        window.text_system = options.fetch(:text_system)
        window.render(element, clear: "#FFFFFF")
        raster = window.device.pixels.dup
      ensure
        window.text_system = nil
        window.close
      end
      original_record.call(**options) { element }
    end

    pdf = described_class.render(workbook, font: font_path)
    Dir.mktmpdir("rukbat-pdf-compare") do |directory|
      input = File.join(directory, "page.pdf")
      output = File.join(directory, "page")
      File.binwrite(input, pdf)
      expect(system("pdftoppm", "-f", "1", "-l", "1", "-r", "72", "-singlefile", "-png", input, output,
        out: File::NULL, err: File::NULL)).to be(true)
      width, height, pixels = Zaniah::PNG.decode(File.binread("#{output}.png"))
      expect([width, height]).to eq([842, 595])
      background_offset = (69 * width + 190) * 4
      expect(pixels.byteslice(background_offset, 3).bytes).to eq([255, 242, 204])
      expect(raster.byteslice(background_offset, 3).bytes).to eq([255, 242, 204])
      error = pixels.bytes.zip(raster.bytes).sum { |a, b| (a - b).abs }
      expect(error.fdiv(pixels.bytesize)).to be < 18
    end
  end

  it "exports the selected font family plus bold and italic cell styles" do
    workbook = Rukbat::Workbook.from_rows([["styled"]])
    workbook.format_range(1, 1, 1, 1, font_family: "Abel", bold: true, italic: true)
    face = Zaniah::TextSystem::FontDB::Face.new(path: font_path, index: 0, family: "Abel", families: ["Abel"],
      weight: 400, width: 5, style: :normal, fixed_pitch: false, tables: [])
    font_db = double(faces: [face])
    expect(font_db).to receive(:open).with(font_path, index: 0).and_return(Okab::Font.load(font_path).face)

    pdf = described_class.render(workbook, font: font_path, font_db: font_db)

    expect(pdf).to include("2 Tr".b, "1 0 0.2 1".b, "0.28 w".b)
  end

  it "records an explicitly selected cell font in its searchable glyph run" do
    workbook = Rukbat::Workbook.from_rows([["selected font"]])
    workbook.format_range(1, 1, 1, 1, font_family: "Abel")
    face = Zaniah::TextSystem::FontDB::Face.new(path: font_path, index: 0, family: "Abel", families: ["Abel"],
      weight: 400, width: 5, style: :normal, fixed_pitch: false, tables: [])
    selected = Okab::Font.load(font_path).face
    font_db = double(faces: [face])
    expect(font_db).to receive(:open).with(font_path, index: 0).and_return(selected)
    vector = nil
    allow(Okab::ZaniahVector).to receive(:draw).and_wrap_original do |original, page, document|
      vector = document
      original.call(page, document)
    end

    described_class.render(workbook, font: font_path, font_db: font_db)

    run = vector.commands.grep(Zaniah::Vector::GlyphRun).find { |item| item.text.include?("selected font") }
    expect(run.font).to equal(selected)
  end

  it "paginates wide and tall sparse workbooks" do
    workbook = Rukbat::Workbook.new
    workbook.set(29, 9, "end")

    pdf = described_class.render(workbook, font: font_path)

    expect(pdf).to include("/Count 4".b)
  end

  it "exports only the selected print area with original row and column labels" do
    workbook = Rukbat::Workbook.from_rows([
      ["outside top", "hidden"],
      ["outside left", "inside", "outside right"],
      ["outside bottom", "also inside"]
    ])
    workbook.set_print_area(2, 2, 3, 2)
    pdf = described_class.render(workbook, font: font_path)

    expect(pdf).to include("/Count 1".b)
    skip "pdftotext is unavailable" unless system("pdftotext", "-v", out: File::NULL, err: File::NULL)

    Tempfile.create(["rukbat-print-area", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      extracted = IO.popen(["pdftotext", file.path, "-"], &:read)
      expect(extracted).to include("rows 2-3", "inside", "also inside", "B")
      expect(extracted).not_to include("outside top", "outside left", "outside right", "outside bottom", "hidden")
    end
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
      file.close
      expect(described_class.write(workbook, path, font: font_path)).to eq(path)
      expect(File.binread(path)).to start_with("%PDF-1.7\n".b)
    end
  end
end
