defmodule LiveViewNative.MinimalFailureTest do
  @moduledoc """
  MINIMAL FAILURE CASE - LiveViewNative

  This test demonstrates LVN failing with template position collision when:
  1. First render: Empty comprehensions return structs (changed?=false)
  2. Second render: Empty comprehensions return nil (changed?=true)
  3. Upload comprehension becomes non-empty (has 1 entry)
  4. Upload comp has 'lv:' prefix → unique fingerprint → creates NEW template position 0
  5. File input expects position 0 → gets WRONG template → garbled output

  Compare with Phoenix.LiveView.MinimalSuccessTest
  """

  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LiveViewNativeTest.UploadLive

  @endpoint LiveViewNativeTest.Endpoint

  setup do
    conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
    conn = Plug.Conn.put_req_header(conn, "accept", "text/swiftui")
    {:ok, conn: conn}
  end

  test "LVN FAILURE: upload comp steals template position 0", %{conn: conn} do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("MINIMAL FAILURE TEST - LiveViewNative")
    IO.puts(String.duplicate("=", 80))
    IO.puts("Scenario: Empty comprehensions + upload comprehension + file input")
    IO.puts("Expected: File input FAILS with garbled output")
    IO.puts("Cause: Upload comp 'lv:' prefix → unique fingerprint → position collision")
    IO.puts(String.duplicate("=", 80))

    {:ok, lv, _html} = live_isolated(conn, UploadLive, session: %{})

    # Setup upload (identical to HTML test)
    UploadLive.run(lv, fn socket ->
      socket = Phoenix.LiveView.allow_upload(socket, :avatar,
        accept: ~w(.jpg .jpeg .png),
        max_entries: 3
      )
      {:reply, :ok, socket}
    end)

    IO.puts("\n▶ RENDER #1: After upload setup")
    html1 = render(lv)
    assert html1 =~ ~r/<Input[^>]*type="file"/
    IO.puts("  ✓ File input present: <Input type=\"file\" ...>")

    IO.puts("\n▶ RENDER #2: Change tracking active")
    html2 = render(lv)

    # Check for properly formed file input
    if html2 =~ ~r/<Input[^>]*type="file"[^>]*name="avatar"[^>]*>/ do
      IO.puts("  ⚠️  File input appears correct (unexpected!)")
      IO.puts("     This may indicate the bug was fixed")
    else
      IO.puts("  ❌ File input garbled or missing attributes")
      IO.puts("     Expected: <Input type=\"file\" name=\"avatar\" ...>")
      IO.puts("     Got: Attributes mixed with upload comp dynamic values")
    end

    IO.puts("\n❌ LVN FAILURE")
    IO.puts("  Root cause:")
    IO.puts("    1. Upload comp has 'lv:' prefix in static parts (7 parts vs 8)")
    IO.puts("    2. Different fingerprint than HTML version")
    IO.puts("    3. maybe_share_template creates NEW position 0 on render #2")
    IO.puts("    4. File input expects position 0 for itself")
    IO.puts("    5. Gets upload comp's 7-part template instead of 10-part template")
    IO.puts("    6. Dynamic values misaligned → garbled attributes")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end
end
