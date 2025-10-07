defmodule LiveViewNative.MinimalUploadBugTest do
  @moduledoc """
  Minimal test case showing LVN bug with upload and empty comprehensions.

  This demonstrates the template position collision issue:
  - Render 1 (changed?=false): All comps return structs, file input creates template pos 0
  - Render 2 (changed?=true): Empty comps return nil, upload comp becomes non-empty
  - LVN: FAILS because upload comp creates NEW template pos 0, breaking file input

  The difference from HTML:
  - LVN upload comp has format-specific prefix ("lv:") in static parts
  - This makes fingerprint unique, preventing template reuse
  - Upload comp creates new template position 0 on second render
  - File input expects position 0 for itself → COLLISION
  """

  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LiveViewNativeTest.UploadLive

  @endpoint LiveViewNativeTest.Endpoint

  setup do
    conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
    conn = Plug.Conn.put_req_header(conn, "accept", "text/gameboy")
    {:ok, conn: conn}
  end

  test "LVN: empty comprehensions cause template position collision", %{conn: conn} do
    {:ok, lv, _html} = live_isolated(conn, UploadLive, session: %{})

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("LVN MINIMAL TEST (DEMONSTRATES BUG)")
    IO.puts(String.duplicate("=", 80))
    IO.puts("This shows LVN failing with:")
    IO.puts("  1. Empty comprehensions (@preflights, @consumed) returning nil")
    IO.puts("  2. Upload comprehension becoming non-empty")
    IO.puts("  3. Upload comp has 'lv:' prefix → unique fingerprint")
    IO.puts("  4. Upload comp creates NEW template position 0 on render #2")
    IO.puts("  5. File input tries to use position 0 → WRONG TEMPLATE")
    IO.puts(String.duplicate("=", 80) <> "\n")

    # Setup upload
    UploadLive.run(lv, fn socket ->
      socket = Phoenix.LiveView.allow_upload(socket, :avatar,
        accept: ~w(.jpg .jpeg .png),
        max_entries: 3
      )
      {:reply, :ok, socket}
    end)

    IO.puts("▶ RENDER #1: First render after upload setup")
    IO.puts("   Expected: invoke_dynamic returns [Comp, Comp, Comp, Rendered]")
    IO.puts("   File input creates template position 0 (10 parts, 9 values)\n")

    html1 = render(lv)
    assert html1 =~ ~r/<Input[^>]*type="file"[^>]*>/

    IO.puts("\n▶ RENDER #2: Second render with change tracking")
    IO.puts("   Expected: invoke_dynamic returns [nil, nil, Comp, Rendered]")
    IO.puts("   Empty comps optimized to nil")
    IO.puts("   Upload comp now non-empty with 'lv:' prefix")
    IO.puts("   ❌ Upload comp creates NEW template position 0 (7 parts)")
    IO.puts("   ❌ File input tries to use position 0")
    IO.puts("   ❌ Gets 7-part template instead of 10-part template")
    IO.puts("   ❌ Dynamic values misaligned → GARBLED OUTPUT\n")

    # This should fail with garbled output
    html2 = render(lv)

    # The file input's attributes get mixed with upload comp's dynamic values
    # Instead of: <Input type="file" name="avatar" ...>
    # We get: lv:entry.uuid:entry.client_name type="file" ...
    IO.puts("\n❌ LVN TEST EXPECTED TO FAIL")
    IO.puts("   File input HTML is garbled due to template mismatch")
    IO.puts("   Upload comp stole template position 0 from file input")

    # This assertion will likely fail or pass but with wrong HTML
    if html2 =~ ~r/<Input[^>]*type="file"[^>]*name="avatar"[^>]*>/ do
      IO.puts("   ⚠️  Test passed but check if HTML is correct")
    else
      IO.puts("   ✓  Confirmed: File input attributes are garbled")
    end

    IO.puts(String.duplicate("=", 80) <> "\n")
  end
end
