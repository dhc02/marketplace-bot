defmodule MarketplaceBot.Receivers.LLMStub do
  @behaviour MarketplaceBot.Receivers.LLM.Behaviour
  @impl true
  def classify_extract(_listing, _opts \\ []), do: {:ok, %{is_av_receiver: false, brand: nil, model: nil}}
end

defmodule MarketplaceBot.Earc.LLMStub do
  @behaviour MarketplaceBot.Earc.LLM.Behaviour
  @impl true
  def lookup(_brand, _model, _opts \\ []), do: {:ok, "unknown"}
end

defmodule MarketplaceBot.Notifier.Stub do
  @behaviour MarketplaceBot.Notifier.Behaviour
  @impl true
  def send_digest(_listings, _opts \\ []), do: {:ok, :stubbed}
end

defmodule MarketplaceBot.Vision.Stub do
  @behaviour MarketplaceBot.Vision
  @impl true
  def extract_model(_image_urls, _opts \\ []), do: {:ok, %{brand: nil, model: nil}}
end
