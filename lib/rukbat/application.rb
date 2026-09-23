# frozen_string_literal: true

module Rukbat
  class Application
    attr_reader :workbook, :path, :view

    def initialize(workbook:, path:, delimiter: :comma, backend: :auto)
      @workbook, @path, @delimiter = workbook, File.expand_path(path), delimiter
      @backend = backend == :auto ? default_backend : backend
      @view = GridView.new(workbook, on_save: method(:save))
    end

    def run
      app = Zaniah::App.new
      window = app.open_window(backend: @backend, width: 1100, height: 720,
        title: "Rukbat — #{File.basename(@path)}") { @view }
      window.on_input { |event| @view.handle_shortcut(event, window) }
      app.run
    end

    def save
      CSVFile.write(@workbook, @path, delimiter: @delimiter)
      "Saved #{File.basename(@path)}"
    end

    private

    def default_backend
      return :mac if RUBY_PLATFORM.include?("darwin")
      return :windows if RUBY_PLATFORM.match?(/mswin|mingw/)
      return :linux if ENV["DISPLAY"] || ENV["WAYLAND_DISPLAY"]
      return :tui if $stdin.tty? && $stdout.tty?

      raise Error, "no display or interactive terminal is available"
    end
  end
end
