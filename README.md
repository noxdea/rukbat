<h1 align="center">Rukbat</h1>

<p align="center">
  <strong>Ruby spreadsheet editor with sparse sheets, live formulas, and CSV/TSV workflows</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/rukbat"><img src="https://img.shields.io/gem/v/rukbat.svg" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/rukbat"><img src="https://img.shields.io/gem/dt/rukbat.svg" alt="Gem downloads"></a>
  <a href="https://github.com/noxdea/rukbat/actions/workflows/main.yml"><img src="https://github.com/noxdea/rukbat/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Ruby-%3E%3D%203.2-cc342d.svg" alt="Ruby 3.2 or newer">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#workbook-api">Workbook API</a> ·
  <a href="#development">Development</a>
</p>

---

Rukbat combines [Denebola](https://github.com/noxdea/denebola)'s persistent,
sparse sheets with [Furud](https://github.com/noxdea/furud)'s formula engine.
It opens CSV and TSV files in a graphical editor or an interactive terminal,
and also exposes workbooks as a Ruby API.
Its name comes from Rukbat (α Sagittarii), Arabic *rukbat al-rāmī*
(“the archer’s knee”).

## Features

- A virtualized million-row grid with formula editing, completion, multi-sheet references, and range summaries
- Undo/redo, row and column edits, formatting, sorting, filtering, duplicate removal, find/replace, comments, and named ranges
- Whole-number input validation, conditional formatting, freeze panes, and static pivot tables
- Line, bar, pie, donut, scatter, area, and stacked charts in the editor
- CSV/TSV import and export, plus searchable PDF export with an embedded font

## Installation

Rukbat requires Ruby 3.2 or newer. Install the published gem:

```sh
gem install rukbat
rukbat --version
```

Or add `gem "rukbat"` to your Gemfile. The editor needs a supported desktop
display or an interactive terminal; the workbook API can be used without one.

## Quick start

Open a CSV file, start a new one, or select tab-delimited input and output:

```sh
rukbat sales.csv
rukbat new.csv
rukbat --tsv data.tsv
```

Use the mouse to select cells, arrow keys to move, and Enter or a double-click
to edit. The formula bar's **Apply** button commits its value. Save with
Ctrl-S (Cmd-S on macOS); Ctrl-Z/Cmd-Z undoes, and the shifted shortcut redoes.
The status bar shows the selected range's count, numeric count, sum, and average.

The toolbar provides formats, sorting, filtering, duplicate removal,
search/replace, comments, named ranges, conditional highlighting, freeze
panes, print areas, and charts.

## Workbook API

Coordinates and formula references are one-based:

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

Denebola stores zero-based, immutable sheet snapshots internally. Undo and
redo retain prior roots instead of copying every cell; Rukbat feeds sparse
ranges to Furud through `CellSource`.

### Validation and pivots

Select a range in the editor, enter inclusive bounds, and choose **Apply
whole-number rule**. Nonblank edits, including calculated formula results,
must then be whole numbers within the bounds. Invalid edits are rejected
atomically; existing values are not changed when a rule is added. **Clear
rule** removes validation from the selected range. Rules follow structural
edits and undo/redo, but reset when a CSV/TSV workbook is reopened.

To create a pivot, select a rectangle including its header row, enter the
one-based key and value column positions within that selection, choose **Sum**
or **Count**, then **Create pivot**. The result is a static `Pivot` sheet (or
the next unused `Pivot2`, etc.), not a live link. Formula results are used;
groups retain first-seen order and match exact key values. Sum accepts finite
real numbers, while Count counts nonblank values. One Undo removes the
generated sheet.

## Files and export

```ruby
book = Rukbat::CSVFile.read("sales.csv", hint: "Windows-31J")
Rukbat::CSVFile.write(book, "sales-export.csv")
Rukbat::CSVFile.read("data.tsv", delimiter: :tsv)
```

Import uses [Menkar](https://github.com/noxdea/menkar) to detect and decode
text, infers integer and decimal literals, and leaves other fields as strings.
Export writes UTF-8 with CRLF row separators and uses calculated formula
values by default; pass `values: :input` to export stored formulas. Saving an
opened file rejects external changes made since it was loaded.

CSV/TSV saves only the active sheet. Pivot creation leaves the source sheet
active, so activate the pivot sheet before exporting its summary. Formatting,
validation rules, print areas, and other workbook metadata are not stored in
CSV/TSV.

Set a print area in the editor to limit PDF output, then choose **Export PDF**
and supply an embeddable font. The command line can export directly:

```sh
rukbat --export-pdf report.pdf --font /path/to/font.ttf sales.csv
```

PDF export includes formatted, searchable cell text. Charts are not rendered
in PDFs. Print areas reset when the workbook is reopened.

## Limits

- Workbooks support 1,048,576 rows and 16,384 columns; the grid renders visible cells rather than all rows at once.
- A workbook supports up to 256 validation ranges. A pivot handles up to 100,000 data rows and 10,000 groups.
- CSV/TSV export is limited to 10 million cells; PDF export is limited to 100,000 cells.
- Rukbat does not open or save XLSX/ODS files. CSV/TSV does not preserve multiple sheets or workbook metadata.

## Development

```sh
bundle install
bundle exec rake spec
BUDGET=1 bundle exec rake bench
bundle exec rbs -I sig -I "$(bundle info --path furud)/sig" -I "$(bundle info --path denebola)/sig" validate
gem build --strict rukbat.gemspec
```

## License

Rukbat is released under the [MIT License](LICENSE.txt).
