defmodule MarketplaceBot.Vision.GeminiTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Vision.Gemini

  # One Req.Test stub serves BOTH the image download (fbcdn host) and the
  # Gemini call (generativelanguage host), branched on conn.host.
  defp stub(gemini_text) do
    Req.Test.stub(MarketplaceBot.Vision.Gemini, fn conn ->
      if conn.host =~ "generativelanguage" do
        Req.Test.json(conn, %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => gemini_text}]}}]
        })
      else
        Req.Test.text(conn, "FAKE-IMAGE-BYTES")
      end
    end)
  end

  test "downloads photos and parses brand/model from Gemini" do
    stub(~s({"brand": "Marantz", "model": "SR6004"}))

    assert {:ok, %{brand: "Marantz", model: "SR6004"}} =
             Gemini.extract_model(["https://scontent.fbcdn.net/x.jpg"],
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.Vision.Gemini}]
             )
  end

  test "returns {:error, :no_images} for an empty image list" do
    assert {:error, :no_images} =
             Gemini.extract_model([], req_options: [plug: {Req.Test, MarketplaceBot.Vision.Gemini}])
  end

  test "returns {:error, _} on a Gemini error (no crash)" do
    Req.Test.stub(MarketplaceBot.Vision.Gemini, fn conn ->
      if conn.host =~ "generativelanguage" do
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "rate"})
      else
        Req.Test.text(conn, "FAKE-IMAGE-BYTES")
      end
    end)

    assert {:error, _} =
             Gemini.extract_model(["https://scontent.fbcdn.net/x.jpg"],
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.Vision.Gemini}]
             )
  end
end
