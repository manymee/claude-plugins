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
  The session board roster: one row per live session with its classified
  activity status, ready for JSON encoding. Sorted by name for stable output.

  Membership follows Claude Code's own session registry (`Exline.Board.SelfReport`)
  wherever it can: a session whose registry file names a process that is no
  longer running has quit, so it leaves the board — and this tracker — at once,
  and a running session appears even if no statusline render was ever seen from
  it. Only sessions the registry cannot speak for fall back to render age.
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
       # nil resolves to Exline.Board.SelfReport.default_dir() per board call,
       # so CLAUDE_CONFIG_DIR is honoured even if it changes under the daemon.
       self_report_dir:
         Keyword.get(opts, :self_report_dir, Application.get_env(:exline, :self_report_dir)),
       # Injectable so tests decide liveness without forking ps.
       liveness: Keyword.get(opts, :liveness, &Exline.Board.Liveness.check/1),
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
    # One directory scan and one liveness check for the whole roster, not one
    # per session.
    dir = state.self_report_dir || Exline.Board.SelfReport.default_dir()
    reports = Exline.Board.SelfReport.scan(dir)
    liveness = state.liveness.(reports)

    {tracked, kept} = tracked_rows(state.sessions, reports, liveness, now)

    rows =
      (tracked ++ registry_rows(state.sessions, reports, liveness))
      |> Enum.sort_by(&{&1.name || "", &1.session_id})

    {:reply, rows, %{state | sessions: kept}}
  end

  # Sessions exline has render data for. A dead one is dropped from the board
  # and from the tracker — waiting out the 6 h prune would keep a session the
  # user already quit on screen for hours.
  defp tracked_rows(sessions, reports, liveness, now) do
    gone_after = Exline.Board.State.thresholds().gone_after

    Enum.reduce(sessions, {[], %{}}, fn {session_id, entry}, {rows, kept} ->
      report = reports[session_id]
      render_age = now - entry.board.last_render_at

      # Renders fresher than the gone threshold outrank the verdict: the session
      # was there moments ago, so the process check must have raced it.
      if liveness[session_id] == :dead and render_age >= gone_after do
        {rows, kept}
      else
        row = tracked_row(session_id, entry, report, liveness[session_id], now, render_age)
        {[row | rows], Map.put(kept, session_id, entry)}
      end
    end)
  end

  defp tracked_row(session_id, entry, report, live, now, render_age) do
    # A verified-alive process settles liveness, so the file's status stands
    # however long the pane has been parked.
    report = if report && live == :alive, do: Map.put(report, :alive, true), else: report
    {status, reason} = Exline.Board.State.classify(entry.board, now, report)

    %{
      session_id: session_id,
      name: entry.display[:name],
      cwd: entry.display[:cwd],
      model: entry.display[:model],
      status: status,
      reason: reason,
      since_s: Exline.Board.State.since(entry.board, status, now, report),
      context_pct: entry.pct,
      last_render_age_s: render_age
    }
  end

  # Live sessions exline has no render data for — never seen, or parked long
  # enough to have been pruned. Everything but the file's own fields is unknown.
  defp registry_rows(sessions, reports, liveness) do
    for {session_id, report} <- reports,
        liveness[session_id] == :alive,
        not Map.has_key?(sessions, session_id) do
      {status, reason} = Exline.Board.State.from_report(report)

      %{
        session_id: session_id,
        name: report.name,
        cwd: report.cwd,
        model: nil,
        status: status,
        reason: reason <> " — no statusline feed",
        since_s: report.age_s || 0,
        context_pct: nil,
        last_render_age_s: nil
      }
    end
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
