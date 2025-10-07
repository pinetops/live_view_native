IO.puts "Testing Rendered structure for LVN vs HTML..."

# Compile a simple template with comprehension + component
defmodule TestLVN do
  use LiveViewNative.Component,
    format: :gameboy,
    as: :render

  def render(assigns, _interface) do
    ~LVN"""
    <%= for item <- @items do %>
      item: <%= item %>
    <% end %>
    <.test_component name="foo" />
    """
  end

  def test_component(assigns, _interface) do
    ~LVN"""
    <Text><%= @name %></Text>
    """
  end
end

defmodule TestHTML do
  import Phoenix.Component

  def render(assigns) do
    ~H"""
    <%= for item <- @items do %>
      item: <%= item %>
    <% end %>
    <.test_component name="foo" />
    """
  end

  def test_component(assigns) do
    ~H"""
    <span><%= @name %></span>
    """
  end
end

# Test both
lvn_assigns = %{items: ["a", "b"], __changed__: nil, _interface: %{}}
html_assigns = %{items: ["a", "b"], __changed__: nil}

lvn_rendered = TestLVN.render(lvn_assigns, %{})
html_rendered = TestHTML.render(html_assigns)

IO.puts "\n=== LVN Rendered ==="
IO.inspect(lvn_rendered, limit: :infinity, printable_limit: :infinity, pretty: true)

IO.puts "\n=== HTML Rendered ==="
IO.inspect(html_rendered, limit: :infinity, printable_limit: :infinity, pretty: true)

IO.puts "\n=== LVN Root Flag ==="
IO.puts "Root: #{inspect(lvn_rendered.root)}"

IO.puts "\n=== HTML Root Flag ==="
IO.puts "Root: #{inspect(html_rendered.root)}"
