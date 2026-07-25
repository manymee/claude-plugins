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
    * renders stopping entirely — session closed (stale, then gone)

  Known blind spots (accepted, see proto/board_state.exs to experience them):

    * during a long-running tool the api counter freezes → the open turn
      carries the working classification, with a degrading reason note
    * Esc interrupt fires no hook → misclassified working until the idle-60s
      notification closes the turn
    * permission approval fires no hook → attention persists until the tool
      batch ends (a PreToolUse registration would clear it at approval time)
    * daemon restart wipes turn state → falls back to the api-diff heuristic
      until the next hook arrives

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

  @doc "Returns `{status, reason}`; status is :working | :attention | :idle | :stale | :gone."
  def classify(s, now) do
    render_age = now - s.last_render_at

    cond do
      render_age >= @gone_after ->
        {:gone, "no renders for #{render_age}s — session closed"}

      render_age >= @stale_after ->
        {:stale, "no renders for #{render_age}s"}

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
  Seconds the session has been in `status` (as returned by `classify/2`),
  anchored to the event that put it there.
  """
  def since(s, status, now) do
    anchor =
      case status do
        :working -> s.turn_open_since || s.api_advanced_at || s.created_at
        :attention -> s.pending_permission
        :idle -> latest_closer(s) || s.created_at
        _stale_or_gone -> s.last_render_at
      end

    now - (anchor || now)
  end

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
