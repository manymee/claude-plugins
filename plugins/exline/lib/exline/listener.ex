defmodule Exline.Listener do
  @moduledoc false

  use GenServer
  require Logger

  # The canonical socket served by the launchd/plugin daemon. Any other
  # configured path means this instance is a dev daemon: its renders carry a
  # `dev` badge so the statusline shows which daemon answered.
  @prod_socket "/tmp/exline.sock"

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    path = Application.get_env(:exline, :socket_path, @prod_socket)
    listen_socket = open_socket(path)
    send(self(), :accept)
    {:ok, %{listen: listen_socket, path: path, dev?: path != @prod_socket}}
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen) do
      {:ok, conn_socket} ->
        dev? = state.dev?

        {:ok, pid} =
          Task.Supervisor.start_child(Exline.ConnSupervisor, fn -> serve(conn_socket, dev?) end)

        :ok = :gen_tcp.controlling_process(conn_socket, pid)
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

  defp serve(conn_socket, dev?) do
    input = read_until_null(conn_socket, [])

    response =
      case JSON.decode(input) do
        {:ok, json} ->
          Exline.Captures.save(input)
          render(input, json, dev?)

        {:error, reason} ->
          Logger.warning("exline: invalid json: #{inspect(reason)}")
          "exline: invalid json"
      end

    :gen_tcp.send(conn_socket, response)
    :gen_tcp.close(conn_socket)
  end

  # A crashing render must not blank the statusline silently: persist the
  # payload + stacktrace (the regular capture history buries them within
  # seconds) and reply with the crash location so the failure is visible —
  # in dev and prod alike.
  defp render(input, json, dev?) do
    Exline.format(json, color: true, drift: Exline.PluginVersion.drift(), dev: dev?)
  catch
    kind, reason ->
      Logger.error("exline: render crashed: #{Exception.format(kind, reason, __STACKTRACE__)}")
      path = Exline.Captures.save_crash(input, kind, reason, __STACKTRACE__)
      "exline: render crashed — #{path}"
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
