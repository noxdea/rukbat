# frozen_string_literal: true

require "rukbat"

FRAME_BUDGET_MS = 16.67
FRAME_COUNT = 23
window = Zaniah::Platform::Headless::Window.new(width: 800, height: 600)
context = Zaniah::FrameContext.new(window)
view = Rukbat::GridView.new(Rukbat::Workbook.new)
engine = Zaniah::Layout::Engine.new

render_frame = lambda do
  window.scene.clear
  window.dispatcher.clear_hits
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  node = view.request_layout(context)
  engine.compute(node, width: 800, height: 600)
  view.prepaint(node.bounds, nil, context)
  view.paint(node.bounds, nil, nil, context)
  finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  (finished - started) * 1000
end

begin
  render_frame.call
  view.grid.scroll_to(row: 500_000, column: 8_000)
  render_frame.call
  visible_cells = []
  times = FRAME_COUNT.times.map do |index|
    view.grid.scroll_to(row: 500_000 + (index + 1) * 24, column: 8_000 + (index + 1) * 4)
    elapsed = render_frame.call
    visible_cells << view.grid.visible_rows.size * view.grid.visible_columns.size
    elapsed
  end
  median = times.sort[FRAME_COUNT / 2]
  puts "Rukbat million-row integrated scroll frame median: #{median.round(3)} ms"
  puts "  average visible cells per frame: #{visible_cells.sum.fdiv(FRAME_COUNT).round(1)}"
  abort "Rukbat grid frame exceeds #{FRAME_BUDGET_MS}ms" if ENV["BUDGET"] == "1" && median > FRAME_BUDGET_MS
ensure
  window.close
end
