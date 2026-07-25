defmodule Exline.Sessions do
  @moduledoc """
  Per-session context-usage tracker behind the handoff reports.

  The statusline is the one thing Claude Code polls continuously, so its render
  doubles as the sampler: every payload feeds that session's context percentage
  in here. Hooks then ask, once per Stop/PostToolBatch, whether the session has
  crossed a threshold it has not been told about yet — which keeps the nagging
  to one message per threshold instead of one per hook fire.

  A report claims the threshold it fired for. The claim follows the percentage
  back *down* on the next update, so after a `/compact` the same thresholds
  re-arm and report again on the way back up.

  With `repeat_every` set, the top threshold's message keeps firing every that
  many percent past it (synthetic thresholds at top + k·step), so a session
  sailing past the last configured tier is not left in silence.
  """

  use GenServer

  # Claude Code never tells us a session ended, so entries are dropped once
  # nothing has been heard from them for this long.
  @stale_after :timer.hours(6)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Record a statusline render for `session_id`: `pct` is the context percentage,
  `extra` optionally carries the board fields sampled from the same payload
  (`:api_ms`, `:name`, `:cwd`, `:model`).
  """
  def update(server \\ __MODULE__, session_id, pct, extra \\ %{}),
    do: GenServer.cast(server, {:update, session_id, pct, extra})

  @doc """
  Feed a hook event into the session's board activity state. `event` is
  `:stop`, `:post_tool_batch`, `:user_prompt_submit`,
  `{:notification, :permission}` or `{:notification, :idle}`.
  """
  def hook_event(server \\ __MODULE__, session_id, event),
    do: GenServer.cast(server, {:hook_event, session_id, event})

  @doc """
  The session board roster: one row per tracked session with its classified
  activity status, ready for JSON encoding. Sorted by name for stable output.
  """
  def board(server \\ __MODULE__), do: GenServer.call(server, :board)

  @doc """
  Claim the pending threshold report for `session_id`, or `nil` when there is
  nothing to say (unknown session, reporting off, or no newly crossed
  threshold). Claiming marks the threshold reported, so the next call is silent
  until a higher one is crossed.

  Returns `%{percent: threshold_percent, message: message, pct: current_pct}`;
  the message has its `{percent}` placeholder filled with the *current*
  percentage, not the threshold's.
  """
  def hook_report(server \\ __MODULE__, session_id),
    do: GenServer.call(server, {:hook_report, session_id})

  @doc "Turn threshold reporting for `session_id` on or off."
  def set_enabled(server \\ __MODULE__, session_id, enabled?),
    do: GenServer.call(server, {:set_enabled, session_id, enabled?})

  @doc """
  Reporting state of `session_id` as `%{enabled: boolean, pct: number | nil}`.
  Unknown sessions read as enabled with no percentage yet.
  """
  def status(server \\ __MODULE__, session_id), do: GenServer.call(server, {:status, session_id})

  @impl true
  def init(opts) do
    thresholds = opts[:thresholds] || Exline.SessionConfig.thresholds()

    {:ok,
     %{
       thresholds: Enum.sort_by(thresholds, & &1.percent),
       repeat_every: Keyword.get(opts, :repeat_every, Exline.SessionConfig.repeat_every()),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
       sessions: %{}
     }}
  end

  @impl true
  def handle_cast({:update, session_id, pct, extra}, state) do
    now = state.now.()
    entry = entry(state, session_id)
    threshold = crossed(state, pct)

    # Follow a falling percentage down: once the context drops below what was
    # last reported (compaction, a cleared session), lower the claim so the
    # thresholds above it fire again.
    reported =
      if entry.reported && (is_nil(threshold) or threshold.percent < entry.reported),
        do: threshold && threshold.percent,
        else: entry.reported

    entry = %{
      entry
      | pct: pct,
        reported: reported,
        updated_at: now,
        board: Exline.Board.State.render(entry.board, extra[:api_ms], seconds(now)),
        display: Map.merge(entry.display, Map.take(extra, [:name, :cwd, :model]), &keep_known/3)
    }

    {:noreply, prune(%{state | sessions: Map.put(state.sessions, session_id, entry)}, now)}
  end

  def handle_cast({:hook_event, session_id, event}, state) do
    now = state.now.()
    entry = entry(state, session_id)
    board = apply_event(entry.board, event, seconds(now))
    entry = %{entry | board: board, updated_at: now}
    {:noreply, %{state | sessions: Map.put(state.sessions, session_id, entry)}}
  end

  @impl true
  def handle_call({:hook_report, session_id}, _from, state) do
    entry = state.sessions[session_id]
    threshold = entry && entry.enabled && crossed(state, entry.pct)

    cond do
      !threshold ->
        {:reply, nil, state}

      entry.reported && threshold.percent <= entry.reported ->
        {:reply, nil, state}

      true ->
        report = %{
          percent: threshold.percent,
          message: interpolate(threshold.message, entry.pct),
          pct: entry.pct
        }

        {:reply, report, put_in(state.sessions[session_id].reported, threshold.percent)}
    end
  end

  def handle_call({:set_enabled, session_id, enabled?}, _from, state) do
    entry = %{entry(state, session_id) | enabled: enabled?, updated_at: state.now.()}
    {:reply, :ok, %{state | sessions: Map.put(state.sessions, session_id, entry)}}
  end

  def handle_call({:status, session_id}, _from, state) do
    case state.sessions[session_id] do
      nil -> {:reply, %{enabled: true, pct: nil}, state}
      entry -> {:reply, %{enabled: entry.enabled, pct: entry.pct}, state}
    end
  end

  def handle_call(:board, _from, state) do
    now = seconds(state.now.())

    rows =
      state.sessions
      |> Enum.map(fn {session_id, entry} ->
        {status, reason} = Exline.Board.State.classify(entry.board, now)

        %{
          session_id: session_id,
          name: entry.display[:name],
          cwd: entry.display[:cwd],
          model: entry.display[:model],
          status: status,
          reason: reason,
          since_s: Exline.Board.State.since(entry.board, status, now),
          context_pct: entry.pct,
          last_render_age_s: now - entry.board.last_render_at
        }
      end)
      |> Enum.sort_by(&{&1.name || "", &1.session_id})

    {:reply, rows, state}
  end

  # An entry may be created by a control message or hook before the first
  # statusline payload arrives, hence a nil percentage.
  defp entry(state, session_id) do
    now = state.now.()

    state.sessions[session_id] ||
      %{
        pct: nil,
        reported: nil,
        enabled: true,
        updated_at: now,
        board: Exline.Board.State.new(seconds(now)),
        display: %{}
      }
  end

  # The board model thinks in seconds; the tracker clock is milliseconds.
  defp seconds(ms), do: div(ms, 1000)

  # A payload missing a display field must not blank a previously seen value.
  defp keep_known(_key, old, new), do: new || old

  defp apply_event(board, :stop, now), do: Exline.Board.State.stop(board, now)

  defp apply_event(board, :post_tool_batch, now),
    do: Exline.Board.State.post_tool_batch(board, now)

  defp apply_event(board, :user_prompt_submit, now),
    do: Exline.Board.State.user_prompt_submit(board, now)

  defp apply_event(board, {:notification, kind}, now) when kind in [:permission, :idle],
    do: Exline.Board.State.notification(board, kind, now)

  defp apply_event(board, _unknown, _now), do: board

  # Highest threshold at or below `pct`, or nil when none is reached yet.
  defp crossed(_state, pct) when not is_number(pct), do: nil

  defp crossed(state, pct) do
    state.thresholds
    |> Enum.take_while(&(&1.percent <= pct))
    |> List.last()
    |> step_past_top(state, pct)
  end

  defp step_past_top(nil, _state, _pct), do: nil

  defp step_past_top(threshold, %{repeat_every: step} = state, pct) when is_integer(step) do
    top = List.last(state.thresholds)

    if threshold.percent == top.percent do
      %{threshold | percent: top.percent + div(trunc(pct) - top.percent, step) * step}
    else
      threshold
    end
  end

  defp step_past_top(threshold, _state, _pct), do: threshold

  defp interpolate(message, pct), do: String.replace(message, "{percent}", to_string(pct))

  defp prune(state, now) do
    cutoff = now - @stale_after

    %{
      state
      | sessions: Map.reject(state.sessions, fn {_id, entry} -> entry.updated_at < cutoff end)
    }
  end
end
