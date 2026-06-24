defmodule MarketplaceBot.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "runs" do
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :fetched, :integer, default: 0
    field :new, :integer, default: 0
    field :matched, :integer, default: 0
    field :errors, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs),
    do: cast(run, attrs, [:started_at, :finished_at, :fetched, :new, :matched, :errors])
end
