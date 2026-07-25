defmodule Exline.Listener do
  @moduledoc false

  use GenServer
  require Logger

  # The canonical socket served by the launchd/plugin daemon. Any other
  # configured path means this instance is a dev daemon: its renders carry a
  # `dev` badge so the statusline shows which daemon answered.
  @prod_socket "/tmp/exline.sock"

  # Wire protocol: one JSON document terminated by NUL, answered with raw bytes
  # until the daemon closes the connection. A payload without a top-level
  # `exline` key is a Claude Code statusline payload and is rendered; the key
  # (never present in a statusline payload) selects a control message instead:
  #
  #   {"exline":"hook","event":"Stop","session_id":"…"} → hook JSON, or empty
  #   {"exline":"ctl","session_id":"…","action":"on"|"off"|"status"} → ctl JSON

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    # Without trapping exits a supervisor/SIGTERM shutdown kills this process
    # outright, terminate/2 never runs and the socket file is left behind.
    Process.flag(:trap_exit, true)

    path = opts[:socket_path] || Application.get_env(:exline, :socket_path, @prod_socket)
    listen_socket = open_socket(path)
    send(self(), :accept)

    {:ok,
     %{
       listen: listen_socket,
       path: path,
       config: %{
         dev?: path != @prod_socket,
         sessions: Keyword.get(opts, :sessions, Exline.Sessions)
       }
     }}
  end

  # Accepting with a timeout keeps the loop shutdown-responsive: a blocking
  # accept parks the process inside a selective receive, where the supervisor's
  # exit signal waits unseen until the shutdown timeout kills the process and
  # terminate/2 with it. The driver hands over a connection that arrives before
  # the timeout, so nothing is dropped by re-arming.
  @accept_timeout 500

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen, @accept_timeout) do
      {:ok, conn_socket} ->
        config = state.config

        {:ok, pid} =
          Task.Supervisor.start_child(Exline.ConnSupervisor, fn -> serve(conn_socket, config) end)

        # A short reply (an empty hook answer) can be served and the connection
        # closed before this handover runs, which fails — harmlessly, since a
        # passive socket is readable from any process and the task closes it
        # either way. Crashing the listener over it is the only real risk.
        _ = :gen_tcp.controlling_process(conn_socket, pid)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :closed, state}

      # Transient failures like :emfile (fd exhaustion under connection
      # bursts): back off and retry rather than crash — repeated listener
      # crashes exceed the supervisor's restart intensity and take the
      # whole daemon down.
      {:error, reason} ->
        Logger.warning("exline: accept failed: #{inspect(reason)}, retrying")
        Process.send_after(self(), :accept, 100)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
    :ok
  end

  defp open_socket(path) do
    options = [
      :binary,
      {:active, false},
      {:ifaddr, {:local, path}}
    ]

    case :gen_tcp.listen(0, options) do
      {:ok, sock} ->
        sock

      {:error, :eaddrinuse} ->
        Logger.warning("exline: socket #{path} in use, unlinking")
        File.rm!(path)
        open_socket(path)
    end
  end

  defp serve(conn_socket, config) do
    input = read_until_null(conn_socket, [])

    response =
      case JSON.decode(input) do
        # Control messages carry no statusline payload, so no capture either:
        # the capture history is the corpus for replaying real renders.
        {:ok, %{"exline" => kind} = message} ->
          control(kind, message, config)

        {:ok, json} ->
          Exline.Captures.save(input)
          render(input, json, config)

        {:error, reason} ->
          Logger.warning("exline: invalid json: #{inspect(reason)}")
          "exline: invalid json"
      end

    :gen_tcp.send(conn_socket, response)
    :gen_tcp.close(conn_socket)
  end

  # A hook asking whether this session has crossed a context threshold it has
  # not been told about yet. Empty reply = nothing to say; the hook stays silent.
  defp control("hook", %{"event" => event, "session_id" => session_id}, config)
       when event in ["Stop", "PostToolBatch"] and is_binary(session_id) do
    case Exline.Sessions.hook_report(config.sessions, session_id) do
      nil ->
        ""

      report ->
        JSON.encode!(%{
          hookSpecificOutput: %{
            hookEventName: event,
            additionalContext: "[exline] " <> report.message
          }
        })
    end
  end

  defp control("hook", _message, _config), do: ""

  defp control("ctl", %{"session_id" => session_id, "action" => action}, config)
       when is_binary(session_id) and action in ["on", "off", "status"] do
    if action != "status",
      do: Exline.Sessions.set_enabled(config.sessions, session_id, action == "on")

    status = Exline.Sessions.status(config.sessions, session_id)

    JSON.encode!(%{
      ok: true,
      context_report: if(status.enabled, do: "on", else: "off"),
      used_percentage: status.pct
    })
  end

  defp control("ctl", %{"session_id" => session_id}, _config) when is_binary(session_id),
    do: JSON.encode!(%{ok: false, error: "unknown action"})

  defp control(_kind, _message, _config), do: JSON.encode!(%{ok: false, error: "unknown message"})

  # A crashing render must not blank the statusline silently: persist the
  # payload + stacktrace (the regular capture history buries them within
  # seconds) and reply with the crash location so the failure is visible —
  # in dev and prod alike.
  defp render(input, json, config) do
    Exline.format(json,
      color: true,
      drift: Exline.PluginVersion.drift(),
      dev: config.dev?,
      ctx_report_off: track_session(json, config)
    )
  catch
    kind, reason ->
      Logger.error("exline: render crashed: #{Exception.format(kind, reason, __STACKTRACE__)}")
      path = Exline.Captures.save_crash(input, kind, reason, __STACKTRACE__)
      "exline: render crashed — #{path}"
  end

  # Feed the render's context percentage to the session tracker (the state the
  # hook queries read) and report back whether this session muted its reports,
  # which the render shows as a badge.
  defp track_session(json, config) do
    session_id = json["session_id"]
    pct = get_in(json, ["context_window", "used_percentage"])

    if is_binary(session_id) do
      if is_number(pct), do: Exline.Sessions.update(config.sessions, session_id, pct)
      not Exline.Sessions.status(config.sessions, session_id).enabled
    else
      false
    end
  end

  @recv_timeout 2_000

  defp read_until_null(conn_socket, acc) do
    case :gen_tcp.recv(conn_socket, 0, @recv_timeout) do
      {:ok, data} ->
        combined = IO.iodata_to_binary([acc, data])

        case :binary.match(combined, <<0>>) do
          {pos, 1} -> :binary.part(combined, 0, pos)
          :nomatch -> read_until_null(conn_socket, combined)
        end

      {:error, reason} when reason in [:closed, :timeout] ->
        IO.iodata_to_binary(acc)
    end
  end
end
