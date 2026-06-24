defmodule MarketplaceBot.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :fetched, :integer, default: 0
      add :new, :integer, default: 0
      add :matched, :integer, default: 0
      add :errors, :map, default: %{}
      timestamps(type: :utc_datetime)
    end
  end
end
