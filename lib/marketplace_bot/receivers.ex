defmodule MarketplaceBot.Receivers do
  @moduledoc "Classify + extract: prefilter → regex fast-path → LLM fallback."
  alias MarketplaceBot.Receivers.Extractor

  @spec classify_extract(map() | struct(), keyword()) :: {:ok, String.t(), String.t()} | :skip
  def classify_extract(listing, opts \\ []) do
    title = field(listing, :title) || ""
    desc = field(listing, :description) || ""
    text = String.trim(title <> " " <> desc)

    cond do
      Extractor.likely_non_av?(text) ->
        :skip

      true ->
        case Extractor.extract(text) do
          {:ok, brand, model} -> {:ok, brand, model}
          :unknown -> via_llm(listing, opts)
        end
    end
  end

  defp via_llm(listing, opts) do
    llm = opts[:receiver_llm] || opts[:llm] || Application.get_env(:marketplace_bot, :receiver_llm)

    case llm.classify_extract(as_map(listing), opts) do
      {:ok, %{is_av_receiver: true, brand: brand, model: model}} ->
        if blank?(model), do: recover_via_vision(listing, brand, opts), else: {:ok, brand, model}

      _ ->
        :skip
    end
  end

  # Receiver confirmed but no model parsed from text — try reading the photos.
  defp recover_via_vision(listing, brand, opts) do
    vision = opts[:vision] || Application.get_env(:marketplace_bot, :vision)
    images = field(listing, :images) || []

    if vision && images != [] do
      case vision.extract_model(images, opts) do
        {:ok, %{model: m} = r} when is_binary(m) and m != "" -> {:ok, r[:brand] || brand, m}
        _ -> {:ok, brand, nil}
      end
    else
      {:ok, brand, nil}
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

  defp field(m, k) when is_map(m), do: Map.get(m, k) || Map.get(m, to_string(k))
  defp as_map(%_{} = s), do: Map.from_struct(s)
  defp as_map(m), do: m
end
