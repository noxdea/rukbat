---
title: Getting started
description: Install Rukbat, open a CSV file, and calculate your first total.
permalink: /docs/
---

Rukbat opens CSV and TSV files in a desktop editor or an interactive terminal.
The same workbook is available through Ruby for scripts and applications.
This walkthrough starts with a small CSV file.

* On this page
{:toc}

## Install and launch

You need **Ruby 3.2 or newer**.

```sh
gem install rukbat
rukbat --version
```

Open an existing file, or use a new filename to start an empty workbook:

```sh
rukbat sales.csv
rukbat new.csv
```

Quote paths that contain spaces. The parent directory must exist before saving.
Rukbat requires a file path; running it without one prints command-line help.

On macOS and Windows, Rukbat selects the native desktop backend. On Linux,
it selects the desktop backend when `DISPLAY` or `WAYLAND_DISPLAY` is set,
and otherwise uses an interactive terminal when both input and output are TTYs.
The [workbook API](workbook-api.md) and command-line PDF export can run without
a window. There is no `--tui` command-line option.

For a source checkout, run `bundle install`, then
`bundle exec exe/rukbat sales.csv` from the repository directory.

## Open your first sheet

Save this text as `sales.csv`, then run `rukbat sales.csv`:

```csv
Region,Sales
East,12
West,30
```

The first row contains labels. The values `12` and `30` become numbers.
Rukbat detects text encodings on import and uses comma-separated input unless
you open a `.tsv` file or supply `--tsv`.

## Enter a formula

1. Select **A4**, type `Total` in the formula bar, and choose **Apply**.
2. Select **B4**, enter `=SUM(B2:B3)`, and choose **Apply**. The cell displays `42`.
3. Change **B2** to `20` and choose **Apply**. **B4** updates to `50`.

You can also double-click a cell or press Enter while the grid has focus to
edit it in place. Enter commits an inline edit; Escape cancels it.
Use the formula bar's **Apply** button to commit changes made there.

Select **B2:B3** to see a summary in the status bar: populated cell count,
numeric count, sum, and average. See [using the editor](usage.md) for selection,
formatting, sorting, validation, and charts.

## Save your work

Choose **Save**, or press **Ctrl+S** (**Cmd+S** on macOS).
Use **Undo** or **Ctrl+Z / Cmd+Z** to undo workbook changes;
**Ctrl+Shift+Z / Cmd+Shift+Z** redoes them.

**CSV/TSV saves only the active sheet, with calculated formula values.**
Reopening the example shows the saved total as a number, rather than a formula.
Formatting, other sheets, comments, named ranges, and validation rules are
session data and are not preserved. Read [files and exports](files.md) before
using Rukbat for a workbook you need to reopen.

## Where to go next

- [Using the editor](usage.md): selection, toolbars, pivots, and shortcuts.
- [Formulas and references](formulas.md): ranges, completion, and multiple sheets.
- [Files, exports, and limits](files.md): CSV/TSV, PDF, and troubleshooting.
- [Workbook API](workbook-api.md): create and manipulate a workbook from Ruby.
