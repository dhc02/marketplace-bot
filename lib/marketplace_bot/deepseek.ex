defmodule MarketplaceBot.DeepSeek do
  @moduledoc """
  Thin DeepSeek (OpenAI-compatible) chat-completions client over Req.
  Forces JSON-object output. Returns the assistant message content string.
  """

  @spec chat([map()], String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, model, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    api_key = opts[:api_key] || System.get_env("DEEPSEEK_API_KEY")
    base = opts[:base_url] || cfg[:deepseek_base_url] || "https://api.deepseek.com/v1"

    body =
      %{
        model: model,
        messages: messages,
        response_format: %{type: "json_object"}
      }
      |> Map.merge(opts[:body_extra] || %{})

    req_opts =
      [
        method: :post,
        url: base <> "/chat/completions",
        headers: [{"authorization", "Bearer #{api_key}"}],
        json: body,
        receive_timeout: opts[:receive_timeout] || 60_000
      ]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: resp}} -> first_content(resp)
      {:ok, %{status: status, body: body}} -> {:error, {:deepseek_http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content),
       do: {:ok, content}

  defp first_content(_), do: {:error, :bad_response}
end
