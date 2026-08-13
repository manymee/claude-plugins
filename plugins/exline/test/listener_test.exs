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
    listener = start_supervised!({Listener, socket_path: path, sessions: sessions, name: nil})
    on_exit(fn -> File.rm(path) end)

    %{
      path: path,
      listener: listener,
      sessions: sessions,
      session: "sess-#{System.unique_integer([:positive])}"
    }
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

  describe "session board" do
    defp board_row(path, session) do
      %{"sessions" => rows} = JSON.decode!(request(path, %{"exline" => "board"}))
      Enum.find(rows, &(&1["session_id"] == session))
    end

    defp rich_statusline(session) do
      statusline(session, 42)
      |> Map.merge(%{
        "session_name" => "my task",
        "cwd" => "/Users/x/proj",
        "model" => %{"display_name" => "Fable 5"},
        "cost" => %{"total_api_duration_ms" => 5000}
      })
    end

    test "renders feed the board display fields", ctx do
      request(ctx.path, rich_statusline(ctx.session))
      row = board_row(ctx.path, ctx.session)

      assert %{
               "name" => "my task",
               "cwd" => "/Users/x/proj",
               "model" => "Fable 5",
               "context_pct" => 42,
               "status" => "idle",
               "last_render_age_s" => 0
             } = row
    end

    test "UserPromptSubmit opens the turn and stays a silent hook reply", ctx do
      request(ctx.path, rich_statusline(ctx.session))
      assert request(ctx.path, hook(ctx.session, "UserPromptSubmit")) == ""
      assert %{"status" => "working"} = board_row(ctx.path, ctx.session)

      assert request(ctx.path, hook(ctx.session, "Stop")) != ""
      assert %{"status" => "idle"} = board_row(ctx.path, ctx.session)
    end

    test "a permission notification needs attention until activity resumes", ctx do
      request(ctx.path, rich_statusline(ctx.session))

      notification =
        hook(ctx.session, "Notification")
        |> Map.put("notification_type", "permission_prompt")
        |> Map.put("message", "Permission required: Bash(npm test)")

      assert request(ctx.path, notification) == ""
      assert %{"status" => "attention"} = board_row(ctx.path, ctx.session)

      request(ctx.path, hook(ctx.session, "PostToolBatch"))
      assert %{"status" => "working"} = board_row(ctx.path, ctx.session)
    end

    test "an idle notification reads as ready", ctx do
      request(ctx.path, rich_statusline(ctx.session))
      request(ctx.path, hook(ctx.session, "UserPromptSubmit"))

      notification =
        hook(ctx.session, "Notification") |> Map.put("notification_type", "idle_prompt")

      request(ctx.path, notification)
      assert %{"status" => "idle"} = board_row(ctx.path, ctx.session)
    end

    test "notification kinds fall back to message text when untyped", ctx do
      request(ctx.path, rich_statusline(ctx.session))

      notification =
        hook(ctx.session, "Notification")
        |> Map.put("message", "Claude needs your permission to use Bash")

      request(ctx.path, notification)
      assert %{"status" => "attention"} = board_row(ctx.path, ctx.session)
    end

    test "an unrecognized notification changes nothing", ctx do
      request(ctx.path, rich_statusline(ctx.session))
      request(ctx.path, hook(ctx.session, "UserPromptSubmit"))

      notification =
        hook(ctx.session, "Notification")
        |> Map.put("notification_type", "auth_success")
        |> Map.put("message", "something else")

      assert request(ctx.path, notification) == ""
      assert %{"status" => "working"} = board_row(ctx.path, ctx.session)
    end

    test "the roster covers every session, sorted by name", ctx do
      request(ctx.path, Map.put(rich_statusline("s-b"), "session_name", "bravo"))
      request(ctx.path, Map.put(rich_statusline("s-a"), "session_name", "alpha"))

      %{"sessions" => rows} = JSON.decode!(request(ctx.path, %{"exline" => "board"}))
      assert Enum.map(rows, & &1["name"]) == ["alpha", "bravo"]
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

  describe "connection bursts" do
    # Regression: with gen_tcp's default backlog of 5, a burst that arrived
    # while the accept loop was starved of CPU overflowed the listen queue and
    # every further connect was refused instantly — every session's statusline
    # went blank at once. Suspending the listener is the same condition without
    # the CPU starvation: nothing drains the queue while the burst arrives.
    test "queue up while the accept loop is not draining them", ctx do
      :sys.suspend(ctx.listener)

      results =
        try do
          for _ <- 1..20,
              do: :gen_tcp.connect({:local, ctx.path}, 0, [:binary, active: false], 2_000)
        after
          :sys.resume(ctx.listener)
        end

      refused = Enum.reject(results, &match?({:ok, _socket}, &1))
      assert refused == [], "#{length(refused)}/20 connects refused: #{inspect(refused)}"

      # And the queue really was a queue: every waiting connect gets served once
      # the loop runs again.
      for {:ok, socket} <- results do
        :ok = :gen_tcp.send(socket, JSON.encode!(statusline(ctx.session, 45)) <> <<0>>)
        assert read_response(socket, []) =~ "45.0%"
        :gen_tcp.close(socket)
      end
    end
  end

  describe "leaked link exits" do
    # Regression: a socket port left linked to the listener (handover raced the
    # serving task) delivered {:EXIT, port, :normal} on close and the missing
    # handle_info clause killed the listener — a daemon-wide statusline outage.
    test "an :EXIT message from a lingering port does not kill the listener", ctx do
      port = Port.open({:spawn, "cat"}, [:binary])
      send(ctx.listener, {:EXIT, port, :normal})

      # Synchronous call: the EXIT message above has been handled once it returns.
      :sys.get_state(ctx.listener)
      assert Process.alive?(ctx.listener)
      assert request(ctx.path, statusline(ctx.session, 45)) != ""
      Port.close(port)
    end
  end
end
