defmodule DebugOrder do
  use LiveViewNative.Component,
    format: :gameboy,
    as: :render

  def render(assigns, _interface) do
    IO.puts("\n=== COMPILING TEMPLATE ===")
    ~LVN"""
    <%= for entry <- @entries do %>
      entry:<%= entry %>
    <% end %>
    <.test_input name="foo" />
    """
  end

  def test_input(assigns, _interface) do
    ~LVN"""
    <Input name={@name} />
    """
  end
end

# Trigger compilation
assigns = %{entries: ["a"], __changed__: nil, _interface: %{}}
IO.puts("\n=== CALLING RENDER ===")
result = DebugOrder.render(assigns, %{})
IO.puts("\n=== RESULT ===")
IO.inspect(result, limit: :infinity, pretty: true)

# Check dynamic
IO.puts("\n=== DYNAMIC ORDER ===")
result.dynamic.(false)
|> Enum.with_index()
|> Enum.each(fn {val, idx} ->
  type = cond do
    is_struct(val, Phoenix.LiveView.Comprehension) -> "Comprehension"
    is_struct(val, Phoenix.LiveView.Rendered) -> "Rendered"
    true -> "Other"
  end
  IO.puts("Position #{idx}: #{type}")
end)
