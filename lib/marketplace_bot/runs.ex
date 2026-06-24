defmodule MarketplaceBot.Runs do
  import Ecto.Query
  alias MarketplaceBot.Repo
  alias MarketplaceBot.Runs.Run

  @spec record(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs), do: %Run{} |> Run.changeset(attrs) |> Repo.insert()

  @spec list_recent(pos_integer()) :: [Run.t()]
  def list_recent(limit \\ 20),
    do: Repo.all(from r in Run, order_by: [desc: r.inserted_at], limit: ^limit)
end
