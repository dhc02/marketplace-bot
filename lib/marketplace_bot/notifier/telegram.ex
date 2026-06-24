defmodule MarketplaceBot.Notifier.Behaviour do
  @callback send_digest(listings :: [struct()], opts :: keyword()) ::
              {:ok, term()} | {:error, term()} | :noop
end

defmodule MarketplaceBot.Notifier.Telegram do
  @moduledoc "Daily digest of new eARC matches via the Telegram Bot API."
  @behaviour MarketplaceBot.Notifier.Behaviour

  @impl true
  def send_digest(listings, opts \\ [])
  def send_digest([], _opts), do: :noop

  def send_digest(listings, opts) do
    token = opts[:token] || System.get_env("TELEGRAM_BOT_TOKEN")
    chat_id = opts[:chat_id] || System.get_env("TELEGRAM_CHAT_ID")
    base_url = opts[:web_base_url] || Application.get_env(:marketplace_bot, :web_base_url)

    body = %{
      chat_id: chat_id,
      text: build_digest(listings, base_url),
      parse_mode: "Markdown",
      disable_web_page_preview: true
    }

    req_opts =
      [
        method: :post,
        url: "https://api.telegram.org/bot#{token}/sendMessage",
        json: body,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:telegram_http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_digest([struct()], String.t()) :: String.t()
  def build_digest(listings, base_url) do
    header = "*#{length(listings)} new eARC receiver match(es):*\n"

    items =
      Enum.map_join(listings, "\n\n", fn l ->
        tag = if l.earc_verdict == "unknown", do: " _(eARC unconfirmed)_", else: ""
        price = format_price(l.price_cents, l.currency)

        "• *#{l.title}*#{tag}\n#{price} — #{l.city}\n[View](#{base_url}/listings/#{l.id}) · [FB](#{l.url})"
      end)

    header <> "\n" <> items
  end

  defp format_price(nil, _), do: "price n/a"
  defp format_price(cents, currency) do
    sym = if currency in [nil, "USD"], do: "$", else: "#{currency} "
    "#{sym}#{div(cents, 100)}"
  end
end
