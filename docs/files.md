---
title: Files, exports, and limits
description: Understand what CSV and TSV preserve, export searchable PDFs, and resolve file errors.
---

* On this page
{:toc}

## CSV and TSV input

```sh
rukbat sales.csv
rukbat data.tsv
rukbat --tsv data.txt
```

A `.tsv` extension selects tab-separated values automatically. `--tsv` forces
tab-separated input and output for another extension. Other filenames use
commas. Rukbat does not open or save XLSX or ODS files.

[Menkar](https://github.com/noxdea/menkar) detects and decodes the input's text
encoding. Empty fields become blank cells; integer and finite decimal literals
become numbers. Other fields remain strings, with leading `=` interpreted as
a formula. Numeric-looking fields with leading zeros, such as `0012`, remain
text. Binary input and malformed CSV are rejected.

The Ruby API supports a decoding hint and a custom delimiter:

```ruby
book = Rukbat::CSVFile.read("sales.csv", hint: "Windows-31J")
tabs = Rukbat::CSVFile.read("data.tsv", delimiter: :tsv)
```

## What a save preserves

**Save writes the active sheet to the path opened by the launcher.**
The editor has no Save As control. Exports use UTF-8 and CRLF row separators.
Formula cells are saved as their calculated values by default.

| Data | CSV/TSV save |
| --- | --- |
| Active sheet's values | Preserved |
| Formula expressions | Only with API option `values: :input` |
| Other sheets | Not included |
| Formatting and conditional highlights | Not included |
| Comments and named ranges | Not included |
| Input-validation rules | Not included |
| Hidden rows/columns and frozen panes | Visibility settings are not included; cell values are exported |
| Print area, charts, and undo history | Not included |

Choose the pivot sheet tab before saving if you want to export a pivot result.
Use the API to write another path or a specific sheet:

```ruby
Rukbat::CSVFile.write(book, "sales-export.csv")
Rukbat::CSVFile.write(book, "formulas.csv", values: :input)
Rukbat::CSVFile.write(book, "summary.tsv", sheet: "Pivot", delimiter: :tsv)
```

Writes use a temporary file followed by installation at the target path.
Saving a loaded file checks its content digest and rejects changes made by
another process since loading or the last successful save. This is an advisory
check, not a lock against another writer racing the final rename.

## Export a searchable PDF

Select an area and choose **Set print area** to restrict PDF output. Without a
print area, export covers the active sheet's used rectangle. **Clear print
area** removes the restriction.

Choose **Export PDF**, select an embeddable font first, and then choose an output
path. The font must cover the characters in your sheet. File dialogs require
an interactive backend that supports them; the command line offers another
way to export:

```sh
rukbat --export-pdf report.pdf --font /path/to/font.ttf sales.csv
```

That command reads the file, writes a PDF, and exits without opening the editor.
The font path is required. From Ruby, you can export a workbook's current
formatting and print area:

```ruby
book.set_print_area(1, 1, 20, 4)
Rukbat::PDFFile.write(book, "report.pdf", font: "/path/to/font.ttf")
```

PDFs contain searchable text and formatted cells on landscape pages. Each page
contains up to 28 data rows and 8 data columns. Long cell text is truncated;
only its first line is rendered, and font sizes are capped at 13 points for
the fixed row height. Charts are not rendered. Print areas are not retained
when reopening CSV/TSV.

## Current limits

| Operation | Limit |
| --- | ---: |
| Sheet dimensions | 1,048,576 rows × 16,384 columns |
| Fill, sort, format, or hide in one operation | 100,000 cells or indices, depending on the operation |
| Filter | 100,000 rows |
| Pivot source | 100,000 data rows, excluding the header |
| Pivot result | 10,000 groups |
| Whole-number validation | 256 ranges per workbook |
| Conditional formatting | 256 rules per workbook |
| CSV/TSV export | 10,000,000 cells in the used rectangle |
| PDF export | 100,000 cells in the output rectangle |

Sparse storage and a virtualized grid avoid allocating every blank cell.
Import still reads the file into memory, and export limits count rectangular
area rather than only populated cells. A value far from the origin can make
an otherwise sparse sheet too large to export. Set a smaller print area for
PDFs or export a smaller workbook for CSV/TSV.

## Troubleshooting

- **“no display or interactive terminal is available”:** use a supported
  desktop session or an interactive terminal. For automation, use the Ruby API
  or `--export-pdf`.
- **“CSV file changed since it was loaded”:** keep the external file, reopen it,
  and reconcile your edits. From Ruby, write your edited workbook to a different
  path to keep both versions.
- **“CSV target directory does not exist”:** create the output's parent directory.
- **“invalid CSV” / “CSV input is binary”:** check the file format and delimiter;
  an XLSX file is not CSV.
- **PDF font or cell-limit errors:** supply an embeddable font with the required
  glyphs and reduce the print area. The status bar or command-line error explains
  the failed operation.
