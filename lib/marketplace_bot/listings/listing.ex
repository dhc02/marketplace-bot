defmodule MarketplaceBot.Listings.Listing do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @cast_fields ~w(fb_id url title price_cents currency description city state lat lng
                  images seller condition fb_created_at is_live is_sold is_pending
                  is_receiver model_id earc_verdict status first_seen_at notified_at
                  image_dims)a

  schema "listings" do
    field :fb_id, :string
    field :url, :string
    field :title, :string
    field :price_cents, :integer
    field :currency, :string
    field :description, :string
    field :city, :string
    field :state, :string
    field :lat, :float
    field :lng, :float
    field :images, {:array, :string}, default: []
    field :image_dims, :map
    field :seller, :string
    field :condition, :string
    field :fb_created_at, :utc_datetime
    field :is_live, :boolean
    field :is_sold, :boolean
    field :is_pending, :boolean
    field :is_receiver, :boolean, default: true
    field :model_id, :id
    field :earc_verdict, :string
    field :status, :string, default: "new"
    field :first_seen_at, :utc_datetime
    field :notified_at, :utc_datetime
    field :distance_mi, :float, virtual: true
    timestamps(type: :utc_datetime)
  end

  def changeset(listing, attrs) do
    listing
    |> cast(attrs, @cast_fields)
    |> validate_required([:fb_id])
    |> unique_constraint(:fb_id)
  end
end
