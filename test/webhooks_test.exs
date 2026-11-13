defmodule AyInbox.WebhooksTest do
  use ExUnit.Case, async: true

  alias AyInbox.Webhooks

  setup do
    {:ok, vector: AyInbox.Fixtures.json("webhook_signature.json")}
  end

  test "accepts the test vector", %{vector: v} do
    assert Webhooks.verify_signature(v["body"], v["header"], v["secret"], now: v["timestamp"])

    assert {:ok, event} =
             Webhooks.construct_event(v["body"], v["header"], v["secret"], now: v["timestamp"])

    assert event["event_type"] == "campaign.reply_received"
  end

  test "computes the expected v1", %{vector: v} do
    header = "t=#{v["timestamp"]},v1=#{v["expected_v1"]}"
    assert header == v["header"]
  end

  test "rejects a tampered body", %{vector: v} do
    refute Webhooks.verify_signature(v["body"] <> " ", v["header"], v["secret"],
             now: v["timestamp"]
           )
  end

  test "rejects the wrong secret", %{vector: v} do
    refute Webhooks.verify_signature(v["body"], v["header"], "whsec_other", now: v["timestamp"])

    assert {:error, %AyInbox.Error{type: :signature_verification}} =
             Webhooks.construct_event(v["body"], v["header"], "whsec_other", now: v["timestamp"])
  end

  test "enforces the tolerance", %{vector: v} do
    assert Webhooks.verify_signature(v["body"], v["header"], v["secret"], now: 1_700_000_300)
    refute Webhooks.verify_signature(v["body"], v["header"], v["secret"], now: 1_700_000_301)
  end

  test "accepts any matching v1 and ignores other schemes", %{vector: v} do
    header = "t=1700000000,v0=abc,v1=#{String.duplicate("0", 64)},v1=#{v["expected_v1"]}"
    assert Webhooks.verify_signature(v["body"], header, v["secret"], now: v["timestamp"])
  end

  test "rejects malformed headers", %{vector: v} do
    for header <- [nil, "", "v1=#{v["expected_v1"]}", "t=1700000000", "t=abc,v1=00"] do
      refute Webhooks.verify_signature(v["body"], header, v["secret"], now: v["timestamp"])
    end
  end
end
