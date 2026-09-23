# Rukbat

Rukbat (α Sagittarii), from Arabic *rukbat al-rāmī* (“the archer’s knee”), is
a spreadsheet application built on a sparse, persistent Denebola sheet and the
Furud formula engine.

The current implementation includes a virtualized million-row grid, formula
editing and completion, multi-sheet formulas, range summaries, undo/redo,
structural row/column edits, formatting, sorting, filtering, duplicate removal,
find/replace, comments, named ranges, conditional formatting, line/bar/pie
charts, CSV/TSV import/export, and searchable PDF export. The application is
still under development and has not been released as `0.1.0`; large-sheet
recalculation performance and formula compatibility remain under validation.

## Install

```ruby
gem "rukbat"
```

Rukbat requires Ruby 3.2 or newer.

## Workbooks

```ruby
require "rukbat"

book = Rukbat::Workbook.new
book.set(1, 1, 12)
book.set(2, 1, 30)
book.set(1, 2, "=SUM(A1:A2)")
book[1, 2] # => 42

book.add_sheet("Annual Plan")
book.set(1, 1, 2026, sheet: "Annual Plan")
book.undo
book.redo
```

Workbook coordinates and Furud references are one-based. Denebola storage is
zero-based internally. Sheets are immutable persistent snapshots, so undo and
redo retain prior roots instead of copying all cells. The formula engine is
storage-agnostic; Rukbat adapts sparse range iteration through `CellSource`.

## CSV and TSV

```ruby
book = Rukbat::CSVFile.read("sales.csv", hint: "Windows-31J")
Rukbat::CSVFile.write(book, "sales-export.csv")
Rukbat::CSVFile.read("data.tsv", delimiter: :tsv)
```

Import detects and strictly decodes text with Menkar, then infers integer and
decimal literals while leaving other fields as strings. Export writes UTF-8
with CRLF row separators; formula cells export their calculated values by
default. Pass `values: :input` to export stored formulas/inputs instead.
The application refuses to replace an existing file unless it is the exact
file read into the workbook and has not changed since loading.

Run `bundle exec rukbat sales.csv` to open the graphical editor. A missing CSV
path starts a new workbook; `--tsv` selects tab-delimited input and output.
Use the mouse to select ranges, arrow keys to move, Enter or a double-click to
edit, and Apply to commit the formula bar value. `Ctrl-S`/`Cmd-S` saves;
`Ctrl-Z`/`Cmd-Z` undo and the shifted shortcut redoes. The selected range's
count, numeric count, sum, and average appear in the status bar.

The toolbar provides common number, font, alignment, fill, and border formats;
sorting, filtering, duplicate removal, search/replace, comments, named ranges,
positive-value highlighting, freeze/unfreeze panes, print areas, and line/bar/pie charts.
Freeze panes are kept per sheet and restored by undo/redo; the selected cell and
the row/column headers before it stay visible while scrolling. **Unfreeze** removes
all frozen rows and columns. Clear highlights removes conditional formatting
from the active sheet.
Select a range and choose **Set print area** to constrain PDF export; **Clear
print area** restores full-sheet output. **Export PDF** prompts for an embeddable
font and output path, applying the current print area. The CLI can also export
with `bundle exec rukbat --export-pdf report.pdf --font /path/to/font.ttf`.
Print areas are session metadata; CSV has no place to store them, so they reset
when the workbook is reopened.
PDF export embeds the supplied font and writes cell values and basic cell
styling; it does not yet render charts.

## Development

```sh
bundle install
bundle exec rake spec
BUDGET=1 bundle exec rake bench
bundle exec rbs -I sig -I "$(bundle info --path furud)/sig" -I "$(bundle info --path denebola)/sig" validate
gem build --strict rukbat.gemspec
```

The implementation is not yet a `0.1.0` release: check the workplan's M17
acceptance gate for the remaining compatibility and performance work.
