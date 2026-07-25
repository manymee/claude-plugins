# Interactive workbench for Exline.Board.State — the session-board
# classification rules (working / attention / idle / stale / gone).
#
# This drives the REAL module in lib/exline/board/state.ex; there is no copy of
# the logic here, so this stays a source of truth for how the rules behave.
# Signal semantics and known blind spots are documented on the module itself.
#
# Run (from plugins/exline/):   mix run --no-start proto/board_state.exs
#
# Keys simulate the signals the daemon receives; numbered scenarios reset to a
# baseline and step through one expected transition per Enter press.

defmodule BoardProto.TUI do
  @moduledoc false
  alias Exline.Board.State, as: Logic

  @bold "\e[1m"
  @dim "\e[2m"
  @off "\e[0m"

  @style %{
    working: {"\e[1;32m", "●"},
    attention: {"\e[1;33m", "▲"},
    idle: {"\e[1;31m", "○"},
    stale: {"\e[1;90m", "◌"},
    gone: {"\e[1;90m", "✕"}
  }

  # Expected transitions between natural board states. Each resets the session
  # to a baseline, then Enter steps through the events one frame at a time —
  # judge every intermediate frame, not just the destination.
  @scenarios %{
    "1" => {"ready → working (submit; api takes a moment to advance)", :ready, ~w(u i w w w)},
    "2" => {"working → ready (turn ends)", :working, ~w(w s i i)},
    "3" => {"working → attention (permission) → working", :working, ~w(w p i i i b w)},
    "4" => {"long tool run — api frozen, still working", :working, ~w(w b i i i i i i)},
    "5" => {"Esc interrupt — board lies until idle-60s notif", :working, ~w(w e i i i i n i)},
    "6" => {"ready → closed (stale, then gone)", :ready, ~w(i i x x X X)},
    "7" => {"daemon restart mid-turn — state recovery", :working, ~w(R i w w s)}
  }

  def main do
    s = Logic.new(0) |> Logic.render(1000, 0)

    loop(%{
      t: 0,
      s: s,
      history: [{0, "session appeared (first render, api baseline 1000ms)"}],
      last_time_key: nil,
      queue: [],
      scenario: nil
    })
  end

  defp loop(st) do
    draw(st)

    case IO.gets("> ") do
      nil ->
        IO.puts("")

      line ->
        key = String.trim(line)

        cond do
          key == "q" -> :ok
          key == "" and st.queue != [] -> loop(play_next(st))
          key == "" and st.last_time_key != nil -> loop(handle(st, st.last_time_key))
          key == "" -> loop(st)
          Map.has_key?(@scenarios, key) -> loop(start_scenario(st, key))
          true -> loop(handle(st, key))
        end
    end
  end

  defp start_scenario(st, key) do
    {title, base, steps} = @scenarios[key]

    %{
      st
      | t: 0,
        s: baseline(base),
        queue: steps,
        scenario: title,
        history: [],
        last_time_key: nil
    }
    |> note(0, "scenario #{key} · #{title} — baseline :#{base}, Enter steps through")
  end

  defp play_next(%{queue: [key | rest]} = st) do
    st = handle(%{st | queue: rest}, key)
    if rest == [], do: note(st, st.t, "scenario done — keys are yours again"), else: st
  end

  defp baseline(:fresh), do: Logic.new(0) |> Logic.render(1000, 0)
  defp baseline(:ready), do: baseline(:fresh) |> Logic.stop(0)

  defp baseline(:working),
    do: baseline(:ready) |> Logic.user_prompt_submit(0) |> Logic.render(2000, 0)

  # -- event keys -------------------------------------------------------------

  defp handle(st, "w") do
    t = st.t + 1
    api = (st.s.api_ms || 0) + 1000

    %{st | t: t, s: Logic.render(st.s, api, t), last_time_key: "w"}
    |> note(t, "+1s · render, api +1000ms")
  end

  defp handle(st, "i") do
    t = st.t + 1

    %{st | t: t, s: Logic.render(st.s, st.s.api_ms || 0, t), last_time_key: "i"}
    |> note(t, "+1s · render, api frozen")
  end

  defp handle(st, "x"), do: silent(st, 1)
  defp handle(st, "X"), do: silent(st, 5)

  defp handle(st, "u"),
    do: %{st | s: Logic.user_prompt_submit(st.s, st.t)} |> note(st.t, "hook UserPromptSubmit")

  defp handle(st, "b"),
    do: %{st | s: Logic.post_tool_batch(st.s, st.t)} |> note(st.t, "hook PostToolBatch")

  defp handle(st, "s"),
    do: %{st | s: Logic.stop(st.s, st.t)} |> note(st.t, "hook Stop")

  defp handle(st, "p"),
    do:
      %{st | s: Logic.notification(st.s, :permission, st.t)}
      |> note(st.t, "hook Notification (needs permission)")

  defp handle(st, "n"),
    do:
      %{st | s: Logic.notification(st.s, :idle, st.t)}
      |> note(st.t, "hook Notification (idle 60s)")

  defp handle(st, "e"),
    do: note(st, st.t, "user hits Esc — CC sends NO hook; simulate the aftermath with [i]")

  defp handle(st, "R") do
    %{st | s: Logic.new(st.t)}
    |> note(st.t, "daemon restart — session state wiped (turn unknown, api baseline lost)")
  end

  defp handle(st, other), do: note(st, st.t, "unknown key #{inspect(other)}")

  defp silent(st, n) do
    t = st.t + n
    key = if n == 1, do: "x", else: "X"
    %{st | t: t, last_time_key: key} |> note(t, "+#{n}s · no render")
  end

  defp note(st, t, msg), do: %{st | history: Enum.take([{t, msg} | st.history], 10)}

  # -- frame ------------------------------------------------------------------

  defp draw(st) do
    {status, reason} = Logic.classify(st.s, st.t)
    {color, glyph} = @style[status]
    s = st.s

    IO.write("\e[2J\e[H")

    IO.puts(
      "#{@bold}exline board-state workbench#{@off}   " <>
        "#{@dim}t=#{st.t}s · #{inspect(Logic.thresholds())}#{@off}"
    )

    IO.puts("")
    IO.puts("  #{color}#{glyph} #{String.upcase(to_string(status))}#{@off}  #{reason}")
    IO.puts("")
    IO.puts("  #{@bold}state#{@off}")
    IO.puts("    last render    #{ago(st.t, s.last_render_at)}")

    IO.puts(
      "    api_ms         #{s.api_ms || "–"}  #{@dim}advanced: #{ago(st.t, s.api_advanced_at)}#{@off}"
    )

    IO.puts("    turn_open      #{inspect(s.turn_open)}#{turn_since(s)}")

    IO.puts(
      "    permission     #{if s.pending_permission, do: "pending since t=#{s.pending_permission}", else: "–"}"
    )

    IO.puts("    hooks          #{hooks_line(s)}")
    IO.puts("")
    IO.puts("  #{@bold}history#{@off}")

    st.history
    |> Enum.reverse()
    |> Enum.each(fn {t, msg} -> IO.puts("    #{@dim}t=#{t}#{@off}  #{msg}") end)

    IO.puts("")

    if st.queue != [] do
      IO.puts(
        "  #{@bold}▶ #{st.scenario}#{@off}  #{@dim}next: [#{hd(st.queue)}] on Enter · #{length(st.queue)} steps left#{@off}"
      )
    else
      IO.puts("  #{@bold}scenarios#{@off} #{@dim}(press number; then Enter steps through)#{@off}")

      @scenarios
      |> Enum.sort()
      |> Enum.each(fn {key, {title, base, steps}} ->
        IO.puts("    #{k(key)} #{title} #{@dim}(:#{base}, #{length(steps)} steps)#{@off}")
      end)
    end

    IO.puts("")

    IO.puts(
      "  #{k("w")} +1s render api++  #{k("i")} +1s render frozen  #{k("x")}/#{k("X")} +1s/+5s no render"
    )

    IO.puts(
      "  #{k("u")} UserPromptSubmit  #{k("b")} PostToolBatch  #{k("s")} Stop  #{k("p")} Notif:permission  #{k("n")} Notif:idle60"
    )

    IO.puts(
      "  #{k("e")} Esc (no hook)  #{k("R")} daemon restart  #{k("⏎")} scenario step / repeat time key  #{k("q")} quit"
    )
  end

  defp k(key), do: "#{@bold}[#{key}]#{@off}"

  defp ago(_now, nil), do: "never"
  defp ago(now, t), do: "#{now - t}s ago #{@dim}(t=#{t})#{@off}"

  defp turn_since(%{turn_open: true, turn_open_since: t}) when is_integer(t),
    do: " (since t=#{t})"

  defp turn_since(_), do: ""

  defp hooks_line(s) do
    [
      {"submit", :user_prompt_submit},
      {"batch", :post_tool_batch},
      {"stop", :stop},
      {"perm", :notif_permission},
      {"idle60", :notif_idle}
    ]
    |> Enum.map_join(" · ", fn {label, key} ->
      case s.hooks[key] do
        nil -> "#{@dim}#{label} –#{@off}"
        t -> "#{label} t=#{t}"
      end
    end)
  end
end

BoardProto.TUI.main()
