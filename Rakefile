# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Benchmark 100k-cell workbook load and incremental recalculation"
task :bench do
  ruby "-Ilib", "bench/workbook.rb"
end

task default: :spec
