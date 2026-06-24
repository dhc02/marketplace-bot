defmodule MarketplaceBotWeb.PageController do
  use MarketplaceBotWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
