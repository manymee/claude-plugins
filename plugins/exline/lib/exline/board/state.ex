defmodule Exline.Board.State do
  @moduledoc """
  Pure per-session activity model for the session board: fold incoming signals
  into a state map, classify it as working / attention / idle / stale / gone.

  One instance of this state per session_id; sessions are independent.
  `Exline.Sessions` owns the instances and feeds them; this module does no I/O.

  Signals:

    * statusline render every ~1s per open session — `render/3` with the
      payload's cumulative `cost.total_api_duration_ms`; advancing between
      consecutive renders means an API call is in flight
    * PostToolBatch / Stop hook beacons
    * UserPromptSubmit hook (opens the turn)
    * Notification hook — "needs permission" vs "waiting for input" (fires
      after ~60s idle), distinguished by message content
    * renders stopping entirely — session closed (stale, then gone), but only
      for a session whose process could not be checked (see below)
    * the session's own status file, read by `Exline.Board.SelfReport` and
      passed to `classify/3` — what the session says about itself, which
      outranks everything the signals above can only guess at

  The hook-and-render signals are a heuristic; the self-report is not, so a
  session that has one is classified from it and the heuristic is demoted to a
  parenthetical note whenever the two disagree. Sessions without one — an older
  CLI, or a file that failed to parse — run on the heuristic alone.

  Liveness is not this module's to decide when it can be established outright.
  `Exline.Board.Liveness` asks the OS whether the process that wrote the status
  file is still running; a report carrying `alive: true` therefore skips stale
  and gone entirely, however long ago the session last rendered — a session
  parked in a hidden pane is open, not gone. Stale and gone are left to sessions
  whose process cannot be checked, and `Exline.Sessions` drops a confirmed-dead
  session from the board rather than classifying it.

  The self-report closes three of the heuristic's blind spots outright while a
  session file matches: an Esc interrupt (no hook fires, so the turn used to
  read working until the idle-60s notification), a permission approval (no hook
  fires, so attention used to persist until the tool batch ended), and a daemon
  restart (turn state wiped, so classification used to fall back to the api-diff
  guess). What stays (see proto/board_state.exs to experience the heuristic):

    * status files are never heartbeated — a killed session leaves one behind
      forever, so a report alone can never keep a session alive; only a checked
      process (`alive: true`) outranks stale and gone
    * the file format is a private contract (peerProtocol 1); an absent file,
      an unparseable one or an unknown status word falls back to the heuristic
    * sessions on a CLI older than the status files write none at all
    * on the heuristic, during a long-running tool the api counter freezes →
      the open turn carries the working classification, with a degrading reason
      note

  The interactive workbench for these rules is `proto/board_state.exs`
  (`mix run --no-start proto/board_state.exs`) — it drives this module
  directly, so workbench and production logic cannot drift apart.
  """

  @stale_after 3
  @gone_after 10
  @api_window 3
  @suspicious_after 15

  def thresholds,
    do: %{
      stale_after: @stale_after,
      gone_after: @gone_after,
      api_window: @api_window,
      suspicious_after: @suspicious_after
    }

  @doc "Fresh state for a session first seen at `now` (seconds, injectable clock)."
  def new(now) do
    %{
      created_at: now,
      last_render_at: now,
      api_ms: nil,
      api_advanced_at: nil,
      # true | false | :unknown — :unknown means we have no turn state
      # (session predates daemon start, or daemon restarted mid-turn)
      turn_open: :unknown,
      turn_open_since: nil,
      pending_permission: nil,
      hooks: %{}
    }
  end

  ## Events

  @doc "Statusline render; `api_ms` = cumulative total_api_duration_ms from the payload."
  def render(s, api_ms, now) do
    advanced = is_integer(s.api_ms) and api_ms > s.api_ms
    s = %{s | last_render_at: now, api_ms: api_ms}
    if advanced, do: %{s | api_advanced_at: now, pending_permission: nil}, else: s
  end

  def user_prompt_submit(s, now) do
    %{s | turn_open: true, turn_open_since: now, pending_permission: nil}
    |> put_hook(:user_prompt_submit, now)
  end

  def post_tool_batch(s, now) do
    %{s | turn_open: true, turn_open_since: s.turn_open_since || now, pending_permission: nil}
    |> put_hook(:post_tool_batch, now)
  end

  def stop(s, now) do
    %{s | turn_open: false, turn_open_since: nil, pending_permission: nil}
    |> put_hook(:stop, now)
  end

  def notification(s, :permission, now) do
    %{s | pending_permission: now}
    |> put_hook(:notif_permission, now)
  end

  # "Claude is waiting for your input" — fires after ~60s idle, even when no
  # Stop was seen (Esc interrupt), so it doubles as a late turn-closer
  def notification(s, :idle, now) do
    %{s | turn_open: false, turn_open_since: nil}
    |> put_hook(:notif_idle, now)
  end

  defp put_hook(s, name, now), do: %{s | hooks: Map.put(s.hooks, name, now)}

  ## Classification

  @doc """
  Returns `{status, reason}`; status is :working | :attention | :idle | :stale
  | :gone.

  `report` is this session's entry from `Exline.Board.SelfReport.scan/2`, or
  `nil` when it has none. Render age decides first — a status file outlives the
  session that wrote it, so it can never keep a dead session alive on its own.

  A report marked `alive: true` is the exception: its writing process has been
  found running (`Exline.Board.Liveness`), which settles liveness better than
  render age can, so stale and gone are skipped and the file decides.
  """
  def classify(s, now, report \\ nil) do
    render_age = now - s.last_render_at

    cond do
      is_map(report) and report[:alive] ->
        self_reported(s, now, report)

      render_age >= @gone_after ->
        {:gone, "no renders for #{render_age}s — session closed"}

      render_age >= @stale_after ->
        {:stale, "no renders for #{render_age}s"}

      is_map(report) ->
        self_reported(s, now, report)

      true ->
        heuristic(s, now)
    end
  end

  @doc """
  Status and reason for a session known only from its status file — it is
  running (verified), but exline has no render feed for it, so there is no
  heuristic to cross-check against.
  """
  def from_report(report), do: {self_status(report.status), self_reason(report)}

  defp self_reported(s, now, report) do
    status = self_status(report.status)
    {guess, guess_reason} = heuristic(s, now)

    note =
      if guess == status, do: "", else: " (heuristic: #{guess} — #{guess_reason})"

    {status, self_reason(report) <> note}
  end

  defp self_status(:busy), do: :working
  defp self_status(:waiting), do: :attention
  defp self_status(:idle), do: :idle

  defp self_reason(%{status: :waiting, waiting_for: what}) when is_binary(what),
    do: "self-reported waiting: #{what}"

  defp self_reason(%{status: status}), do: "self-reported #{status}"

  defp heuristic(s, now) do
    cond do
      s.pending_permission ->
        {:attention, "permission prompt unanswered for #{now - s.pending_permission}s"}

      s.turn_open == true ->
        {:working, "turn open — " <> api_note(s, now)}

      s.turn_open == :unknown and api_recent?(s, now) ->
        {:working, "no turn state — api advanced #{now - s.api_advanced_at}s ago"}

      s.turn_open == :unknown ->
        {:idle, "no turn state — api quiet"}

      api_recent?(s, now) and api_after_close?(s) ->
        {:idle, "turn closed — but api advanced after close?! (background call?)"}

      true ->
        {:idle, "turn closed by " <> closer(s)}
    end
  end

  @doc """
  Seconds the session has been in `status` (as returned by `classify/3`),
  anchored to the event that put it there.

  With a `report`, the session's own status timestamp is the anchor — it knows
  when it changed state better than any hook we happened to see. Stale and gone
  are render-age states, so they stay anchored to the last render either way.
  """
  def since(s, status, now, report \\ nil) do
    now - (anchor(s, status, now, report) || now)
  end

  # Stale and gone are render-age states; nothing the session last said about
  # itself can date them.
  defp anchor(s, status, _now, _report) when status not in [:working, :attention, :idle],
    do: s.last_render_at

  defp anchor(_s, _status, now, %{age_s: age_s}) when is_integer(age_s), do: now - age_s

  defp anchor(s, :working, _now, _report),
    do: s.turn_open_since || s.api_advanced_at || s.created_at

  defp anchor(s, :attention, _now, _report), do: s.pending_permission
  defp anchor(s, :idle, _now, _report), do: latest_closer(s) || s.created_at

  defp latest_closer(s) do
    case Enum.reject([s.hooks[:stop], s.hooks[:notif_idle]], &is_nil/1) do
      [] -> nil
      closers -> Enum.max(closers)
    end
  end

  defp api_recent?(s, now),
    do: is_integer(s.api_advanced_at) and now - s.api_advanced_at <= @api_window

  defp api_after_close?(s) do
    closed_at = [s.hooks[:stop], s.hooks[:notif_idle]] |> Enum.reject(&is_nil/1)
    is_integer(s.api_advanced_at) and closed_at != [] and s.api_advanced_at > Enum.max(closed_at)
  end

  defp api_note(s, now) do
    cond do
      api_recent?(s, now) ->
        "api advancing"

      is_integer(s.api_advanced_at) ->
        quiet = now - s.api_advanced_at

        if quiet >= @suspicious_after,
          do: "api quiet #{quiet}s — suspiciously long (interrupted? hung tool?)",
          else: "api quiet #{quiet}s (tool running?)"

      true ->
        "api not seen advancing yet"
    end
  end

  defp closer(s) do
    stop = s.hooks[:stop]
    idle = s.hooks[:notif_idle]

    cond do
      idle && (!stop || idle > stop) -> "idle-60s notification"
      stop -> "Stop"
      true -> "?"
    end
  end
end
