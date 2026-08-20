defmodule ExlineTest do
  use ExUnit.Case, async: true

  @zwsp "​"
  # Non-existent dir so Exline.Git invocations fail and only the fallback
  # basename appears on line 2, keeping these tests independent of git state.
  @cwd "/tmp/exline-test-cwd/dotfiles"
  @now 1_700_000_000

  describe "format/2 with no data" do
    test "returns just the ZWSP placeholder for the rate-limit line" do
      assert Exline.format(%{}, now: @now) == @zwsp
    end
  end

  describe "drift line" do
    test "is absent by default" do
      refute Exline.format(%{}, now: @now) |> String.contains?("exline")
    end

    test "renders a trailing warning line when drift is given" do
      out = Exline.format(%{}, now: @now, drift: {"0.1.0", "0.2.0"})

      assert List.last(String.split(out, "\n")) ==
               "⚠ exline 0.1.0 running, 0.2.0 installed — run /exline:setup"
    end

    test "styles the warning when color is on" do
      out = Exline.format(%{}, now: @now, color: true, drift: {"0.1.0", "0.2.0"})
      assert String.contains?(out, "\e[1;33m⚠ exline 0.1.0")
    end
  end

  describe "dev badge" do
    test "is absent by default" do
      data = %{"version" => "2.0.0"}
      refute Exline.format(data, now: @now) |> String.contains?("dev")
    end

    test "prefixes line 3 when dev: true" do
      data = %{"version" => "2.0.0"}
      out = Exline.format(data, now: @now, dev: true)
      assert out |> String.split("\n") |> Enum.any?(&String.starts_with?(&1, "dev  v2.0.0"))
    end

    test "renders bold yellow when color is on" do
      out = Exline.format(%{"version" => "2.0.0"}, now: @now, color: true, dev: true)
      assert String.contains?(out, "\e[1;33mdev\e[0m")
    end
  end

  describe "ctx-report off badge" do
    test "is absent by default" do
      data = %{"version" => "2.0.0"}
      refute Exline.format(data, now: @now) |> String.contains?("ctx-report")
    end

    test "leaves the rest of the output byte-identical when off" do
      data = %{"version" => "2.0.0", "context_window" => %{"used_percentage" => 6}}

      assert Exline.format(data, now: @now, ctx_report_off: false) ==
               Exline.format(data, now: @now)
    end

    test "prefixes line 3 when ctx_report_off: true" do
      data = %{"version" => "2.0.0"}
      out = Exline.format(data, now: @now, ctx_report_off: true)

      assert out
             |> String.split("\n")
             |> Enum.any?(&String.starts_with?(&1, "ctx-report off  v2.0.0"))
    end

    test "sits next to the dev badge when both are on" do
      data = %{"version" => "2.0.0"}
      out = Exline.format(data, now: @now, dev: true, ctx_report_off: true)

      assert out
             |> String.split("\n")
             |> Enum.any?(&String.starts_with?(&1, "dev  ctx-report off  v2.0.0"))
    end

    test "renders bold yellow when color is on" do
      out = Exline.format(%{"version" => "2.0.0"}, now: @now, color: true, ctx_report_off: true)
      assert String.contains?(out, "\e[1;33mctx-report off\e[0m")
    end
  end

  describe "line 1 (cwd path)" do
    test "is omitted when workspace.current_dir is absent" do
      refute Exline.format(%{}, now: @now) |> String.contains?("/")
    end

    test "renders a shallow path verbatim" do
      data = %{"workspace" => %{"current_dir" => "/usr/local"}}
      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == "/usr/local"
    end

    test "truncates a deep path to '.../<parent>/<leaf>'" do
      data = %{"workspace" => %{"current_dir" => "/a/b/c/d/e"}}
      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == ".../d/e"
    end

    # Path.split counts the leading "/" as a part, so the truncation threshold
    # of `> 3` fires once the path has two non-root segments below root.
    test "truncates at the Path.split-length-3 boundary" do
      data = %{"workspace" => %{"current_dir" => "/usr/local/bin"}}
      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == ".../local/bin"
    end

    test "keeps a single-segment path untruncated" do
      data = %{"workspace" => %{"current_dir" => "/etc"}}
      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == "/etc"
    end
  end

  describe "line 1 width-aware truncation (terminal.columns)" do
    test "ignores a zero width and falls back to width-blind truncation" do
      data = %{
        "workspace" => %{"current_dir" => "/a/b/c/d/e"},
        "terminal" => %{"columns" => 0}
      }

      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == ".../d/e"
    end

    test "keeps a deep path verbatim when it fits the width" do
      data = %{
        "workspace" => %{"current_dir" => "/usr/local/bin"},
        "terminal" => %{"columns" => 80}
      }

      # Width is ample, so the path keeps all segments (no `.../` collapse). At
      # this width it also merges onto one row with the git group; see the
      # dedicated merge describe block below.
      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert String.starts_with?(line1, "/usr/local/bin")
      refute line1 =~ "..."
    end

    test "collapses from the left, keeping as many trailing segments as fit" do
      data = %{
        "workspace" => %{"current_dir" => "/Users/me/my/dotfiles/custom/exline"},
        "terminal" => %{"columns" => 21}
      }

      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == ".../custom/exline"
      assert String.length(line1) <= 20
    end

    test "reserves render-margin headroom below the reported width" do
      # Full path is exactly 20 chars and would fit a raw 20-col width, but CC
      # reserves columns on the right, so we still collapse to stay clear of it.
      data = %{
        "workspace" => %{"current_dir" => "/Users/me/projectdir"},
        "terminal" => %{"columns" => 20}
      }

      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      refute line1 == "/Users/me/projectdir"
      assert String.length(line1) < 20
    end

    test "floors at the leaf alone when even one segment overflows" do
      data = %{
        "workspace" => %{"current_dir" => "/Users/me/averylongdirectoryname"},
        "terminal" => %{"columns" => 10}
      }

      [line1 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == ".../averylongdirectoryname"
    end
  end

  describe "line 2 (git info)" do
    test "is omitted entirely when cwd is absent" do
      data = %{"version" => "2.0.0"}
      lines = Exline.format(data, now: @now) |> String.split("\n")
      # Only line 3 (version) and line 4 (ZWSP) — no path, no git line.
      assert lines == ["v2.0.0", @zwsp]
    end

    test "falls back to the basename of cwd when git is unavailable" do
      data = %{"workspace" => %{"current_dir" => @cwd}}
      [_line1, line2 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line2 == "dotfiles"
    end

    test "falls back to the basename when the git cache returns nil (hung gather)" do
      data = %{"workspace" => %{"current_dir" => @cwd}}
      render = Exline.format(data, now: @now, git_fetch: fn _cwd -> nil end)
      [_line1, line2 | _] = String.split(render, "\n")
      assert line2 == "dotfiles"
    end
  end

  describe "merging the path and git lines (terminal.columns)" do
    test "joins them onto one row, git info flush right, when wide enough" do
      data = %{"workspace" => %{"current_dir" => @cwd}, "terminal" => %{"columns" => 200}}
      [merged | _] = Exline.format(data, now: @now) |> String.split("\n")

      assert String.starts_with?(merged, @cwd)
      # Flush right: ends exactly with the git group, no trailing pad.
      assert String.ends_with?(merged, "dotfiles")
      # Filled to the usable width (COLUMNS minus the 4-col render margin).
      assert String.length(merged) == 196
      # Everything between the two groups is padding spaces.
      assert merged |> String.trim_leading(@cwd) |> String.trim_trailing("dotfiles") =~ ~r/^ +$/
    end

    test "keeps them stacked when the joined row would not fit" do
      data = %{"workspace" => %{"current_dir" => @cwd}, "terminal" => %{"columns" => 33}}
      [line1, line2 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == @cwd
      assert line2 == "dotfiles"
    end

    test "stays stacked when the width is unknown" do
      data = %{"workspace" => %{"current_dir" => @cwd}}
      [line1, line2 | _] = Exline.format(data, now: @now) |> String.split("\n")
      assert line1 == ".../exline-test-cwd/dotfiles"
      assert line2 == "dotfiles"
    end
  end

  describe "line 3 (version / model / effort / style / context)" do
    test "is omitted when all four fields are missing" do
      lines = Exline.format(%{}, now: @now) |> String.split("\n")
      assert lines == [@zwsp]
    end

    test "renders version with a leading 'v'" do
      assert Exline.format(%{"version" => "2.1.140"}, now: @now) =~ "v2.1.140"
    end

    test "renders model display_name verbatim" do
      data = %{"model" => %{"display_name" => "Opus 4.7"}}
      assert Exline.format(data, now: @now) =~ "Opus 4.7"
    end

    test "renders effort level verbatim" do
      data = %{"effort" => %{"level" => "xhigh"}}
      assert Exline.format(data, now: @now) =~ "xhigh"
    end

    test "renders output_style name verbatim" do
      data = %{"output_style" => %{"name" => "concise-omit"}}
      assert Exline.format(data, now: @now) =~ "concise-omit"
    end

    test "renders context window with one decimal place" do
      data = %{"context_window" => %{"used_percentage" => 6}}
      assert Exline.format(data, now: @now) =~ "Ctx Used: 6.0%"
    end

    test "joins all five fields with double spaces in fixed order" do
      data = %{
        "version" => "2.1.140",
        "model" => %{"display_name" => "Opus 4.7"},
        "effort" => %{"level" => "xhigh"},
        "output_style" => %{"name" => "concise-omit"},
        "context_window" => %{"used_percentage" => 12.5}
      }

      [line3, _line4] = String.split(Exline.format(data, now: @now), "\n")
      assert line3 == "v2.1.140  Opus 4.7  xhigh  concise-omit  Ctx Used: 12.5%"
    end

    test "omits absent fields but keeps present ones with the standard separator" do
      data = %{
        "version" => "2.1.140",
        "context_window" => %{"used_percentage" => 6}
      }

      assert Exline.format(data, now: @now) =~ "v2.1.140  Ctx Used: 6.0%"
    end
  end

  describe "line 4 (rate limits)" do
    test "renders the ZWSP placeholder when no rate_limits are present" do
      assert String.ends_with?(Exline.format(%{}, now: @now), @zwsp)
    end

    test "computes resets_at countdown against the :now option" do
      data = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 50.0, "resets_at" => @now + 5400}
        }
      }

      assert Exline.format(data, now: @now) =~ "Session: 50.0%  1h30m"
    end

    test "renders both Session and Weekly windows joined by '  |  '" do
      data = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 3, "resets_at" => @now + 3600},
          "seven_day" => %{"used_percentage" => 29, "resets_at" => @now + 7200}
        }
      }

      output = Exline.format(data, now: @now)
      assert output =~ "Session: 3.0%  1h0m  |  Weekly: 29.0%  2h0m"
    end

    test "renders 0h0m for windows that have already expired" do
      data = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 80, "resets_at" => @now - 10}
        }
      }

      assert Exline.format(data, now: @now) =~ "Session: 80.0%  0h0m"
    end

    test "renders integer used_percentage with one decimal place" do
      data = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 50, "resets_at" => @now + 60}
        }
      }

      assert Exline.format(data, now: @now) =~ "Session: 50.0%"
    end

    test "renders float used_percentage with one decimal place" do
      data = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 12.345, "resets_at" => @now + 60}
        }
      }

      assert Exline.format(data, now: @now) =~ "Session: 12.3%"
    end

    test "skips a window whose entry is missing while rendering the other" do
      data = %{
        "rate_limits" => %{
          "seven_day" => %{"used_percentage" => 10, "resets_at" => @now + 3600}
        }
      }

      output = Exline.format(data, now: @now)
      refute output =~ "Session:"
      assert output =~ "Weekly: 10.0%  1h0m"
    end
  end

  describe "merging the model and rate-limit lines (terminal.columns)" do
    @lower %{
      "version" => "2.1.156",
      "rate_limits" => %{
        "five_hour" => %{"used_percentage" => 6, "resets_at" => @now + 5400},
        "seven_day" => %{"used_percentage" => 2, "resets_at" => @now + 7200}
      }
    }

    test "joins them onto one row, rate limits flush right, when wide enough" do
      data = Map.put(@lower, "terminal", %{"columns" => 200})
      rate_line = "Session: 6.0%  1h30m  |  Weekly: 2.0%  2h0m"
      [merged] = Exline.format(data, now: @now) |> String.split("\n")

      assert String.starts_with?(merged, "v2.1.156")
      # Flush right: ends exactly with the rate line, no trailing pad.
      assert String.ends_with?(merged, rate_line)
      # Filled to the usable width (COLUMNS minus the 4-col render margin).
      assert String.length(merged) == 196
      # Everything between the two groups is padding spaces.
      assert merged |> String.trim_leading("v2.1.156") |> String.trim_trailing(rate_line) =~
               ~r/^ +$/
    end

    test "keeps them stacked when the joined row would not fit" do
      data = Map.put(@lower, "terminal", %{"columns" => 30})
      lines = Exline.format(data, now: @now) |> String.split("\n")
      assert lines == ["v2.1.156", "Session: 6.0%  1h30m  |  Weekly: 2.0%  2h0m"]
    end

    test "stays stacked when the width is unknown" do
      lines = Exline.format(@lower, now: @now) |> String.split("\n")
      assert lines == ["v2.1.156", "Session: 6.0%  1h30m  |  Weekly: 2.0%  2h0m"]
    end

    test "does not merge the ZWSP placeholder when no rate limits are present" do
      data = %{"version" => "2.1.156", "terminal" => %{"columns" => 200}}
      lines = Exline.format(data, now: @now) |> String.split("\n")
      assert lines == ["v2.1.156", @zwsp]
    end
  end

  describe "color: true styling" do
    # Strip SGR escapes to recover the display text the layout pass measured.
    defp strip(s), do: Regex.replace(~r/\e\[[0-9;]*m/, s, "")

    test "is off by default — no escape sequences" do
      data = %{"version" => "2.1.140", "model" => %{"display_name" => "Opus 4.7"}}
      refute Exline.format(data, now: @now) =~ "\e["
    end

    test "stripping ANSI recovers the exact plain layout" do
      data = %{
        "version" => "2.1.156",
        "model" => %{"display_name" => "Opus 4.7"},
        "context_window" => %{"used_percentage" => 12.5},
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 6, "resets_at" => @now + 5400}
        }
      }

      plain = Exline.format(data, now: @now)
      colored = Exline.format(data, now: @now, color: true)

      assert colored =~ "\e["
      assert strip(colored) == plain
    end

    test "gradients the context percentage by threshold" do
      green = %{"context_window" => %{"used_percentage" => 10}}
      red = %{"context_window" => %{"used_percentage" => 95}}

      assert Exline.format(green, now: @now, color: true) =~ "\e[1;32m10.0%\e[0m"
      assert Exline.format(red, now: @now, color: true) =~ "\e[1;31m95.0%\e[0m"
    end

    test "colors the branch on the real git path" do
      # Drive the live git path against this repo: a branch is always present, so
      # the magenta branch color must appear.
      repo = File.cwd!()
      data = %{"workspace" => %{"current_dir" => repo}}
      colored = Exline.format(data, now: @now, color: true)
      assert colored =~ "\e[1;35m⎇ "
    end

    test "ANSI is width-neutral: the flush-right merge stays aligned" do
      data = %{"workspace" => %{"current_dir" => @cwd}, "terminal" => %{"columns" => 200}}
      [merged | _] = Exline.format(data, now: @now, color: true) |> String.split("\n")

      assert merged =~ "\e["
      visible = strip(merged)
      assert String.length(visible) == 196
      assert String.starts_with?(visible, @cwd)
      assert String.ends_with?(visible, "dotfiles")
    end
  end

  describe "format/2 :now option" do
    test "defaults to the system clock when not provided" do
      future = System.system_time(:second) + 1800

      data = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 1, "resets_at" => future}
        }
      }

      assert Exline.format(data) =~ ~r/Session: 1\.0%  0h\d+m/
    end
  end
end
