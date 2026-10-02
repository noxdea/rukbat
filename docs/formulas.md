---
title: Formulas and references
description: Calculate with cell references, named ranges, and values from other sheets.
---

Rukbat uses [Furud](https://github.com/noxdea/furud) to parse and evaluate
formulas. Enter a leading `=` to store a formula. The grid shows its result,
and the formula bar shows the original expression.

* On this page
{:toc}

## Cells and ranges

Rows and columns are **one-based**: `A1` is row 1, column 1. A colon specifies
a rectangular range, such as `A1:B3`.

| Expression | Meaning |
| --- | --- |
| `=A1*3` | Multiply the value in A1 by three. |
| `=SUM(A1:A2)` | Sum the values in A1 and A2. |
| `=AVERAGE(B2:B4)` | Average the numeric values in B2 through B4. |
| `=COUNT(B2:B4)` | Count numeric values in that range. |
| `=$A$1*B2` | Keep A1 fixed when filling the formula into other cells. |

For example, enter `12` in A1, `30` in A2, and `=SUM(A1:A2)` in B1. B1 displays
`42`; editing A1 recalculates B1. References are tracked so dependent values
update when their inputs change.

Relative references move during fill operations. `$A$1` fixes both the row and
column; `$A1` fixes the column, and `A$1` fixes the row. A fill that moves a
reference outside the grid produces `#REF!`.

## Function completion

Type a partial function name, such as `=SU`, into the formula bar. When a
candidate appears, choose **Use completion** to insert the function name.
Add the parentheses and arguments yourself, then choose **Apply**:

```text
=SUM(A1:A2)
```

Completion uses Furud's standard function registry. To list the available
functions from Ruby:

```ruby
require "rukbat"
puts Furud::Functions.standard.names.sort
```

Consult [Furud's documentation](https://github.com/noxdea/furud#readme) for the
full function language. Rukbat does not promise compatibility with every
Excel or LibreOffice function.

## Other sheets

Use `!` between the sheet name and the cell reference. Quote names that contain
spaces with single quotes:

```text
='Annual Plan'!A1+2
```

If `Annual Plan!A1` contains `25`, the result is `27`. Use the sheet's actual
name; the editor creates new sheets with names such as `Sheet2`.
The Ruby API can create a specifically named sheet:

```ruby
book = Rukbat::Workbook.new
book.add_sheet("Annual Plan")
book.set(1, 1, 25, sheet: "Annual Plan")
book.set(1, 1, "='Annual Plan'!A1+2", sheet: "Sheet1")
book[1, 1, sheet: "Sheet1"] # => 27
```

## Named ranges

Select a cell or range, enter a name such as `TaxRate` or `Sales`, and choose
**Name range**. Use that name in a formula:

```text
=TaxRate*2
=SUM(Sales)
```

Names are case-insensitive. A name must parse as a name rather than a cell
address or another expression. Redefining a name updates formulas that use it.
Definitions follow supported row and column edits and undo/redo.

## Invalid formulas and saving

A syntax error, such as `=SUM(`, rejects the edit and reports an error in the
status bar. An expression that parses but cannot calculate can display a
Furud error value, such as `#REF!`. Correct the referenced inputs or expression.

CSV/TSV saves calculated results by default, including error values as text.
To export formula expressions from Ruby, use `values: :input`:

```ruby
Rukbat::CSVFile.write(book, "formulas.csv", values: :input)
```

This still exports only one sheet. Other sheets and named-range definitions
are not serialized, so a formula that depends on them cannot be restored from
that file alone. See [files and exports](files.md#what-a-save-preserves).
