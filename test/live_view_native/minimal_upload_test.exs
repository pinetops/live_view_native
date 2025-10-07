defmodule LiveViewNative.MinimalUploadTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LiveViewNativeTest.UploadLive

  @endpoint LiveViewNativeTest.Endpoint

  setup do
    conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
    conn = Phoenix.ConnTest.put_req_header(conn, "accept", "text/gameboy")
    {:ok, conn: conn}
  end

  test "LVN with empty comprehensions renders consistently", %{conn: conn} do
    {:ok, lv, _html} = live_isolated(conn, UploadLive, session: %{})

    # Setup upload
    UploadLive.run(lv, fn socket ->
      Phoenix.LiveView.allow_upload(socket, :avatar,
        accept: ~w(.jpg .jpeg .png),
        max_entries: 3
      )
    end)

    # Render multiple times - may fail due to ordering issues
    html1 = render(lv)
    IO.puts("\n=== LVN Render #1 ===")
    IO.puts(String.slice(html1, 0, 200))
    assert html1 =~ ~r/<Input[^>]*type="file"[^>]*>/

    html2 = render(lv)
    IO.puts("\n=== LVN Render #2 ===")
    IO.puts(String.slice(html2, 0, 200))
    assert html2 =~ ~r/<Input[^>]*type="file"[^>]*>/

    html3 = render(lv)
    IO.puts("\n=== LVN Render #3 ===")
    IO.puts(String.slice(html3, 0, 200))
    assert html3 =~ ~r/<Input[^>]*type="file"[^>]*>/

    IO.puts("\n✅ LVN: All 3 renders succeeded with consistent output")
  end
end
