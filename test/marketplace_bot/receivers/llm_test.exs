defmodule MarketplaceBot.Receivers.LLMTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Receivers.LLM

  # DeepSeek = OpenAI-compatible: assistant content is choices[0].message.content
  defp stub(content_json) do
    Req.Test.stub(MarketplaceBot.DeepSeek, fn conn ->
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => content_json}}]})
    end)
  end

  test "parses a structured classify/extract response" do
    stub(~s({"is_av_receiver": true, "brand": "Sony", "model": "STR-DN1080"}))

    assert {:ok, %{is_av_receiver: true, brand: "Sony", model: "STR-DN1080"}} =
             LLM.classify_extract(
               %{title: "Sony surround receiver", description: "model STR-DN1080"},
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.DeepSeek}]
             )
  end

  test "returns is_av_receiver false for non-AV items" do
    stub(~s({"is_av_receiver": false}))

    assert {:ok, %{is_av_receiver: false, brand: nil, model: nil}} =
             LLM.classify_extract(%{title: "wifi receiver dongle"},
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.DeepSeek}]
             )
  end
end
