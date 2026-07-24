defmodule Exline.Captures do
  @moduledoc """
  Storage for statusline JSON payloads captured live by the daemon.

  Single source of truth for where captures live, how many to keep, and
  how to enumerate them. Written at runtime by `Exline.Listener` on
  every statusline tick; read at dev time by the `exline.ccstatusline`
  and `exline.ccstatusline.references` Mix tasks to replay payloads
  through ccstatusline for comparison against exline's output.

  Distinct from `Exline.ExpectedTest`, which asserts exline's own
  rendered output against committed `<name>.expected.txt` files.
  """

  @last_path "/tmp/exline-last.json"
  @history_dir "examples/captures"
  @history_keep 20

  def last_path, do: @last_path
  def history_dir, do: @history_dir

  @doc """
  Persist a payload as the newest capture and as `last_path/0`. Prunes
  the oldest entries once the history exceeds the keep count.
  """
  def save(input) do
    File.mkdir_p(@history_dir)
    ts = System.os_time(:microsecond)
    File.write(Path.join(@history_dir, "#{ts}.json"), input)
    File.write(@last_path, input)
    prune()
  end

  @doc "Capture paths in `history_dir/0`, newest first."
  def list do
    case File.ls(@history_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort(:desc)
        |> Enum.map(&Path.join(@history_dir, &1))

      _ ->
        []
    end
  end

  @doc "Path to the N-th newest capture (1-indexed), or `nil`."
  def nth(n) when is_integer(n) and n >= 1, do: Enum.at(list(), n - 1)

  defp prune do
    case File.ls(@history_dir) do
      {:ok, names} ->
        names
        |> Enum.sort(:desc)
        |> Enum.drop(@history_keep)
        |> Enum.each(&File.rm(Path.join(@history_dir, &1)))

      _ ->
        :ok
    end
  end
end
