defmodule Exline.ExpectedTest do
  use ExUnit.Case, async: true

  @fixtures_dir Path.expand("fixtures", __DIR__)
  # Fallback clock for fixtures without their own `_test_now`.
  @default_now 1_700_000_000

  fixtures =
    @fixtures_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort()

  for fixture <- fixtures do
    @fixture fixture
    test "format/2 matches expected output: #{fixture}" do
      json_path = Path.join(@fixtures_dir, @fixture)

      expected_path =
        Path.join(@fixtures_dir, String.replace_suffix(@fixture, ".json", ".expected.txt"))

      data = json_path |> File.read!() |> JSON.decode!()
      now = Map.get(data, "_test_now", @default_now)
      actual = Exline.format(data, now: now)

      if System.get_env("UPDATE_EXPECTED") == "1" do
        File.write!(expected_path, actual)
        IO.puts("wrote expected: #{expected_path}")
      else
        case File.read(expected_path) do
          {:ok, expected} ->
            assert actual == expected,
                   "expected output drift in #{@fixture}; run `UPDATE_EXPECTED=1 mix test` to refresh"

          {:error, :enoent} ->
            flunk(
              "missing expected output at #{expected_path}; run `UPDATE_EXPECTED=1 mix test` to create"
            )
        end
      end
    end
  end
end
