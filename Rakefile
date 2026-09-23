# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Benchmark workbook recalculation and the integrated grid frame"
task :bench do
  ruby "-Ilib", "bench/workbook.rb"
  ruby "--yjit", "-Ilib", "bench/grid_view.rb"
end

task default: :spec
