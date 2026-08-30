defmodule Exline.Board.Liveness do
  @moduledoc """
  Is the process that wrote a session status file still running?

  Claude Code's status files (see `Exline.Board.SelfReport`) outlive their
  writers: a session that is killed or exits leaves its file behind unchanged.
  Each file names the process that wrote it — `pid`, plus `procStart`, the
  moment that process started — so a file with a dead pid is a session that
  quit, and the board can drop it at once instead of watching its render age
  decay for hours.

  `procStart` is what makes the pid trustworthy. Pids are recycled, so an
  unrelated process may hold the pid of a session that quit; the start time
  matched against the OS's own tells the two apart.

  The whole roster is checked with one `ps`. A verdict is `:alive`, `:dead`, or
  `:unverifiable` — the last for anything this module cannot answer for: a file
  with no pid or start time, a `pidDomain` other than "darwin" (the pid means
  nothing on this host then), an unparseable timestamp, or `ps` failing to run.
  Infrastructure trouble never reads as `:dead`; those sessions fall back to the
  render-age heuristic in `Exline.Board.State`.
  """

  @doc """
  Verdicts for a whole `Exline.Board.SelfReport.scan/2` result, as
  `session_id => :alive | :dead | :unverifiable`.

  One `ps` covers every checkable pid; a roster with none skips the command
  entirely.
  """
  def check(reports) when is_map(reports) do
    pids =
      reports
      |> Enum.flat_map(fn {_session_id, report} -> checkable_pid(report) end)
      |> Enum.uniq()

    starts = if pids == [], do: {:ok, %{}}, else: process_starts(pids)

    Map.new(reports, fn {session_id, report} -> {session_id, decide(report, starts)} end)
  end

  @doc """
  Verdict for one report against `starts`, the parsed `ps` result
  (`{:ok, %{pid => lstart}}`, or `:error` when `ps` could not be trusted).
  """
  def decide(report, starts) do
    case {checkable_pid(report), starts} do
      {[pid], {:ok, running}} -> verdict(pid, report.proc_start, running)
      _unverifiable -> :unverifiable
    end
  end

  defp checkable_pid(%{pid: pid, proc_start: proc_start, pid_domain: "darwin"})
       when is_integer(pid) and is_binary(proc_start),
       do: [pid]

  defp checkable_pid(_report), do: []

  defp verdict(pid, proc_start, running) do
    case Map.fetch(running, pid) do
      {:ok, observed} -> compare(proc_start, observed)
      # The pid is gone, so whatever wrote the file has exited.
      :error -> :dead
    end
  end

  # The file records the start time in UTC while `ps` prints it in the host's
  # local zone, so equal strings are the lucky case, not the rule (matching on
  # them alone would call every session on a non-UTC machine dead). Two
  # renderings of one instant differ by a whole-minute zone offset, and real
  # offsets span UTC-12 to UTC+14. Anything else is a different process wearing
  # a recycled pid.
  @zone_span_s 26 * 3600

  defp compare(same, same), do: :alive

  defp compare(recorded, observed) do
    case {to_naive(recorded), to_naive(observed)} do
      {{:ok, a}, {:ok, b}} -> if same_instant?(a, b), do: :alive, else: :dead
      _unparseable -> :unverifiable
    end
  end

  defp same_instant?(a, b) do
    diff = NaiveDateTime.diff(a, b)
    rem(diff, 60) == 0 and abs(diff) <= @zone_span_s
  end

  @doc """
  Parses `ps -o pid=,lstart=` output into `{:ok, %{pid => lstart}}`.

  Returns `:error` on any line that is not a pid and a start time — `ps` reports
  a bad argument list (an out-of-range pid, say) by printing a usage error and
  no rows at all, which must not be mistaken for "none of these are running".
  """
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:ok, pid, lstart} -> {:cont, {:ok, Map.put(acc, pid, lstart)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp parse_line(line) do
    with {pid, rest} <- Integer.parse(String.trim_leading(line)),
         lstart when lstart != "" <- String.trim(rest) do
      {:ok, pid, lstart}
    else
      _unexpected -> :error
    end
  end

  # `ps` exits non-zero merely because one of the pids is not running, so the
  # status says nothing; the output does. stderr is merged in so a usage error
  # shows up as an unparseable line rather than an empty, "all dead" answer.
  defp process_starts(pids) do
    {output, _status} =
      System.cmd("ps", ["-o", "pid=,lstart=", "-p", Enum.join(pids, ",")],
        env: [{"LC_ALL", "C"}],
        stderr_to_stdout: true
      )

    parse(output)
  rescue
    _no_ps -> :error
  catch
    :exit, _reason -> :error
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
          |> Enum.with_index(1)
          |> Map.new()

  # "Sat Aug 29 20:17:48 2026" (ctime layout, day space-padded) -> NaiveDateTime.
  defp to_naive(text) do
    with [_weekday, month, day, time, year] <- String.split(text, " ", trim: true),
         {:ok, month} <- Map.fetch(@months, month),
         {day, ""} <- Integer.parse(day),
         {year, ""} <- Integer.parse(year) do
      NaiveDateTime.from_iso8601("#{year}-#{pad(month)}-#{pad(day)}T#{time}")
    else
      _unparseable -> :error
    end
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
