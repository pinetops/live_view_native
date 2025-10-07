defmodule LiveViewNativeTest.MinimalTemplateBugLive do
  use Phoenix.LiveView

  use LiveViewNative.LiveView,
    formats: [:gameboy],
    dispatch_to: &Module.concat/2

  defmodule GameBoy do
    use LiveViewNative.Component,
      format: :gameboy,
      as: :render

    def render(assigns, _interface) do
      ~LVN"""
      <%= for item <- @empty do %>
        empty:{item}
      <% end %>
      <%= for item <- @items do %>
        lv:{item}
      <% end %>
      """
    end
  end

  def render(assigns), do: ~H""

  def mount(_params, _session, socket) do
    {:ok, assign(socket, empty: [], items: [])}
  end

  def handle_call({:set_items, items}, _from, socket) do
    {:reply, :ok, assign(socket, items: items)}
  end

  def run(lv, func) do
    GenServer.call(lv.pid, func)
  end
end
