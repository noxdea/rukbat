# frozen_string_literal: true

require "rbconfig"

module Rukbat
  module AtomicFile
    WINDOWS = RbConfig::CONFIG["host_os"].match?(/mswin|mingw/)
    MOVEFILE_REPLACE_EXISTING = 0x1

    if WINDOWS
      require "fiddle"
      require "fiddle/import"

      module Win32
        extend Fiddle::Importer
        dlload "kernel32"
        extern "int MoveFileExW(void*, void*, unsigned long)"
      end
    end

    module_function

    def install(source, target, replace:)
      return move_file(source, target, replace: replace) if WINDOWS

      replace ? File.rename(source, target) : File.link(source, target)
    end

    def move_file(source, target, replace:)
      from = Fiddle::Pointer[(source + "\0").encode(Encoding::UTF_16LE)]
      to = Fiddle::Pointer[(target + "\0").encode(Encoding::UTF_16LE)]
      flags = replace ? MOVEFILE_REPLACE_EXISTING : 0
      return if Win32.MoveFileExW(from, to, flags) != 0

      error = Fiddle.last_error
      errno = case error
      when 2, 3 then Errno::ENOENT::Errno
      when 5, 32 then Errno::EACCES::Errno
      when 80, 183 then Errno::EEXIST::Errno
      else Errno::EIO::Errno
      end
      raise SystemCallError.new("MoveFileExW failed (Windows error #{error})", errno)
    end
    private_class_method :move_file
  end
end
