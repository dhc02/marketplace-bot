defmodule MarketplaceBot.Receivers.Extractor do
  @moduledoc """
  Cheap, pure first passes for the classify/extract step:
  a negative-keyword prefilter and a regex fast-path for common AV brands.
  Anything not handled here falls through to the LLM (see Receivers).
  """

  @negative ~w(hitch trailer satellite directv dish gps antenna radar fuel
               drone vape baby walkie cb)

  # {brand, regex}. Regex captures the full model token in group 1.
  @patterns [
    {"Denon", ~r/\b(AVR[- ]?X?\d{3,4}H?)\b/i},
    {"Marantz", ~r/(?<![A-Za-z0-9-])((?:SR|NR)\d{3,4})\b/i},
    {"Marantz", ~r/\b(Cinema\s?\d{1,2})\b/i},
    {"Yamaha", ~r/\b(RX[- ]?[VA]\d{3,4}[A-Z]?)\b/i},
    {"Onkyo", ~r/\b(TX[- ]?(?:NR|RZ)\d{2,4})\b/i},
    {"Pioneer", ~r/\b(VSX[- ]?\d{3,4})\b/i},
    {"Sony", ~r/\b(STR[- ]?(?:DH|DN|AN)\d{3,4})\b/i},
    {"Anthem", ~r/\b(MRX\s?\d{3,4})\b/i},
    {"NAD", ~r/\b(T\s?7\d{2,3})\b/i},
    {"Integra", ~r/\b(DRX[- ]?\d{1,2}\.\d)\b/i},
    {"Arcam", ~r/\b(AVR\d{2,3})\b/i}
  ]

  @spec likely_non_av?(String.t()) :: boolean()
  def likely_non_av?(text) when is_binary(text) do
    down = String.downcase(text)
    Enum.any?(@negative, &String.contains?(down, &1))
  end

  def likely_non_av?(_), do: false

  @spec extract(String.t()) :: {:ok, String.t(), String.t()} | :unknown
  def extract(text) when is_binary(text) do
    Enum.find_value(@patterns, :unknown, fn {brand, re} ->
      case Regex.run(re, text, capture: :all_but_first) do
        [model | _] -> {:ok, brand, normalize_model(model)}
        _ -> nil
      end
    end)
  end

  def extract(_), do: :unknown

  # Uppercase, collapse internal spaces, ensure a hyphen after the alpha prefix.
  defp normalize_model(model) do
    model
    |> String.upcase()
    |> String.replace(~r/\s+/, "")
    |> insert_hyphen()
  end

  defp insert_hyphen(m) do
    cond do
      String.contains?(m, "-") -> m
      Regex.match?(~r/^[A-Z]+\d/, m) -> Regex.replace(~r/^([A-Z]+)(\d.*)$/, m, "\\1-\\2")
      true -> m
    end
  end
end
