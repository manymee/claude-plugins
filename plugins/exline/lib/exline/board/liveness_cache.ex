defmodule Exline.Board.LivenessCache do
  @moduledoc """
  Keeps the `ps` half of `Exline.Board.Liveness` off the board's request path.

  Liveness asks two questions, and on macOS they cost very different things.
  *Does the pid still exist* is a `kill -0` over the roster, ~2 ms, so it is
  asked on every board read: a session that quits is off the board on the next
  one. *Is it still the same process* needs start times, and reading those costs
  ~35 ms (or ~225 ms, if the pids are named — see `Exline.Board.Liveness`) —
  far too much to spend per request, which is what once put a quarter of a
  second into every `/board.json` and stalled the statusline renders queued
  behind it on `Exline.Sessions`.

  So this server holds the start-time snapshot. A read is answered from the last
  one; a snapshot older than the TTL is served as it stands while a refresh runs
  in the background, so no caller waits for `ps` (the first read of all, with
  nothing cached yet, is the exception). Staleness costs nothing but precision:
  the snapshot only tells a surviving pid from a recycled one, and a pid it has
  never seen reads `:unverifiable` — the render-age heuristic decides that
  session until the refresh settles it — rather than being guessed at.
  """

  use GenServer

  alias Exline.Board.Liveness

  # Long enough that board polls (~1 s) mostly hit a fresh snapshot, short
  # enough that a pid reused within it is a freak occurrence.
  @default_ttl 2_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Verdicts for a `Exline.Board.SelfReport.scan/2` result, in
  `Exline.Board.Liveness.check/1`'s shape: existence asked now, identity from
  the cached snapshot.
  """
  def check(server \\ __MODULE__, reports) when is_map(reports) do
    {starts, existence} =
      case inputs(server) do
        {starts, exists} -> {starts, existence(exists, Liveness.checkable_pids(reports))}
        # A cache that is down must not take the board down with it: with
        # neither answer every verdict reads :unverifiable, never :dead.
        :down -> {:error, :error}
      end

    Map.new(reports, fn {session_id, report} ->
      {session_id, Liveness.decide(report, starts, existence)}
    end)
  end

  defp inputs(server) do
    GenServer.call(server, :inputs)
  catch
    :exit, _reason -> :down
  end

  defp existence(_exists, []), do: {:ok, %{}}

  defp existence(exists, pids) do
    exists.(pids)
  catch
    _kind, _reason -> :error
  end

  @impl true
  # No snapshot is taken here: application start must not wait on `ps`.
  def init(opts) do
    {:ok,
     %{
       ttl: Keyword.get(opts, :ttl, @default_ttl),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
       # Injectable so tests exercise the cache without forking.
       fetch: Keyword.get(opts, :fetch, &Liveness.snapshot/0),
       exists: Keyword.get(opts, :exists, &Liveness.exists/1),
       snapshot: nil,
       fetched_at: nil,
       refresh: nil
     }}
  end

  @impl true
  def handle_call(:inputs, _from, state) do
    state =
      cond do
        # Nothing to serve yet, so this one caller waits out a `ps`.
        is_nil(state.snapshot) -> store(state, fetch(state.fetch))
        stale?(state) -> refresh(state)
        true -> state
      end

    {:reply, {state.snapshot, state.exists}, state}
  end

  @impl true
  def handle_info({:refreshed, snapshot}, state), do: {:noreply, store(state, snapshot)}

  # The refresher is done (or died before reporting, which leaves the snapshot
  # as it was for the next read to retry).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh: ref} = state),
    do: {:noreply, %{state | refresh: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  # A failed snapshot is always due another try; a good one lasts the TTL.
  defp stale?(%{snapshot: :error}), do: true
  defp stale?(state), do: state.now.() - state.fetched_at > state.ttl

  defp store(state, snapshot), do: %{state | snapshot: snapshot, fetched_at: state.now.()}

  # One refresh at a time: board reads arrive far faster than `ps` returns, and
  # every read past the TTL would otherwise fork its own.
  defp refresh(%{refresh: ref} = state) when is_reference(ref), do: state

  defp refresh(state) do
    server = self()
    fetch = state.fetch
    {_pid, ref} = spawn_monitor(fn -> send(server, {:refreshed, fetch(fetch)}) end)
    %{state | refresh: ref}
  end

  # A snapshot that cannot be taken degrades to :error — deaths still land and
  # the surviving pids read :unverifiable — rather than taking the cache down.
  defp fetch(fun) do
    fun.()
  catch
    _kind, _reason -> :error
  end
end
