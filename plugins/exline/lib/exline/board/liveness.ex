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

  Two commands answer the two halves, and they cost very different things.
  `exists/1` asks `kill -0` whether the pids are there at all — ~2 ms for a
  dozen. `snapshot/0` reads every running process's start time out of one
  `ps -ax`: ~35 ms, where naming the pids (`ps -p a,b`) hits a macOS slow path
  that costs ~225 ms for anything past a single pid. `Exline.Board.LivenessCache`
  puts that split to use, asking existence per board read and reusing a cached
  snapshot for identity.

  A verdict is `:alive`, `:dead`, or `:unverifiable` — the last for anything
  this module cannot answer for: a file with no pid or start time, a `pidDomain`
  other than "darwin" (the pid means nothing on this host then), an unparseable
  timestamp, or a command failing to run. Infrastructure trouble never reads as
  `:dead`; those sessions fall back to the render-age heuristic in
  `Exline.Board.State`.
  """

  @doc """
  Verdicts for a whole `Exline.Board.SelfReport.scan/2` result, as
  `session_id => :alive | :dead | :unverifiable`, from a fresh `ps` snapshot.

  One `ps` covers the roster however long it is; a roster with no checkable pid
  skips the command entirely.
  """
  def check(reports) when is_map(reports) do
    starts = if checkable_pids(reports) == [], do: {:ok, %{}}, else: snapshot()

    Map.new(reports, fn {session_id, report} -> {session_id, decide(report, starts)} end)
  end

  @doc "The pids in `reports` this module can check, deduplicated."
  def checkable_pids(reports) do
    reports
    |> Enum.flat_map(fn {_session_id, report} -> checkable_pid(report) end)
    |> Enum.uniq()
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

  @doc """
  Verdict for one report from a live existence answer (`exists/1`) plus a
  possibly older `starts` snapshot.

  Existence settles the death: a pid that is gone is gone whatever the snapshot
  still remembers, which is what lets a quit session leave the board on the very
  next read. The snapshot only says whether the pid that *is* there is still the
  one that wrote the file. `:error` existence falls back to `decide/2`.
  """
  def decide(report, starts, existence) do
    with {[pid], {:ok, alive}} <- {checkable_pid(report), existence},
         {:ok, exists?} <- Map.fetch(alive, pid) do
      if exists?, do: identity(pid, report.proc_start, starts), else: :dead
    else
      {[], _existence} -> :unverifiable
      # No usable existence answer for this pid: the snapshot alone decides.
      _snapshot_only -> decide(report, starts)
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

  # The process is there; only its start time says whether it is still the one
  # that wrote the file. A pid the snapshot never saw — taken before the process
  # started, or not taken at all — stays unjudged: existence alone cannot tell a
  # survivor from a recycled pid.
  defp identity(pid, proc_start, {:ok, running}) do
    case Map.fetch(running, pid) do
      {:ok, observed} -> compare(proc_start, observed)
      :error -> :unverifiable
    end
  end

  defp identity(_pid, _proc_start, _no_snapshot), do: :unverifiable

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
  a refusal (a bad option, say) by printing a usage error and no rows at all,
  which must not be mistaken for "nothing is running".
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

  @doc """
  Start times of every running process, as `{:ok, %{pid => lstart}}` — or
  `:error` when `ps` could not be run or its output could not be trusted.

  The whole table rather than `-p <pids>`: naming more than one pid puts macOS's
  `ps` on a ~225 ms path, while the full table costs ~35 ms whatever the roster.
  """
  # The exit status says nothing here (`ps` exits non-zero for reasons that have
  # no bearing on the rows it printed), so only the output is read. stderr is
  # merged in so a usage error shows up as an unparseable line rather than an
  # empty, "all dead" answer.
  def snapshot do
    {output, _status} =
      System.cmd("ps", ["-ax", "-o", "pid=,lstart="],
        env: [{"LC_ALL", "C"}],
        stderr_to_stdout: true
      )

    parse(output)
  rescue
    _no_ps -> :error
  catch
    :exit, _reason -> :error
  end

  @doc """
  Which of `pids` exist right now, as `{:ok, %{pid => boolean}}` — or `:error`
  when `kill`'s answer could not be trusted.

  Cheap enough (~2 ms) to ask on every board read, which is what keeps a quit
  session from lingering behind a cached `snapshot/0`.
  """
  def exists(pids) do
    {output, status} =
      System.cmd("/bin/kill", ["-0" | Enum.map(pids, &Integer.to_string/1)],
        env: [{"LC_ALL", "C"}],
        stderr_to_stdout: true
      )

    # A clean exit is `kill`'s own word that every signal was delivered; nothing
    # in the output can override that.
    if status == 0, do: {:ok, all_exist(pids)}, else: parse_kill(output, pids)
  rescue
    _no_kill -> :error
  catch
    :exit, _reason -> :error
  end

  @doc """
  Reads `kill -0`'s complaints into `{:ok, %{pid => boolean}}`: `pids` it says
  nothing about were signalled, so they exist.

  Only "No such process" is death. Any other complaint naming the pid —
  "Operation not permitted" for a process owned by someone else — is proof that
  a process is there to refuse the signal. A line that names no pid of the batch
  fails the whole thing to `:error`: `kill` gives up on a malformed argument
  list with a usage error, and the pids it never got to must not read as dead.
  """
  def parse_kill(output, pids) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, all_exist(pids)}, fn line, {:ok, acc} ->
      case kill_line(String.trim(line)) do
        {:ok, pid, exists?} when is_map_key(acc, pid) -> {:cont, {:ok, %{acc | pid => exists?}}}
        _unattributable -> {:halt, :error}
      end
    end)
  end

  defp all_exist(pids), do: Map.new(pids, &{&1, true})

  # "kill: 4242: No such process"
  defp kill_line("kill: " <> rest) do
    with [pid, reason] <- String.split(rest, ": ", parts: 2),
         {pid, ""} <- Integer.parse(pid) do
      {:ok, pid, reason != "No such process"}
    else
      _unattributable -> :error
    end
  end

  defp kill_line(_line), do: :error

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
