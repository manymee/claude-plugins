defmodule Exline.Style do
  @moduledoc """
  ANSI styling primitives for the status line.

  Colors are emitted as **16-color ANSI indices** (`\\e[31m`..`\\e[37m`,
  `\\e[91m`, bold via `1;`), not 256-cube or truecolor values. Indices resolve
  against the terminal's active palette, so they automatically track the user's
  light/dark theme switch — a fixed 256-cube color would not.

  No faint/dim (`\\e[2m`) is used: on a light background faint text washes out to
  low contrast. All text renders at full intensity; hierarchy comes from **bold**
  on the signal plus semantic color, while chrome stays plain default foreground
  (maximum contrast, theme-agnostic).

  Escapes have **zero display width**, so styling is applied as a final overlay
  *after* all width/truncation/merge decisions in `Exline` — the layout pass
  measures plain text only. `paint/3` with `color?: false` returns text
  unchanged, which keeps the daemon/test path byte-identical and color-free.
  """

  @reset "\e[0m"

  # The one thing the eye should land on: current-dir leaf, model name.
  def bold, do: "\e[1m"

  # Git's branch identity color (bold magenta). Semantic accents are all bold so
  # they stay vivid even where a light theme renders the base palette muted.
  def branch, do: "\e[1;35m"

  @doc "Wrap `text` in `sgr` and a reset, or return it unchanged when color is off."
  def paint(text, _sgr, false), do: text
  def paint(text, sgr, true), do: sgr <> text <> @reset

  @doc """
  Threshold gradient for a climbing usage percentage (context, rate-limit
  windows). green < 50 → yellow < 75 → bright red < 90 → bold red. The same scale
  is used for every percentage so one color language reads across the status line.
  """
  def pct_sgr(pct) when pct >= 90, do: "\e[1;31m"
  def pct_sgr(pct) when pct >= 75, do: "\e[1;91m"
  def pct_sgr(pct) when pct >= 50, do: "\e[1;33m"
  def pct_sgr(_), do: "\e[1;32m"

  @doc """
  Per-symbol color for the git working-tree flags by severity: `!` conflict
  (bold red), `+` staged (green), `*` unstaged (yellow). `?` untracked and any
  unknown symbol get nil (left at full-contrast default foreground).
  """
  def flag_sgr("!"), do: "\e[1;31m"
  def flag_sgr("+"), do: "\e[1;32m"
  def flag_sgr("*"), do: "\e[1;33m"
  def flag_sgr(_), do: nil

  # Ahead is informational (green); behind is a mild "you're out of date" warning
  # (yellow).
  def ahead, do: "\e[1;32m"
  def behind, do: "\e[1;33m"
end
