# frozen_string_literal: true

module Rukbat
  module AtomicFile
    module_function

    def install(source, target, replace:)
      replace ? File.rename(source, target) : File.link(source, target)
    end
  end
end
