defmodule MarketplaceBot.Earc do
  @moduledoc "eARC resolver table: normalized model keys → yes/no/unknown verdicts."
  import Ecto.Query
  alias MarketplaceBot.Repo
  alias MarketplaceBot.Earc.Model

  @spec normalize_key(String.t() | nil, String.t() | nil) :: String.t()
  def normalize_key(brand, model) do
    [brand, model]
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  @spec find_by_key(String.t()) :: Model.t() | nil
  def find_by_key(key), do: Repo.get_by(Model, key: key)

  @spec upsert_model(String.t() | nil, String.t() | nil, map()) :: {:ok, Model.t()}
  def upsert_model(brand, model, attrs \\ %{}) do
    key = normalize_key(brand, model)
    base = find_by_key(key) || %Model{}

    {:ok, _} =
      base
      |> Model.changeset(Map.merge(%{brand: brand, model: model, key: key}, attrs))
      |> Repo.insert_or_update()
  end

  @spec set_user_verdict(Model.t(), String.t()) :: {:ok, Model.t()}
  def set_user_verdict(%Model{} = m, verdict) do
    m |> Model.changeset(%{verdict: verdict, source: "user"}) |> Repo.update()
  end

  @doc """
  Resolve eARC for a brand/model. Table is source of truth; user verdicts are
  authoritative. On a miss or a non-user "unknown", call the configured LLM and
  cache the result back as source "llm".
  """
  @spec resolve_with_fallback(String.t() | nil, String.t() | nil, keyword()) :: {:ok, Model.t()}
  def resolve_with_fallback(brand, model, opts \\ []) do
    llm = opts[:earc_llm] || opts[:llm] || Application.get_env(:marketplace_bot, :earc_llm)
    key = normalize_key(brand, model)

    # A receiver with no extractable brand/model has no eARC lookup key — return a
    # transient (unpersisted) "unknown" rather than trying to insert a keyless model.
    if key == "" do
      {:ok, %Model{brand: brand, model: model, verdict: "unknown", source: "llm"}}
    else
      resolve_known(llm, brand, model, key, opts)
    end
  end

  defp resolve_known(llm, brand, model, key, opts) do
    case find_by_key(key) do
      %Model{source: "user"} = m ->
        {:ok, m}

      %Model{verdict: v} = m when v in ["yes", "no"] ->
        {:ok, m}

      _ ->
        verdict =
          case llm.lookup(brand, model, opts) do
            {:ok, v} -> v
            {:error, _} -> "unknown"
          end

        upsert_model(brand, model, %{verdict: verdict, source: "llm"})
    end
  end

  @doc "All models, for the curation list view."
  def list_models, do: Repo.all(from m in Model, order_by: [asc: m.brand, asc: m.model])
end
