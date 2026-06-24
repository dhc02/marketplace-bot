defmodule MarketplaceBot.Earc.LLM.Behaviour do
  @callback lookup(brand :: String.t() | nil, model :: String.t() | nil, opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end

defmodule MarketplaceBot.Earc.LLM do
  @moduledoc """
  eARC lookup: Kagi FastGPT researches the model, then deepseek-v4-pro converts
  the research into a "yes" / "no" / "unknown" verdict.
  """
  @behaviour MarketplaceBot.Earc.LLM.Behaviour
  alias MarketplaceBot.{Kagi, DeepSeek}

  @impl true
  def lookup(brand, model, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    deepseek_model = opts[:model] || cfg[:earc_model] || "deepseek-v4-pro"

    query = "Does the AV receiver \"#{brand} #{model}\" support HDMI eARC (enhanced ARC)? Cite manufacturer specs."

    research =
      case Kagi.fastgpt(query, opts) do
        {:ok, %{answer: answer}} -> answer
        {:error, _} -> ""
      end

    prompt = """
    Based on the research below, decide whether the AV receiver "#{brand} #{model}"
    supports HDMI eARC (enhanced ARC — NOT plain ARC). eARC arrived ~2019 and became
    standard in HDMI-2.1 lineups (2020+). Answer "yes" only if eARC is confirmed,
    "no" if confirmed absent, "unknown" if the research does not settle it.

    Research:
    #{research}

    Respond with ONLY a JSON object: {"verdict": "yes" or "no" or "unknown"}
    """

    with {:ok, json} <- DeepSeek.chat([%{role: "user", content: prompt}], deepseek_model, opts),
         {:ok, %{"verdict" => v}} when v in ["yes", "no", "unknown"] <- Jason.decode(json) do
      {:ok, v}
    else
      {:error, _} = err -> err
      _ -> {:ok, "unknown"}
    end
  end
end
