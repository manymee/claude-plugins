defmodule Exline.Ccstatusline do
  @moduledoc """
  Wraps the pinned ccstatusline binary. Renders a JSON payload through
  ccstatusline and returns the text output. Used by the
  `exline.ccstatusline` (ad-hoc) and `exline.ccstatusline.references`
  (batch) Mix tasks to produce side-by-side comparisons with exline's
  own output.

  Capture storage lives in `Exline.Captures`; this module only handles
  rendering.
  """

  @version "ccstatusline@2.2.19"
  @fallback "examples/input-example.json"

  @doc "Static fallback payload, used when no live capture is available."
  def fallback_path, do: @fallback

  @doc """
  Render the given JSON payload via ccstatusline.

  Options:
    * `:plain` — strip ANSI escape sequences (default `false`)
  """
  def render(json_path, opts \\ []) do
    abs = json_path |> Path.expand() |> shell_quote()
    cmd = "exec npx -y #{@version} < #{abs}"

    {output, 0} = System.cmd("sh", ["-c", cmd])

    if Keyword.get(opts, :plain, false), do: strip_ansi(output), else: output
  end

  defp strip_ansi(s), do: Regex.replace(~r/\e\[[0-9;]*m/, s, "")

  # POSIX single-quote escape: close quote, escaped literal quote, reopen.
  defp shell_quote(s), do: "'" <> String.replace(s, "'", ~S('\'')) <> "'"
end
