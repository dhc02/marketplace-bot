defmodule MarketplaceBot.Repo.Migrations.CreateListings do
  use Ecto.Migration

  def change do
    create table(:listings) do
      add :fb_id, :string, null: false
      add :url, :string
      add :title, :string
      add :price_cents, :integer
      add :currency, :string
      add :description, :text
      add :city, :string
      add :state, :string
      add :lat, :float
      add :lng, :float
      add :images, {:array, :string}, default: []
      add :seller, :string
      add :condition, :string
      add :fb_created_at, :utc_datetime
      add :is_live, :boolean
      add :is_sold, :boolean
      add :is_pending, :boolean
      add :is_receiver, :boolean, default: true, null: false
      add :model_id, references(:models, on_delete: :nilify_all)
      add :earc_verdict, :string
      add :status, :string, default: "new", null: false
      add :first_seen_at, :utc_datetime
      add :notified_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:listings, [:fb_id])
    create index(:listings, [:status])
    create index(:listings, [:earc_verdict])
  end
end
