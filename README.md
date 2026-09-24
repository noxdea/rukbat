# Rukbat

Rukbat (α Sagittarii), from Arabic *rukbat al-rāmī* (“the archer’s knee”), is
a spreadsheet application built on a sparse, persistent Denebola sheet and the
Furud formula engine.

The current implementation includes a virtualized million-row grid, formula
editing and completion, multi-sheet formulas, range summaries, undo/redo,
structural row/column edits, formatting, sorting, filtering, duplicate removal,
find/replace, comments, named ranges, conditional formatting, line/bar/pie,
donut/scatter/area/stacked charts, CSV/TSV import/export, and searchable PDF
export. On arm64 macOS
with Ruby 4.0.6, the million-row integrated scroll benchmark measured 11.383 ms
against a 16.67 ms budget, and the 100,000-cell edit/recalculation benchmark
measured 1.773 s against a 3 s budget. Formula compatibility, public CI, and
dependency releases remain before the first release.

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
positive-value highlighting, freeze/unfreeze panes, print areas, and line, bar,
pie, donut, scatter, area, stacked-area, and stacked-bar charts.
Select a range, enter inclusive minimum/maximum values, and choose **Apply whole-number rule**
to require each nonblank edited value (including a formula's calculated result) to be
a whole number in that range. Invalid edits are rejected atomically; clearing cells is
allowed. **Clear rule** removes validation from the selected range, including only the
selected portion of a larger rule. Rules follow row/column insertions and deletions and
are included in undo/redo. Existing values are not retroactively changed when a rule is
applied. Input validations are session metadata: CSV/TSV has no place to store them, so
they reset when the workbook is reopened.
Freeze panes are kept per sheet and restored by undo/redo; the selected cell and
the row/column headers before it stay visible while scrolling. **Unfreeze** removes
all frozen rows and columns. Clear highlights removes conditional formatting
from the active sheet.
Select a range and choose **Set print area** to constrain PDF export; **Clear
print area** restores full-sheet output. **Export PDF** prompts for an embeddable
font and output path, applying the current print area. The CLI can also export
with `bundle exec rukbat --export-pdf report.pdf --font /path/to/font.ttf`.
Print areas are also session metadata and reset when the workbook is reopened.
PDF export embeds the supplied font, resolves formatted font families from the
system font database, and applies bold/italic along with cell formatting; bold
and italic are synthesized in the PDF when the selected face has no matching
variant. Charts are not yet rendered.

## Development

```sh
bundle install
bundle exec rake spec
BUDGET=1 bundle exec rake bench
bundle exec rbs -I sig -I "$(bundle info --path furud)/sig" -I "$(bundle info --path denebola)/sig" validate
gem build --strict rukbat.gemspec
```

The implementation is not yet a `0.1.0` release. Local performance gates pass;
check the workplan's M17 acceptance gate for remaining compatibility, public
CI, and dependency-release checks.
