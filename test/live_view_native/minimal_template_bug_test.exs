defmodule LiveViewNative.MinimalTemplateBugTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import LiveViewNativeTest

  alias LiveViewNativeTest.MinimalTemplateBugLive

  @endpoint LiveViewNativeTest.Endpoint

  setup do
    conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
    conn = Plug.Conn.put_req_header(conn, "accept", "text/gameboy")
    {:ok, conn: conn}
  end

  test "LVN minimal: template resolution prevents position collision", %{conn: conn} do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("LVN MINIMAL TEST (FIXED WITH TEMPLATE RESOLUTION)")
    IO.puts(String.duplicate("=", 80))
    IO.puts("Template structure:")
    IO.puts("  1. Empty comprehension (@empty = [])")
    IO.puts("  2. Items comprehension (@items) with 'lv:' prefix")
    IO.puts("")
    IO.puts("What happens:")
    IO.puts("  Render #1: Both comps return structs, parent creates template pos 0")
    IO.puts("  Render #2: Empty comp returns nil, items comp has 'lv:' prefix")
    IO.puts("  → Items comp creates NEW template position 0 (collision!)")
    IO.puts("  ✓ Template resolution converts old position refs to literal static parts")
    IO.puts("  ✓ Prevents collision from breaking rendering")
    IO.puts(String.duplicate("=", 80) <> "\n")

    {:ok, lv, _html} = live_isolated(conn, MinimalTemplateBugLive, session: %{}, _format: :gameboy)

    IO.puts("▶ RENDER #1: Initial render (changed?=false)")
    html1 = render(lv)
    IO.puts("✓ Initial render complete\n")

    IO.puts("▶ RENDER #2: Add items and re-render (changed?=true)")
    MinimalTemplateBugLive.run(lv, {:set_items, ["a", "b"]})
    html2 = render(lv)

    IO.puts("\n✓ LVN SUCCESS: Template resolution prevents collision")
    IO.puts("Output: #{inspect(html2)}")
    IO.puts(String.duplicate("=", 80) <> "\n")

    assert html2 =~ "lv:a"
    assert html2 =~ "lv:b"
  end
end
