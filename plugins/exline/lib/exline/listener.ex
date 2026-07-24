defmodule Exline.Listener do
  @moduledoc false

  use GenServer
  require Logger

  @socket_path ~c"/tmp/exline.sock"

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    listen_socket = open_socket()
    send(self(), :accept)
    {:ok, listen_socket}
  end

  @impl true
  def handle_info(:accept, listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, conn_socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(Exline.ConnSupervisor, fn -> serve(conn_socket) end)

        :ok = :gen_tcp.controlling_process(conn_socket, pid)
        send(self(), :accept)
        {:noreply, listen_socket}

      {:error, :closed} ->
        {:stop, :closed, listen_socket}

      # Transient failures like :emfile (fd exhaustion under connection
      # bursts): back off and retry rather than crash — repeated listener
      # crashes exceed the supervisor's restart intensity and take the
      # whole daemon down.
      {:error, reason} ->
        Logger.warning("exline: accept failed: #{inspect(reason)}, retrying")
        Process.send_after(self(), :accept, 100)
        {:noreply, listen_socket}
    end
  end

  @impl true
  def terminate(_reason, listen_socket) do
    :gen_tcp.close(listen_socket)
    File.rm(@socket_path)
    :ok
  end

  defp open_socket do
    options = [
      :binary,
      {:active, false},
      {:ifaddr, {:local, @socket_path}}
    ]

    case :gen_tcp.listen(0, options) do
      {:ok, sock} ->
        sock

      {:error, :eaddrinuse} ->
        Logger.warning("exline: socket #{@socket_path} in use, unlinking")
        File.rm!(@socket_path)
        open_socket()
    end
  end

  defp serve(conn_socket) do
    input = read_until_null(conn_socket, [])

    response =
      case JSON.decode(input) do
        {:ok, json} ->
          Exline.Captures.save(input)
          Exline.format(json, color: true)

        {:error, reason} ->
          Logger.warning("exline: invalid json: #{inspect(reason)}")
          "exline: invalid json"
      end

    :gen_tcp.send(conn_socket, response)
    :gen_tcp.close(conn_socket)
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
