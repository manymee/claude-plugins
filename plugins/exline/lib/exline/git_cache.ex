defmodule Exline.GitCache do
  @moduledoc """
  Per-cwd cache of `Exline.Git.gather/1` results with a TTL and single-flight.

  The daemon is shared by every Claude Code session, so caching here bounds git
  work to roughly one gather per repository per TTL — independent of how many
  sessions poll or how often. Single-flight ensures that when several sessions
  miss the cache for the same repo at once, only one gather runs and all callers
  receive its result.
  """

  use GenServer
  require Logger

  @default_ttl 3_000
  # Random extra lifetime (ms) added per entry so repos cached together don't
  # all expire on the same tick and stampede git at once.
  @default_jitter 1_000
  # Kill a gather that outlives this deadline: a hung git would otherwise pin
  # its key in-flight forever (every later fetch coalesces onto it and times
  # out) and hold the spawned port's fds. Waiters get nil via the :DOWN path.
  @default_gather_timeout 10_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Return the gathered git fields for `key` (a cwd), from cache or freshly."
  # :infinity, not the default 5s: the server already bounds every fetch with
  # its gather deadline (killed gathers reply nil), and a second, shorter
  # timeout here races it — the caller crashes before the protection applies.
  # A dead server still fails fast (calls to a dead process do not hang).
  def fetch(server \\ __MODULE__, key), do: GenServer.call(server, {:fetch, key}, :infinity)

  @impl true
  def init(opts) do
    {:ok,
     %{
       ttl: Keyword.get(opts, :ttl, @default_ttl),
       jitter: Keyword.get(opts, :jitter, fn -> :rand.uniform(@default_jitter + 1) - 1 end),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
       gather: Keyword.get(opts, :gather, &Exline.Git.gather/1),
       gather_timeout: Keyword.get(opts, :gather_timeout, @default_gather_timeout),
       task_sup: Keyword.get(opts, :task_sup, Exline.ConnSupervisor),
       entries: %{},
       inflight: %{},
       refs: %{}
     }}
  end

  @impl true
  def handle_call({:fetch, key}, from, state) do
    cond do
      fresh?(state, key) ->
        {value, _at} = state.entries[key]
        observe("HIT cwd=#{key}")
        {:reply, value, state}

      Map.has_key?(state.inflight, key) ->
        observe("WAIT cwd=#{key}")
        {:noreply, update_in(state.inflight[key].waiters, &[from | &1])}

      true ->
        {:noreply, start_gather(state, key, from)}
    end
  end

  @impl true
  # Gather task finished: store the value and reply to every coalesced waiter.
  def handle_info({ref, value}, state) when is_reference(ref) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {key, refs} ->
        Process.demonitor(ref, [:flush])
        {%{waiters: waiters}, inflight} = Map.pop(state.inflight, key)
        Enum.each(waiters, &GenServer.reply(&1, value))
        deadline = state.now.() + state.ttl + state.jitter.()
        entries = Map.put(state.entries, key, {value, deadline})
        {:noreply, %{state | refs: refs, inflight: inflight, entries: entries}}
    end
  end

  # Gather task crashed: don't strand waiters, don't poison the cache.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {key, refs} ->
        {%{waiters: waiters}, inflight} = Map.pop(state.inflight, key)
        Enum.each(waiters, &GenServer.reply(&1, nil))
        {:noreply, %{state | refs: refs, inflight: inflight}}
    end
  end

  # Gather deadline elapsed: kill the task if it is still running; the
  # resulting :DOWN message cleans up and replies nil to its waiters.
  def handle_info({:gather_deadline, ref}, state) do
    case state.refs[ref] do
      nil ->
        {:noreply, state}

      key ->
        Logger.warning(
          "exline: git gather for #{key} exceeded #{state.gather_timeout}ms, killing"
        )

        Process.exit(state.inflight[key].pid, :kill)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fresh?(state, key) do
    case state.entries[key] do
      {_value, deadline} -> state.now.() < deadline
      nil -> false
    end
  end

  defp start_gather(state, key, from) do
    gather = state.gather
    observe? = observing?()

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        {us, value} = :timer.tc(fn -> gather.(key) end)
        if observe?, do: Logger.info("git_cache MISS cwd=#{key} gather=#{div(us, 1000)}ms")
        value
      end)

    Process.send_after(self(), {:gather_deadline, task.ref}, state.gather_timeout)

    %{
      state
      | inflight: Map.put(state.inflight, key, %{waiters: [from], pid: task.pid}),
        refs: Map.put(state.refs, task.ref, key)
    }
  end

  # Opt-in per-fetch logging, toggled live via
  # `Application.put_env(:exline, :observe, true|false)`; off by default.
  defp observing?, do: Application.get_env(:exline, :observe, false)
  defp observe(msg), do: observing?() && Logger.info("git_cache " <> msg)
end
