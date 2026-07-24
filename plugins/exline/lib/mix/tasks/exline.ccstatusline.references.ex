defmodule Mix.Tasks.Exline.Ccstatusline.References do
  @moduledoc """
  Regenerate ccstatusline reference outputs for every test fixture.

  Rolls fixture timestamps forward via `mix exline.refresh_fixture_timestamps`
  first, so wall-clock-aware fields (rate-limit `resets_at`) render
  realistic deltas. Then runs ccstatusline against each fixture and
  writes the ANSI-stripped output to
  `test/fixtures/<name>.ccstatusline.txt`.

  Reference files are committed; exline's own regression assertions
  live in `<name>.expected.txt` and are regenerated separately via
  `UPDATE_EXPECTED=1 mix test`.
  """

  @shortdoc "Regenerate ccstatusline references for all test fixtures"

  use Mix.Task

  @fixtures_dir "test/fixtures"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("exline.refresh_fixture_timestamps")

    @fixtures_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&regenerate/1)
  end

  defp regenerate(json_path) do
    out_path = String.replace_suffix(json_path, ".json", ".ccstatusline.txt")
    Mix.shell().info("generating: #{Path.basename(out_path)}")
    File.write!(out_path, Exline.Ccstatusline.render(json_path, plain: true))
  end
end
