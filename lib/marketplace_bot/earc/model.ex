defmodule MarketplaceBot.Earc.Model do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "models" do
    field :brand, :string
    field :model, :string
    field :key, :string
    field :verdict, :string, default: "unknown"
    field :source, :string, default: "seed"
    field :notes, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(model, attrs) do
    model
    |> cast(attrs, [:brand, :model, :key, :verdict, :source, :notes])
    |> validate_required([:key])
    |> validate_inclusion(:verdict, ~w(yes no unknown))
    |> validate_inclusion(:source, ~w(seed llm user))
    |> unique_constraint(:key)
  end
end
