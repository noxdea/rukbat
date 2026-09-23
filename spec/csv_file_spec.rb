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
end
