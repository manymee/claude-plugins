defmodule Exline.ListenerTest do
  # Not async: each test binds a real unix socket and writes captures.
  use ExUnit.Case, async: false

  alias Exline.Captures
  alias Exline.Listener
  alias Exline.Sessions

  @thresholds [
    %{percent: 40, message: "Context at {percent}% — handoff soon."},
    %{percent: 70, message: "Context at {percent}% — handoff now."}
  ]

  setup do
    sessions =
      start_supervised!({Sessions, thresholds: @thresholds, repeat_every: nil, name: nil})

    # sun_path caps at ~104 bytes, so keep the socket short and inside the repo.
    File.mkdir_p!("tmp")
    path = Path.expand("tmp/l#{System.unique_integer([:positive])}.sock")
    start_supervised!({Listener, socket_path: path, sessions: sessions, name: nil})
    on_exit(fn -> File.rm(path) end)

    %{path: path, sessions: sessions, session: "sess-#{System.unique_integer([:positive])}"}
  end

  defp request(path, message) when is_map(message), do: request(path, JSON.encode!(message))

  defp request(path, payload) when is_binary(payload) do
    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    :ok = :gen_tcp.send(socket, payload <> <<0>>)
    response = read_response(socket, [])
    :gen_tcp.close(socket)
    response
  end

  defp read_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read_response(socket, [acc, data])
      {:error, _reason} -> IO.iodata_to_binary(acc)
    end
  end

  # A statusline payload without a workspace, so no git work is involved.
  defp statusline(session, pct) do
    %{
      "session_id" => session,
      "version" => "2.1.140",
      "context_window" => %{"used_percentage" => pct}
    }
  end

  defp hook(session, event), do: %{"exline" => "hook", "event" => event, "session_id" => session}

  defp ctl(session, action),
    do: %{"exline" => "ctl", "session_id" => session, "action" => action}

  describe "statusline renders" do
    test "still render and now feed the session tracker", ctx do
      response = request(ctx.path, statusline(ctx.session, 45))

      assert response =~ "v2.1.140"
      assert response =~ "Ctx Used: "
      assert response =~ "45.0%"
      assert Sessions.status(ctx.sessions, ctx.session) == %{enabled: true, pct: 45}
    end

    test "are tracked without a badge while reporting is on", ctx do
      refute request(ctx.path, statusline(ctx.session, 45)) =~ "ctx-report off"
    end

    test "ignore a payload with no session id", ctx do
      response = request(ctx.path, %{"version" => "2.1.140"})
      assert response =~ "v2.1.140"
      refute response =~ "ctx-report off"
    end
  end

  describe "hook queries" do
    test "reply empty below the first threshold", ctx do
      request(ctx.path, statusline(ctx.session, 20))
      assert request(ctx.path, hook(ctx.session, "Stop")) == ""
    end

    test "report a crossed threshold once, echoing the event name", ctx do
      request(ctx.path, statusline(ctx.session, 45))

      assert JSON.decode!(request(ctx.path, hook(ctx.session, "Stop"))) == %{
               "systemMessage" => "[exline] Context at 45% — handoff soon.",
               "hookSpecificOutput" => %{
                 "hookEventName" => "Stop",
                 "additionalContext" => "[exline] Context at 45% — handoff soon."
               }
             }

      assert request(ctx.path, hook(ctx.session, "Stop")) == ""
    end

    test "echo the PostToolBatch event name", ctx do
      request(ctx.path, statusline(ctx.session, 75))
      response = JSON.decode!(request(ctx.path, hook(ctx.session, "PostToolBatch")))

      assert response["hookSpecificOutput"]["hookEventName"] == "PostToolBatch"

      assert response["hookSpecificOutput"]["additionalContext"] ==
               "[exline] Context at 75% — handoff now."
    end

    test "reply empty for an unknown session", ctx do
      assert request(ctx.path, hook("never-seen", "Stop")) == ""
    end

    test "reply empty for an unknown or missing event", ctx do
      request(ctx.path, statusline(ctx.session, 45))
      assert request(ctx.path, hook(ctx.session, "SessionStart")) == ""
      assert request(ctx.path, %{"exline" => "hook", "session_id" => ctx.session}) == ""
      assert request(ctx.path, %{"exline" => "hook", "event" => "Stop"}) == ""
    end

    test "are never captured as statusline payloads", ctx do
      request(ctx.path, statusline(ctx.session, 45))
      newest = Captures.list() |> List.first()

      request(ctx.path, hook(ctx.session, "Stop"))
      request(ctx.path, ctl(ctx.session, "status"))

      assert Captures.list() |> List.first() == newest
    end
  end

  describe "ctl messages" do
    test "off silences hook reports and badges the render", ctx do
      request(ctx.path, statusline(ctx.session, 45))

      assert JSON.decode!(request(ctx.path, ctl(ctx.session, "off"))) == %{
               "ok" => true,
               "context_report" => "off",
               "used_percentage" => 45
             }

      assert request(ctx.path, hook(ctx.session, "Stop")) == ""

      # Even climbing past the next threshold stays silent, and the render says so.
      assert request(ctx.path, statusline(ctx.session, 75)) =~ "ctx-report off"
      assert request(ctx.path, hook(ctx.session, "Stop")) == ""
    end

    test "on restores reporting", ctx do
      request(ctx.path, statusline(ctx.session, 45))
      request(ctx.path, ctl(ctx.session, "off"))

      assert JSON.decode!(request(ctx.path, ctl(ctx.session, "on"))) == %{
               "ok" => true,
               "context_report" => "on",
               "used_percentage" => 45
             }

      refute request(ctx.path, statusline(ctx.session, 45)) =~ "ctx-report off"
      assert request(ctx.path, hook(ctx.session, "Stop")) != ""
    end

    test "status reports state without changing or claiming anything", ctx do
      request(ctx.path, statusline(ctx.session, 45))

      assert JSON.decode!(request(ctx.path, ctl(ctx.session, "status"))) == %{
               "ok" => true,
               "context_report" => "on",
               "used_percentage" => 45
             }

      assert request(ctx.path, hook(ctx.session, "Stop")) != ""
    end

    test "status of an unseen session reports enabled with a null percentage", ctx do
      assert JSON.decode!(request(ctx.path, ctl("never-seen", "status"))) == %{
               "ok" => true,
               "context_report" => "on",
               "used_percentage" => nil
             }
    end

    test "reject an unknown action", ctx do
      assert JSON.decode!(request(ctx.path, ctl(ctx.session, "toggle"))) == %{
               "ok" => false,
               "error" => "unknown action"
             }
    end
  end

  describe "shutdown" do
    test "removes the socket file so the next start finds a clean path", ctx do
      assert File.exists?(ctx.path)
      stop_supervised!(Listener)
      refute File.exists?(ctx.path)
    end
  end

  describe "malformed input" do
    test "rejects an unknown exline message", ctx do
      assert JSON.decode!(request(ctx.path, %{"exline" => "nope"})) == %{
               "ok" => false,
               "error" => "unknown message"
             }
    end

    @tag :capture_log
    test "answers invalid json with the plain error string", ctx do
      assert request(ctx.path, "{not json") == "exline: invalid json"
    end
  end
end
