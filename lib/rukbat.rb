# frozen_string_literal: true

require_relative "rukbat/version"
require "csv"
require "denebola"
require "furud"
require "menkar"
require "okab"
require "spica"
require "xamidimura"
require "zaniah"
require "zaniah/ui"
require_relative "rukbat/cell_source"
require_relative "rukbat/workbook"
require_relative "rukbat/csv_file"
require_relative "rukbat/pdf_file"
require_relative "rukbat/grid_view"
require_relative "rukbat/application"

module Rukbat
  class Error < StandardError; end
end
