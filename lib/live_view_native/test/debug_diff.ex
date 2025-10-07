defmodule LiveViewNativeTest.DebugDiff do
  @moduledoc false

  # Wrapper around Phoenix.LiveView.Diff.to_iodata with debugging

  def to_iodata(diff, mapper \\ fn cid, content -> content end) do
    IO.puts("\n=== DebugDiff.to_iodata called ===")
    IO.inspect(diff, label: "Input diff", limit: 10, pretty: true, structs: false)

    result = Phoenix.LiveView.Diff.to_iodata(diff, mapper)

    IO.puts("\n=== DebugDiff.to_iodata result ===")
    IO.inspect(result, label: "Output", limit: 10, pretty: true)

    result
  end
end
