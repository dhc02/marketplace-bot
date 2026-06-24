defmodule MarketplaceBot.ReceiversTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Receivers

  defmodule AvLLM do
    @behaviour MarketplaceBot.Receivers.LLM.Behaviour
    @impl true
    def classify_extract(_l, _o \\ []), do: {:ok, %{is_av_receiver: true, brand: "Yamaha", model: "RX-A8A"}}
  end

  defmodule NotAvLLM do
    @behaviour MarketplaceBot.Receivers.LLM.Behaviour
    @impl true
    def classify_extract(_l, _o \\ []), do: {:ok, %{is_av_receiver: false, brand: nil, model: nil}}
  end

  test "negative keyword short-circuits to :skip" do
    assert :skip = Receivers.classify_extract(%{title: "trailer hitch receiver"}, llm: AvLLM)
  end

  test "regex fast-path returns brand/model without the LLM" do
    assert {:ok, "Denon", "AVR-X3700H"} =
             Receivers.classify_extract(%{title: "Denon AVR-X3700H"}, llm: NotAvLLM)
  end

  test "ambiguous listing uses the LLM (av → ok)" do
    assert {:ok, "Yamaha", "RX-A8A"} =
             Receivers.classify_extract(%{title: "Yamaha home theater amp"}, llm: AvLLM)
  end

  test "ambiguous listing uses the LLM (not av → skip)" do
    assert :skip = Receivers.classify_extract(%{title: "generic stereo box"}, llm: NotAvLLM)
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

  defmodule EmptyVision do
    @behaviour MarketplaceBot.Vision
    @impl true
    def extract_model(_imgs, _o \\ []), do: {:ok, %{brand: nil, model: nil}}
  end

  defmodule RaiseVision do
    @behaviour MarketplaceBot.Vision
    @impl true
    def extract_model(_imgs, _o \\ []), do: raise("vision should not be called")
  end

  test "receiver with no parsed model recovers the model via vision" do
    assert {:ok, "Marantz", "SR6004"} =
             Receivers.classify_extract(
               %{title: "marantz home theater receiver", images: ["u"]},
               llm: AvNoModelLLM, vision: FoundVision
             )
  end

  test "stays unconfirmed (model nil) when vision finds nothing" do
    assert {:ok, "Marantz", nil} =
             Receivers.classify_extract(
               %{title: "marantz home theater receiver", images: ["u"]},
               llm: AvNoModelLLM, vision: EmptyVision
             )
  end

  test "vision is NOT called when regex already found a model" do
    assert {:ok, "Denon", "AVR-X3700H"} =
             Receivers.classify_extract(
               %{title: "Denon AVR-X3700H", images: ["u"]},
               llm: AvNoModelLLM, vision: RaiseVision
             )
  end

  test "vision is NOT called for a non-receiver" do
    assert :skip =
             Receivers.classify_extract(
               %{title: "trailer hitch receiver", images: ["u"]},
               llm: AvNoModelLLM, vision: RaiseVision
             )
  end
end
