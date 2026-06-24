defmodule MarketplaceBot.Kagi do
  @moduledoc "Thin Kagi FastGPT client over Req. Returns the researched answer + references."

  @spec fastgpt(String.t(), keyword()) ::
          {:ok, %{answer: String.t(), references: list()}} | {:error, term()}
  def fastgpt(query, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])

    # Env-driven so a v0 -> v1 cutover is zero-code. Endpoint: KAGI_FASTGPT_URL.
    # Token: KAGI_TOKEN (explicit) else the v0 key (FastGPT currently lives at
    # /api/v0) else the v1 key. To move to v1: set KAGI_FASTGPT_URL=.../api/v1/fastgpt
    # and KAGI_TOKEN=<v1 token>.
    api_key =
      opts[:kagi_api_key] || System.get_env("KAGI_TOKEN") ||
        System.get_env("KAGI_V0_API_KEY") || System.get_env("KAGI_API_KEY")

    url =
      opts[:kagi_fastgpt_url] || System.get_env("KAGI_FASTGPT_URL") ||
        cfg[:kagi_fastgpt_url] || "https://kagi.com/api/v0/fastgpt"

    req_opts =
      [
        method: :post,
        url: url,
        headers: [{"authorization", "Bot #{api_key}"}],
        json: %{query: query},
        receive_timeout: opts[:receive_timeout] || 60_000
      ]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, %{answer: data["output"] || "", references: data["references"] || []}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:kagi_http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
