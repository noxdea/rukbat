# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rukbat::CSVFile do
  it "streams UTF-8 CSV and binds the digest of the bytes written" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "book.csv")
      workbook = Rukbat::Workbook.new
      workbook.set(1, 1, "name")
      workbook.set(2, 1, "日本")

      described_class.write(workbook, path)

      expect(File.binread(path)).to eq("name\r\n日本\r\n".b)
      expect(workbook.source_digest_for(path)).to eq(Digest::SHA256.file(path).hexdigest)
    end
  end

  it "rejects oversized sparse exports before creating the destination" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "too-large.csv")
      workbook = Rukbat::Workbook.new
      workbook.set(1, 1, 1)
      workbook.set(Rukbat::Workbook::MAX_ROWS, 10, 2)

      expect { described_class.write(workbook, path) }
        .to raise_error(Rukbat::Error, /exceeds #{described_class::MAX_EXPORT_CELLS} cells/)
      expect(File.exist?(path)).to be(false)
    end
  end

  it "persists validated values but not session-only input rules in CSV" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "validated.csv")
      workbook = Rukbat::Workbook.new
      workbook.set_whole_number_validation(1, 1, 1, 1, minimum: 1, maximum: 9)
      workbook.set(1, 1, 5)
      described_class.write(workbook, path)

      reopened = described_class.read(path)
      expect(reopened.input_at(1, 1)).to eq(5)
      expect(reopened.input_validation_at(1, 1)).to be_nil
    end
  end

  it "saves the active source sheet after a pivot and can export the pivot explicitly" do
    Dir.mktmpdir do |directory|
      source_path = File.join(directory, "source.csv")
      pivot_path = File.join(directory, "pivot.csv")
      workbook = Rukbat::Workbook.from_rows([["Key", "Value"], ["A", 3], ["A", 4]])
      pivot = workbook.pivot_table(1, 1, 3, 2, row_key_column: 1, value_column: 2)
      workbook.add_pivot_sheet("Pivot", pivot)

      expect(workbook.active_sheet).to eq("Sheet1")
      described_class.write(workbook, source_path)
      expect(File.binread(source_path)).to eq("Key,Value\r\nA,3\r\nA,4\r\n".b)

      described_class.write(workbook, pivot_path, sheet: "Pivot", expected_digest: :absent)
      expect(File.binread(pivot_path)).to eq("Key,Sum of Value\r\nA,7\r\n".b)
    end
  end
end
