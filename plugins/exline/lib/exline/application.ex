defmodule Exline.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @start_listener Application.compile_env(:exline, :start_listener, true)

  @impl true
  def start(_type, _args) do
    children =
      [{Task.Supervisor, name: Exline.ConnSupervisor}, Exline.GitCache, Exline.Sessions] ++
        if @start_listener, do: [Exline.Listener], else: []

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Exline.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
