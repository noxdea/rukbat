---
title: Development
description: Run the tests and benchmarks, understand the components, and preview the documentation.
---

* On this page
{:toc}

## Set up a checkout

```sh
git clone https://github.com/noxdea/rukbat.git
cd rukbat
bundle install
bundle exec exe/rukbat sales.csv
```

Use Ruby 3.2 or newer. The editor needs a supported desktop or interactive
terminal; the specs exercise workbook operations and the headless UI.

## Run checks

```sh
bundle exec rake spec
bundle exec rbs -I sig -I "$(bundle info --path furud)/sig" -I "$(bundle info --path denebola)/sig" validate
gem build --strict rukbat.gemspec
```

CI runs specs, signature validation, and a strict gem build on Linux, macOS,
and Windows, across Ruby 3.2, 3.3, 3.4, and 4.0. GitHub Actions workflows also
check YAML, spelling, and workflow security.

## Measure workbook and grid performance

```sh
bundle exec rake bench
BUDGET=1 bundle exec rake bench
```

The benchmark task runs workbook recalculation and an integrated grid frame.
The grid benchmark runs with YJIT. `BUDGET=1` enables the benchmarks' budget
checks; inspect the scripts in `bench/` for workloads and thresholds.

## How the components fit together

| Component | Responsibility |
| --- | --- |
| `Workbook` | One-based operations, formulas, metadata, and undo/redo. |
| Denebola | Persistent sparse sheets; history retains roots instead of copying every cell. |
| Furud / `CellSource` | Formula evaluation and sparse range access. |
| `GridView` / Zaniah | Virtualized grid, editing controls, and chart rendering. |
| `CSVFile` / Menkar / Xamidimura | Encoding detection, import, and source-revision checks. |
| `PDFFile` / Okab | Searchable PDF output from Zaniah vector recordings. |
| Spica | Formula-function completion. |

The launcher selects a backend and opens a workbook through `Application`.
Keep data operations in `Workbook` so editor and API behavior stay consistent.
CSV/TSV persists sheet values rather than the complete in-memory workbook.

## Preview the website and guide

The website uses GitHub Pages' built-in Jekyll support. `index.html` is the
landing page, `styles.css` is shared, and Markdown files in `docs/` use the
`_layouts/guide.html` layout. `_config.yml` defines the guide navigation and
the `/rukbat` project path. No JavaScript or custom site generator is required.

Install the site tools separately from the application's bundle:

```sh
gem install jekyll -v 3.10.0
gem install kramdown-parser-gfm -v 1.1.0
gem install jekyll-relative-links -v 0.6.1 --conservative
JEKYLL_NO_BUNDLER_REQUIRE=true jekyll serve
```

Open `http://127.0.0.1:4000/rukbat/` and
`http://127.0.0.1:4000/rukbat/docs/`. Use `jekyll build` with the same environment
variable for a static build. Relative Markdown links between guide pages work
on GitHub and are converted to HTML links by GitHub Pages.

The repository publishes from the root of `main`; merging website or guide
changes into that branch triggers the existing Pages build. See
[GitHub's Pages documentation](https://docs.github.com/en/pages/setting-up-a-github-pages-site-with-jekyll/about-github-pages-and-jekyll)
for the supported build settings.

Regenerate the editor preview from synthetic data with:

```sh
bundle exec ruby -Ilib tools/generate_overview.rb
```

## Contribute

Report issues and submit focused pull requests on
[GitHub](https://github.com/noxdea/rukbat). Include a reproduction for bugs and
run the relevant checks before submitting. Read the
[changelog](https://github.com/noxdea/rukbat/blob/main/CHANGELOG.md) for release
history. Rukbat is released under the
[MIT License](https://github.com/noxdea/rukbat/blob/main/LICENSE.txt).
