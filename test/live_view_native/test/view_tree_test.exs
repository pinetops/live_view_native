defmodule LiveViewNative.ViewTreeTest do
  use ExUnit.Case, async: true

  alias LiveViewNativeTest.ViewTree

  describe "find_live_views" do
    # >= 4432 characters
    @too_big_session Enum.map_join(1..4432, fn _ -> "t" end)

    test "finds views given markup" do
      assert ViewTree.find_live_views(
               ViewTree.parse("""
               <Title>top</Title>
               <Group data-phx-session="SESSION1"
                 id="phx-123"></Group>
               <Group data-phx-parent-id="456"
                   data-phx-session="SESSION2"
                   data-phx-static="STATIC2"
                   id="phx-456"></Group>
               <Group data-phx-session="#{@too_big_session}"
                 id="phx-458"></Group>
               <Title>bottom</Title>
               """)
             ) == [
               {"phx-123", "SESSION1", nil},
               {"phx-456", "SESSION2", "STATIC2"},
               {"phx-458", @too_big_session, nil}
             ]

      assert ViewTree.find_live_views(["none"]) == []
    end

    test "returns main live view as first result" do
      assert ViewTree.find_live_views(
               ViewTree.parse("""
               <Title>top</Title>
               <Group data-phx-session="SESSION1"
                 id="phx-123"></Group>
               <Group data-phx-parent-id="456"
                   data-phx-session="SESSION2"
                   data-phx-static="STATIC2"
                   id="phx-456"></Group>
               <Group data-phx-session="SESSIONMAIN"
                 data-phx-main="true"
                 id="phx-458"></Group>
               <Title>bottom</Title>
               """)
             ) == [
               {"phx-458", "SESSIONMAIN", nil},
               {"phx-123", "SESSION1", nil},
               {"phx-456", "SESSION2", "STATIC2"}
             ]
    end
  end

  describe "replace_root_container" do
    test "replaces tag name and merges attributes" do
      container =
        ViewTree.parse("""
        <Group id="container"
             data-phx-main="true"
             data-phx-session="session"
             data-phx-static="static"
             class="old">contents</Group>
        """)

      assert ViewTree.replace_root_container(container, :Span, %{class: "new"}) ==
               [
                 {"Span",
                  [
                    {"id", "container"},
                    {"data-phx-main", "true"},
                    {"data-phx-session", "session"},
                    {"data-phx-static", "static"},
                    {"class", "new"}
                  ], ["contents"]}
               ]
    end

    test "does not overwrite reserved attributes" do
      container =
        ViewTree.parse("""
        <Group id="container"
             data-phx-main="true"
             data-phx-session="session"
             data-phx-static="static">contents</Group>
        """)

      new_attrs = %{
        "id" => "new",
        "data-phx-session" => "new",
        "data-phx-static" => "new",
        "data-phx-main" => "new"
      }

      assert ViewTree.replace_root_container(container, :Group, new_attrs) ==
               [
                 {"Group",
                  [
                    {"id", "container"},
                    {"data-phx-main", "true"},
                    {"data-phx-session", "session"},
                    {"data-phx-static", "static"}
                  ], ["contents"]}
               ]
    end
  end
end
