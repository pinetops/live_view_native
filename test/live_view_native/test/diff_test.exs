defmodule LiveViewNative.DiffTest do
  use ExUnit.Case, async: true

  alias LiveViewNativeTest.ViewTree

  describe "merge_diff" do
    test "merges unless static" do
      assert ViewTree.merge_diff(%{0 => "bar", s: "foo"}, %{0 => "baz"}) ==
               %{0 => "baz", s: "foo", streams: []}

      assert ViewTree.merge_diff(%{s: "foo", d: []}, %{s: "bar"}) ==
               %{s: "bar", streams: []}
    end
  end
end
