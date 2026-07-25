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
  @history_keep 20
  @crash_keep 20

  def last_path, do: @last_path
  def history_dir, do: Application.get_env(:exline, :captures_dir, "examples/captures")
  def crash_dir, do: Application.get_env(:exline, :crash_dir, "examples/crashes")

  @doc """
  Persist a payload as the newest capture and as `last_path/0`. Prunes
  the oldest entries once the history exceeds the keep count.
  """
  def save(input) do
    dir = history_dir()
    File.mkdir_p(dir)
    ts = System.os_time(:microsecond)
    File.write(Path.join(dir, "#{ts}.json"), input)
    File.write(@last_path, input)
    prune(dir, @history_keep)
  end

  @doc """
  Persist a payload whose render crashed, alongside the formatted crash
  (`<ts>.json` + `<ts>.txt`). Unlike the regular history — which rolls over in
  seconds under statusline polling — this survives long enough to debug: only
  the last #{@crash_keep} crashes are kept. Returns the absolute payload path.
  """
  def save_crash(input, kind, reason, stacktrace) do
    dir = crash_dir()
    File.mkdir_p(dir)
    ts = System.os_time(:microsecond)
    path = Path.join(dir, "#{ts}.json")
    File.write(path, input)
    File.write(Path.join(dir, "#{ts}.txt"), Exception.format(kind, reason, stacktrace))
    prune(dir, @crash_keep * 2)
    Path.expand(path)
  end

  @doc "Capture paths in `history_dir/0`, newest first."
  def list, do: list(history_dir())

  @doc "Crashed-payload paths in `crash_dir/0`, newest first."
  def crashes, do: list(crash_dir())

  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort(:desc)
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  @doc "Path to the N-th newest capture (1-indexed), or `nil`."
  def nth(n) when is_integer(n) and n >= 1, do: Enum.at(list(), n - 1)

  defp prune(dir, keep) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort(:desc)
        |> Enum.drop(keep)
        |> Enum.each(&File.rm(Path.join(dir, &1)))

      _ ->
        :ok
    end
  end
end
