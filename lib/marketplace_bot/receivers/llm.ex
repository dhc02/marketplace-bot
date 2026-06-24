defmodule MarketplaceBot.Receivers.LLM.Behaviour do
  @callback classify_extract(listing :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end

defmodule MarketplaceBot.Receivers.LLM do
  @moduledoc "DeepSeek-backed classify + model-extract for ambiguous listings (deepseek-v4-flash)."
  @behaviour MarketplaceBot.Receivers.LLM.Behaviour
  alias MarketplaceBot.DeepSeek

  @impl true
  def classify_extract(listing, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    model = opts[:model] || cfg[:classify_model] || "deepseek-v4-flash"

    prompt = """
    Decide whether this Facebook Marketplace listing is a home-theater A/V receiver
    (a multi-channel surround-sound amplifier — NOT a trailer hitch, satellite/cable
    box, radio, wireless dongle, etc.). If it is, extract the brand and model.

    Title: #{listing[:title] || listing["title"]}
    Description: #{listing[:description] || listing["description"]}

    Respond with ONLY a JSON object of the exact form:
    {"is_av_receiver": true or false, "brand": string or null, "model": string or null}
    """

    messages = [%{role: "user", content: prompt}]

    with {:ok, json} <- DeepSeek.chat(messages, model, opts),
         {:ok, parsed} <- Jason.decode(json) do
      {:ok,
       %{
         is_av_receiver: parsed["is_av_receiver"] == true,
         brand: parsed["brand"],
         model: parsed["model"]
       }}
    end
  end
end
