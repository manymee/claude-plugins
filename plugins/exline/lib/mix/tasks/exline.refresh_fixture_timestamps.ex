if Code.ensure_loaded?(Jason) do
  defmodule Mix.Tasks.Exline.RefreshFixtureTimestamps do
    @moduledoc """
    Roll fixture timestamps forward so wall-clock-aware comparison tools
    (e.g. ccstatusline) render realistic time deltas against fixed test
    inputs.

    For every `test/fixtures/*.json` that contains `_test_now`, sets
    `_test_now` to the current epoch and updates any `resets_at` fields
    underneath `rate_limits.*` to preserve their offset from the anchor.
    Fixtures without `_test_now` are left alone.

    Called automatically by `mix exline.ccstatusline.references` before
    regenerating the `.ccstatusline.txt` reference files.
    """

    @shortdoc "Roll fixture `_test_now` and rate-limit epochs forward"

    use Mix.Task

    @impl Mix.Task
    def run(_args) do
      "test/fixtures/*.json"
      |> Path.wildcard()
      |> Enum.each(&refresh/1)
    end

    defp refresh(path) do
      data = path |> File.read!() |> Jason.decode!()

      case data do
        %{"_test_now" => old_now} ->
          new_now = System.os_time(:second)

          updated =
            Exline.rate_limit_windows()
            |> Enum.reduce(data, fn {_label, key}, acc ->
              roll(acc, ["rate_limits", key, "resets_at"], old_now, new_now)
            end)
            |> Map.put("_test_now", new_now)

          File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
          Mix.shell().info("refreshed: #{Path.basename(path)}")

        _ ->
          :ok
      end
    end

    defp roll(data, path, old_now, new_now) do
      case get_in(data, path) do
        nil -> data
        epoch -> put_in(data, path, new_now + (epoch - old_now))
      end
    end
  end
end
