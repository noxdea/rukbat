# frozen_string_literal: true

require "rukbat"

COUNT = Integer(ENV.fetch("CELLS", "100000"))
changes = [[1, 1, 0]]
(2..COUNT).each { |row| changes << [row, 1, "=A1+#{row - 1}"] }

workbook = Rukbat::Workbook.new
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
workbook.set_many(changes)
initial = Process.clock_gettime(Process::CLOCK_MONOTONIC)
workbook.set(1, 1, 1)
finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
elapsed = finished - started
recalculation = finished - initial
raise "formula chain is incorrect" unless workbook[COUNT, 1] == COUNT

puts "#{COUNT} cells: load/recalculate #{(initial - started).round(3)}s; source edit/recalculate #{recalculation.round(3)}s; total #{elapsed.round(3)}s"
abort "recalculation budget exceeded (3s)" if ENV["BUDGET"] == "1" && recalculation > 3.0
