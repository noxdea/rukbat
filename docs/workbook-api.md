---
title: Workbook API
description: Create sparse workbooks, calculate formulas, and export data from Ruby.
---

```ruby
require "rukbat"
```

The API works without opening a window. Coordinates are **one-based** throughout
`Rukbat::Workbook`; Denebola's internal sheet coordinates are zero-based.

* On this page
{:toc}

## Inputs and calculated values

```ruby
book = Rukbat::Workbook.new
book.set(1, 1, 12)
book.set(2, 1, 30)
book.set(1, 2, "=SUM(A1:A2)")

book[1, 2]          # => 42
book.input_at(1, 2) # => "=SUM(A1:A2)"
book.formula(1, 2)  # => "=SUM(A1:A2)"
book.summary(1, 1, 2, 1).sum # => 42
```

Use `clear(row, column)` to clear a cell. `set_many` applies a batch atomically
and records one undo step:

```ruby
book.set_many([[1, 1, 20], [2, 1, 30]])
book[1, 2] # => 50
book.undo
book[1, 2] # => 42
book.redo
book[1, 2] # => 50
```

## Rows and sheets

```ruby
book = Rukbat::Workbook.from_rows([
  ["Region", "Sales"],
  ["East", 10],
  ["West", 4],
  ["East", 6]
])
book.add_sheet("Annual Plan")
book.set(1, 1, 25, sheet: "Annual Plan")
book.activate("Sheet1")
book.sheet_names # => ["Sheet1", "Annual Plan"]
```

`add_sheet` activates the new sheet. Supply `sheet:` explicitly to read or edit
another sheet without switching. `insert_rows`, `delete_rows`, `insert_columns`,
and `delete_columns` accept a one-based position and an optional count.
`remove_sheet` rejects the last sheet and sheets still referenced by formulas.

## Formatting and named ranges

```ruby
book.format_range(2, 2, 4, 2, number_format: "#,##0.00", bold: true)
book.presentation_at(2, 2).first # => "10.00"
book.set_comment(2, 1, "Example sales data")
book.define_name("Sales", 2, 2, 4, 2)
book.set(5, 2, "=SUM(Sales)")
book[5, 2] # => 20

book.add_conditional_format(2, 2, 4, 2,
  operator: :greater_than, value: 5, style: {color: "#008000"})
```

Range methods take inclusive `top, left, bottom, right` coordinates. Formatting
supports number format, font family and size, bold/italic, text/background
colors, borders, and horizontal/vertical alignment. Colors use six-digit hex
strings. Inspect stored formatting with `format_at`; `presentation_at` returns
display text and the resolved style.

## Validation and pivots

```ruby
book.set_whole_number_validation(2, 2, 4, 2, minimum: 0, maximum: 100)
book.set(2, 2, 12) # accepted
# book.set(2, 2, 101) raises Rukbat::Error
book.clear_input_validation(2, 2, 4, 2)

pivot = book.pivot_table(1, 1, 4, 2,
  row_key_column: 1, value_column: 2, aggregate: :sum)
pivot.rows # => [["East", 18], ["West", 4]]
book.add_pivot_sheet("Summary", pivot)
```

Pivot column positions are relative to the selected rectangle. Use `:sum` or
`:count`. `pivot_table` returns a static result; `add_pivot_sheet` installs it
as an undoable sheet without changing the active sheet.

## Search, sort, and filter

```ruby
book.find("east", top: 2, left: 1, bottom: 4, right: 2)
book.filter_rows(2, 4, by: 1, query: "east") # => [2, 4]
book.sort(2, 1, 4, 2, by: 2, ascending: false)
book.replace_all("East", "Eastern", top: 2, left: 1, bottom: 4, right: 2)
```

Find and filter use case-insensitive substring matches. `filter_rows` returns
matching one-based row numbers; it does not hide or delete them. Replacement
is case-sensitive and changes stored strings. Sorting operates within the
rectangle; duplicate removal deletes entire duplicate sheet rows.

## Import, export, and errors

```ruby
book = Rukbat::CSVFile.read("sales.csv", hint: "Windows-31J")
Rukbat::CSVFile.write(book, "sales-export.csv")
Rukbat::CSVFile.write(book, "formulas.tsv", delimiter: :tsv, values: :input)
Rukbat::PDFFile.write(book, "report.pdf", font: "/path/to/font.ttf")
```

File methods default to the active sheet. CSV/TSV does not store workbook
metadata; see [files and limits](files.md) for preservation and export bounds.

Invalid workbook operations raise `Rukbat::Error`. Invalid option values can
raise `ArgumentError`. Calculation failures may be returned as
`Furud::ErrorValue` rather than raised. Inspect the result before using it as
a number. Public signatures are in
[sig/rukbat.rbs](https://github.com/noxdea/rukbat/blob/main/sig/rukbat.rbs).
