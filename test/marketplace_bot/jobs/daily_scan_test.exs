defmodule MarketplaceBot.Jobs.DailyScanTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Jobs.DailyScan
  alias MarketplaceBot.{Listings, Runs}

  # Capture digest calls
  defmodule CapNotifier do
    @behaviour MarketplaceBot.Notifier.Behaviour
    @impl true
    def send_digest(listings, _opts \\ []) do
      send(self(), {:digest, Enum.map(listings, & &1.fb_id)})
      {:ok, :ok}
    end
  end

  defmodule YesLLM do
    @behaviour MarketplaceBot.Earc.LLM.Behaviour
    @impl true
    def lookup(_b, _m, _o \\ []), do: {:ok, "yes"}
  end

  setup do
    listings = [
      %{fb_id: "a", title: "Denon AVR-X3700H 9.2", url: "u-a"},
      %{fb_id: "b", title: "Trailer hitch receiver", url: "u-b"},
      %{fb_id: "c", title: "Sony STR-DN1080", url: "u-c"}
    ]

    opts = [
      source: MarketplaceBot.Sources.Fake,
      source_opts: [listings: listings],
      earc_llm: YesLLM,
      notifier: CapNotifier
    ]

    %{opts: opts}
  end

  test "fetch → dedup → classify → resolve → notify → record", %{opts: opts} do
    assert {:ok, summary} = DailyScan.run(opts)

    # a (Denon) and c (Sony) are receivers; b (hitch) is filtered out
    assert summary.new == 3
    assert summary.matched == 2

    a = Repo.get_by!(Listings.Listing, fb_id: "a")
    assert a.is_receiver and a.earc_verdict == "yes" and a.notified_at != nil

    b = Repo.get_by!(Listings.Listing, fb_id: "b")
    refute b.is_receiver

    assert_received {:digest, ids}
    assert Enum.sort(ids) == ["a", "c"]

    assert [%{matched: 2, new: 3}] = Runs.list_recent(1)
  end

  test "second run with same listings notifies nobody new", %{opts: opts} do
    {:ok, _} = DailyScan.run(opts)
    assert {:ok, %{new: 0, matched: 0}} = DailyScan.run(opts)
  end

  test "fetch error records a run with errors and returns {:error, ...} without raising" do
    defmodule ErrorSource do
      @behaviour MarketplaceBot.Sources.Source
      @impl true
      def fetch(_opts), do: {:error, :boom}
    end

    defmodule NoOpNotifier do
      @behaviour MarketplaceBot.Notifier.Behaviour
      @impl true
      def send_digest(_listings, _opts \\ []), do: {:ok, :ok}
    end

    result = DailyScan.run(source: ErrorSource, notifier: NoOpNotifier)

    assert {:error, %{reason: :boom}} = result

    [run] = Runs.list_recent(1)
    assert run.errors["fetch"] != nil
  end

  defmodule AvNoModelLLM do
    @behaviour MarketplaceBot.Receivers.LLM.Behaviour
    @impl true
    def classify_extract(_l, _o \\ []), do: {:ok, %{is_av_receiver: true, brand: "Marantz", model: nil}}
  end

  defmodule FoundVision do
    @behaviour MarketplaceBot.Vision
    @impl true
    def extract_model(_imgs, _o \\ []), do: {:ok, %{brand: "Marantz", model: "SR6004"}}
  end

  test "recovers model via vision for a receiver with no parsed model, then resolves eARC" do
    listings = [
      %{fb_id: "vis1", title: "marantz home theater receiver", url: "u", images: ["http://img/1.jpg"]}
    ]

    opts = [
      source: MarketplaceBot.Sources.Fake,
      source_opts: [listings: listings],
      receiver_llm: AvNoModelLLM,
      vision: FoundVision,
      earc_llm: YesLLM,
      notifier: CapNotifier
    ]

    assert {:ok, %{matched: 1}} = DailyScan.run(opts)

    l = Repo.get_by!(MarketplaceBot.Listings.Listing, fb_id: "vis1")
    assert l.is_receiver
    assert l.model_id != nil
    assert l.earc_verdict == "yes"
  end
end
