# frozen_string_literal: true

require "digest"
require "tempfile"

module Rukbat
  module CSVFile
    module_function
    MAX_EXPORT_CELLS = 10_000_000

    def read(path, delimiter: :comma, sheet: "Sheet1", hint: nil)
      snapshot = Xamidimura::SourceRevision.read(path)
      bytes = snapshot.bytes
      detection = Menkar.detect(bytes, hint: hint)
      raise Error, "CSV input is binary" if detection.binary

      text = Menkar.decode(bytes, detection)
      delimiter = delimiter_for(delimiter)
      rows = CSV.parse(text, col_sep: delimiter).map { |row| row.map { |value| value && parse_cell(value) } }
      Workbook.from_rows(rows, sheet: sheet).tap do |workbook|
        workbook.__send__(:bind_source, path, snapshot.digest)
      end
    rescue CSV::MalformedCSVError => error
      raise Error, "invalid CSV: #{error.message}"
    rescue Menkar::Error, SystemCallError => error
      raise Error, "cannot read CSV: #{error.message}"
    rescue Xamidimura::Error => error
      raise Error, "cannot read CSV: #{error.message}"
    end

    def write(workbook, path, delimiter: :comma, sheet: workbook.active_sheet, values: :calculated,
      expected_digest: :auto)
      col_sep = delimiter_for(delimiter)
      raise ArgumentError, "values must be :calculated or :input" unless %i[calculated input].include?(values)
      expected_digest = workbook.source_digest_for(path) if expected_digest == :auto
      unless expected_digest.nil? || expected_digest == :absent || expected_digest.is_a?(String)
        raise ArgumentError, "expected_digest must be :auto, :absent, a String, or nil"
      end

      current = workbook.sheet(sheet)
      rows, columns = current.row_count, current.column_count
      exported_cells = rows * [columns, 1].max
      raise Error, "CSV export exceeds #{MAX_EXPORT_CELLS} cells" if exported_cells > MAX_EXPORT_CELLS

      digest = Digest::SHA256.new
      write_atomically(path, expected_digest) do |file|
        current.row_count.times do |row|
          row_cells = Array.new(current.column_count) do |column|
            input = workbook.input_at(row + 1, column + 1, sheet: sheet)
            value = values == :input || !input.is_a?(String) || !input.start_with?("=") ? input : workbook[row + 1, column + 1, sheet: sheet]
            value.is_a?(Furud::ErrorValue) ? value.to_s : value
          end
          line = CSV.generate_line(row_cells, col_sep: col_sep, row_sep: "\r\n").encode(Encoding::UTF_8).b
          file.write(line)
          digest.update(line)
        end
      end
      workbook.__send__(:bind_source, path, digest.hexdigest)
      path
    rescue Xamidimura::Error, SystemCallError, EncodingError => error
      raise Error, "cannot write CSV: #{error.message}"
    end

    def infer(value)
      return Integer(value, 10) if value.match?(/\A[+-]?(?:0|[1-9]\d*)\z/)
      if value.match?(/\A[+-]?(?:(?:0|[1-9]\d*)(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?\z/i)
        number = Float(value)
        return number if number.finite?
      end

      value
    end
    private_class_method :infer

    def parse_cell(value)
      return nil if value.empty?

      infer(value)
    end

    def delimiter_for(value)
      case value
      when :comma then ","
      when :tab, :tsv then "\t"
      when String then value
      else raise ArgumentError, "delimiter must be :comma, :tab, :tsv, or a String"
      end
    end
    private_class_method :delimiter_for

    def write_atomically(path, expected_digest)
      target = File.expand_path(path)
      Tempfile.create([".rukbat-", ".tmp"], File.dirname(target), binmode: true) do |file|
        yield file
        file.flush
        file.fsync
        stat = begin
          File.lstat(target)
        rescue Errno::ENOENT
          nil
        end
        raise Error, "CSV target must be a regular file" if stat && !stat.file?
        if expected_digest == :absent && stat
          raise Error, "CSV file appeared since the workbook was opened"
        elsif expected_digest.is_a?(String) && (!stat || Xamidimura::SourceRevision.file_digest(target) != expected_digest)
          raise Error, "CSV file changed since it was loaded"
        end

        mode = stat ? stat.mode & 0o7777 : 0o666 & ~File.umask
        # ponytail: the digest check is advisory; an external writer racing the final rename needs OS-specific compare-and-swap locking.
        file.chmod(mode)
        AtomicFile.install(file.path, target, replace: expected_digest != :absent)
      end
      begin
        File.open(File.dirname(target), "r", &:fsync)
      rescue SystemCallError, IOError
        # Directory fsync is unavailable on some supported platforms.
      end
    rescue Errno::ENOENT
      raise Error, "CSV target directory does not exist"
    end
    private_class_method :write_atomically
  end
end
