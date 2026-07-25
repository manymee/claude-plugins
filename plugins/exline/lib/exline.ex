defmodule Exline do
  @moduledoc false

  alias Exline.Style

  @rate_limit_windows [
    {"Session", "five_hour"},
    {"Weekly", "seven_day"}
  ]

  # Zero-width space: forces a visible 4th line, since Claude Code collapses
  # empty trailing lines.
  @zwsp "​"

  # Divider between the rate-limit windows on line 4.
  @window_sep "  |  "

  # Separator between fields within a line.
  @field_sep "  "

  # Minimum spaces kept between a left group and its right-aligned partner when
  # they share a row; below this the row stays stacked.
  @min_gap 2

  @doc "List of `{label, key}` tuples for rate-limit windows rendered on line 4."
  def rate_limit_windows, do: @rate_limit_windows

  @doc """
  Render the status line for the Claude Code payload `data`.

  Options:
    * `:now`   — epoch seconds for rate-limit countdowns (default: system clock)
    * `:color` — emit ANSI styling (default: `false`). The live daemon passes
      `true`; tests and width math run color-free so plain layout stays
      byte-exact and measurable.
    * `:drift` — `{running, installed}` version pair when the installed plugin
      differs from the running daemon (default: `nil`). Renders a trailing
      "run /exline:setup" line. The listener supplies it via
      `Exline.PluginVersion.drift/0`; format itself does no IO.
    * `:dev`   — `true` when a dev daemon (non-canonical socket) is rendering;
      prefixes line 3 with a bold-yellow `dev` badge (default: `false`).

  Each line is built as a `{plain, styled}` pair. Width, truncation, and merge
  decisions use the plain text only; the styled text is what's emitted. Because
  ANSI escapes have zero display width, the two stay perfectly aligned.
  """
  def format(data, opts \\ []) when is_map(data) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    color? = Keyword.get(opts, :color, false)
    dev? = Keyword.get(opts, :dev, false)
    width = terminal_columns(data)

    rows =
      pair_row(line1(data, width, color?), line2(data, color?), width) ++
        pair_row(line3(data, color?, dev?), line4(data, now, color?), width) ++
        drift_row(Keyword.get(opts, :drift), color?)

    rows
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Extra warning line shown only while the installed plugin version differs
  # from the running daemon's — the cue to rebuild via /exline:setup.
  defp drift_row(nil, _color?), do: []

  defp drift_row({running, installed}, color?) do
    text = "⚠ exline #{running} running, #{installed} installed — run /exline:setup"
    [Style.paint(text, Style.behind(), color?)]
  end

  # Merge a left group and a right group onto one row when both carry content and
  # they fit the usable width with at least @min_gap between them; the right group
  # is padded flush to the right edge. Otherwise the two stay stacked. Applies to
  # both pairs: path + git info (lines 1–2) and model + rate limits (lines 3–4).
  # Width unknown, a nil left, or a right that is absent (nil) or the ZWSP
  # placeholder → stacked. Operates on `{plain, styled}` pairs (or nil): the gap
  # is computed from the plain widths, the styled text is emitted.
  defp pair_row(left, right, width) do
    lp = plain(left)
    rp = plain(right)
    ls = styled(left)
    rs = styled(right)
    mergeable = not is_nil(rp) and rp != @zwsp
    gap = is_integer(width) && lp && mergeable && width - String.length(lp) - String.length(rp)

    cond do
      is_nil(lp) or not mergeable -> [ls, rs]
      gap && gap >= @min_gap -> [ls <> String.duplicate(" ", gap) <> rs]
      true -> [ls, rs]
    end
  end

  defp plain(nil), do: nil
  defp plain({p, _}), do: p
  defp styled(nil), do: nil
  defp styled({_, s}), do: s

  # Columns Claude Code reserves on the right before it hard-clips the status
  # line itself (measured at 3 on a 39-col terminal: COLUMNS=39, render=36).
  # Targeting COLUMNS minus this keeps our left-collapse ahead of CC's clip, so
  # truncation reads as `.../tail` rather than CC's right-side ellipsis.
  @render_margin 3

  # Usable render width derived from the terminal's COLUMNS env var (forwarded
  # by the client). A positive integer enables width-aware path truncation;
  # 0/missing (older Claude Code, or daemon callers like tests) means "unknown"
  # and falls back to the width-blind behavior.
  defp terminal_columns(data) do
    case get_in(data, ["terminal", "columns"]) do
      n when is_integer(n) and n > 0 -> max(n - @render_margin, 1)
      _ -> nil
    end
  end

  defp line1(data, width, color?) do
    case get_in(data, ["workspace", "current_dir"]) do
      nil -> nil
      path -> path |> truncate_path(width) |> path_seg(color?)
    end
  end

  # Path styling: leave the parent segments + `.../` prefix at plain full
  # contrast, bold the leaf dir so the eye lands on where you are.
  defp path_seg(plain, false), do: {plain, plain}

  defp path_seg(plain, true) do
    styled =
      case :binary.matches(plain, "/") do
        [] ->
          Style.paint(plain, Style.bold(), true)

        matches ->
          {pos, _} = List.last(matches)
          prefix = binary_part(plain, 0, pos + 1)
          leaf = binary_part(plain, pos + 1, byte_size(plain) - pos - 1)
          prefix <> Style.paint(leaf, Style.bold(), true)
      end

    {plain, styled}
  end

  defp line2(data, color?) do
    case get_in(data, ["workspace", "current_dir"]) do
      nil ->
        nil

      cwd ->
        g = Exline.GitCache.fetch(cwd)

        [
          seg(g.root, Style.bold(), color?),
          plain_seg(g.worktree),
          seg(g.branch, Style.branch(), color?),
          flags_seg(g.status, color?),
          ahead_behind_seg(g.ahead_behind, color?)
        ]
        |> join(@field_sep, @field_sep)
    end
  end

  defp line3(data, color?, dev?) do
    [
      if(dev?, do: seg("dev", Style.behind(), color?)),
      seg(version(data), Style.bold(), color?),
      plain_seg(get_in(data, ["model", "display_name"])),
      seg(format_effort(get_in(data, ["effort", "level"])), Style.bold(), color?),
      plain_seg(get_in(data, ["output_style", "name"])),
      ctx_seg(get_in(data, ["context_window", "used_percentage"]), color?)
    ]
    |> join(@field_sep, @field_sep)
  end

  defp line4(data, now, color?) do
    segs =
      @rate_limit_windows
      |> Enum.map(fn {label, key} ->
        window_seg(label, get_in(data, ["rate_limits", key]), now, color?)
      end)
      |> Enum.reject(&is_nil/1)

    case segs do
      [] -> {@zwsp, @zwsp}
      _ -> join(segs, @window_sep, @window_sep)
    end
  end

  # Build a colored `{plain, styled}` segment, or nil when the text is absent.
  defp seg(nil, _sgr, _color?), do: nil
  defp seg(text, sgr, color?), do: {text, Style.paint(text, sgr, color?)}

  # A chrome segment: full-contrast default foreground, never styled.
  defp plain_seg(nil), do: nil
  defp plain_seg(text), do: {text, text}

  # Join a list of `{plain, styled}` segments (nils dropped). Plain text joins on
  # `plain_sep`, styled text on `styled_sep` (which may carry its own styling, as
  # the rate-limit divider does). Returns nil when nothing remains.
  defp join(segs, plain_sep, styled_sep) do
    case Enum.reject(segs, &is_nil/1) do
      [] ->
        nil

      kept ->
        {Enum.map_join(kept, plain_sep, &elem(&1, 0)),
         Enum.map_join(kept, styled_sep, &elem(&1, 1))}
    end
  end

  defp version(data), do: data["version"] && "v#{data["version"]}"

  defp format_effort(nil), do: nil
  defp format_effort(level), do: level

  defp ctx_seg(nil, _color?), do: nil

  defp ctx_seg(pct, color?) do
    label = "Ctx Used: "
    num = "#{format_pct(pct)}%"
    {label <> num, label <> Style.paint(num, Style.pct_sgr(pct), color?)}
  end

  defp window_seg(_, nil, _, _), do: nil

  defp window_seg(label, %{"used_percentage" => pct, "resets_at" => epoch}, now, color?) do
    head = "#{label}: "
    num = "#{format_pct(pct)}%"
    tail = "  #{humanize_seconds(epoch - now)}"

    {head <> num <> tail, head <> Style.paint(num, Style.pct_sgr(pct), color?) <> tail}
  end

  # Color each working-tree flag symbol by severity.
  defp flags_seg(nil, _color?), do: nil

  defp flags_seg(flags, color?) do
    styled =
      flags
      |> String.graphemes()
      |> Enum.map_join("", fn ch ->
        case Style.flag_sgr(ch) do
          nil -> ch
          sgr -> Style.paint(ch, sgr, color?)
        end
      end)

    {flags, styled}
  end

  # Color ahead (`↑n`) green and behind (`↓n`) yellow, leaving the layout intact.
  defp ahead_behind_seg(nil, _color?), do: nil

  defp ahead_behind_seg(ab, color?) do
    styled =
      ab
      |> String.split(" ")
      |> Enum.map_join(" ", fn
        "↑" <> _ = tok -> Style.paint(tok, Style.ahead(), color?)
        "↓" <> _ = tok -> Style.paint(tok, Style.behind(), color?)
        tok -> tok
      end)

    {ab, styled}
  end

  defp format_pct(pct) when is_integer(pct), do: format_pct(pct * 1.0)
  defp format_pct(pct) when is_float(pct), do: :erlang.float_to_binary(pct, decimals: 1)

  defp humanize_seconds(secs) when secs > 0 do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    "#{h}h#{m}m"
  end

  defp humanize_seconds(_), do: "0h0m"

  # Width unknown: collapse any path deeper than root + 2 segments to its last
  # two segments (the original, terminal-width-blind behavior).
  defp truncate_path(path, nil) do
    parts = Path.split(path)

    if length(parts) > 3 do
      ".../" <> Path.join(Enum.take(parts, -2))
    else
      path
    end
  end

  # Width known: keep the full path when it fits; otherwise collapse from the
  # left, retaining as many trailing segments as fit under `.../`. Floors at the
  # leaf alone even when that still overflows.
  defp truncate_path(path, width) do
    if String.length(path) <= width do
      path
    else
      path |> Path.split() |> drop_root() |> fit_suffix(width)
    end
  end

  defp drop_root(["/" | rest]), do: rest
  defp drop_root(parts), do: parts

  defp fit_suffix(segments, width) do
    Enum.reduce_while(length(segments)..1//-1, nil, fn k, _ ->
      candidate = ".../" <> Path.join(Enum.take(segments, -k))

      if String.length(candidate) <= width or k == 1 do
        {:halt, candidate}
      else
        {:cont, candidate}
      end
    end)
  end
end
