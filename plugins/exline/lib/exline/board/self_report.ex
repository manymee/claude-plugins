defmodule Exline.Board.SelfReport do
  @moduledoc """
  Claude Code's own status files, read as the session board's primary status
  source.

  Each running session writes `<sessions dir>/<pid>.json` carrying its
  `sessionId` — the same id exline keys sessions on — and a self-reported
  `status` of "busy", "idle" or "waiting". That is what the session knows about
  itself, so it beats anything `Exline.Board.State` can infer from the outside:
  no hook has to fire, and an Esc interrupt shows up at once.

  The file is written only when the status changes, never as a heartbeat, so a
  killed session leaves its file behind indefinitely. These reports therefore
  say only *what* a session is doing, never *whether* it is still there —
  liveness stays with render age in `Exline.Board.State`.

  The format is a private contract (peerProtocol 1). Anything unexpected —
  unreadable file, invalid JSON, missing `sessionId`, an unknown status word —
  drops that file, leaving the session on the heuristic.
  """

  @statuses %{"busy" => :busy, "idle" => :idle, "waiting" => :waiting}

  @doc "Where the session status files are looked up."
  def default_dir do
    Path.join(System.get_env("CLAUDE_CONFIG_DIR") || Path.expand("~/.claude"), "sessions")
  end

  @doc """
  Every usable report in `dir`, as `session_id => %{status:, age_s:,
  waiting_for:}`. `age_s` is how long ago the status was last written, or `nil`
  when the file carries no usable timestamp.

  A missing or unreadable directory yields `%{}`, as does a directory holding
  nothing usable. Only `*.json` entries are read, non-recursively — the `.key`
  sidecars are none of our business.

  Two files can name the same session for a moment (a resume in a new process);
  the newest `statusUpdatedAt` wins.
  """
  def scan(dir \\ default_dir(), now_ms \\ System.system_time(:millisecond)) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(&read(Path.join(dir, &1), now_ms))
        |> Enum.reduce(%{}, &keep_newest/2)
        |> Map.new(fn {session_id, {_written_at, report}} -> {session_id, report} end)

      {:error, _no_dir} ->
        %{}
    end
  end

  defp read(path, now_ms) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"sessionId" => session_id, "status" => status} = data} <- JSON.decode(raw),
         true <- is_binary(session_id),
         {:ok, kind} <- Map.fetch(@statuses, status) do
      [entry(session_id, kind, data, now_ms)]
    else
      _unusable -> []
    end
  end

  defp entry(session_id, kind, data, now_ms) do
    written_at = if is_integer(data["statusUpdatedAt"]), do: data["statusUpdatedAt"]

    report = %{
      status: kind,
      age_s: written_at && max(div(now_ms - written_at, 1000), 0),
      waiting_for: waiting_for(data)
    }

    {session_id, written_at || 0, report}
  end

  defp waiting_for(%{"waitingFor" => text}) when is_binary(text) and text != "", do: text
  defp waiting_for(_data), do: nil

  defp keep_newest({session_id, written_at, report}, acc) do
    case acc[session_id] do
      {seen_at, _report} when seen_at >= written_at -> acc
      _older_or_first -> Map.put(acc, session_id, {written_at, report})
    end
  end
end
