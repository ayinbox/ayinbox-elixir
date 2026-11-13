defmodule AyInbox.Fixtures do
  @moduledoc false

  import Plug.Conn

  @dir Path.expand("../fixtures", __DIR__)

  def read(name), do: File.read!(Path.join(@dir, name))

  def json(name), do: name |> read() |> Jason.decode!()

  def client(opts \\ []) do
    test = self()

    AyInbox.new(
      Keyword.merge(
        [
          api_key: "aybox_test_key",
          base_url: "https://api.test/v1/",
          req_options: [plug: {Req.Test, AyInbox.Stub}],
          sleep: fn ms -> send(test, {:slept, ms}) end
        ],
        opts
      )
    )
  end

  def respond(conn, status, fixture, headers \\ []) do
    conn = put_resp_header(conn, "content-type", "application/json; charset=utf-8")
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_resp_header(acc, k, v) end)
    body = if fixture, do: read(fixture), else: ""
    send_resp(conn, status, body)
  end

  def error(conn, name) do
    meta = error_meta()[name]
    respond(conn, meta.status, "errors/" <> name, meta.headers)
  end

  defp error_meta do
    rid = [{"x-request-id", "req-fixture-0001"}]

    %{
      "400_bad_request.json" => %{status: 400, headers: rid},
      "400_invalid_cursor.json" => %{status: 400, headers: rid},
      "401_unauthorized.json" => %{status: 401, headers: rid},
      "401_api_key_holder_left.json" => %{status: 401, headers: rid},
      "402_insufficient_credits.json" => %{status: 402, headers: rid},
      "403_forbidden.json" => %{status: 403, headers: rid},
      "403_api_key_mailbox_limited.json" => %{status: 403, headers: rid},
      "404_not_found.json" => %{status: 404, headers: rid},
      "409_conflict.json" => %{status: 409, headers: rid},
      "409_idempotency_outcome_unknown.json" => %{status: 409, headers: rid},
      "409_idempotent_secret_withheld.json" => %{status: 409, headers: rid},
      "422_unprocessable.json" => %{status: 422, headers: rid},
      "429_api_key_rate_limited.json" => %{
        status: 429,
        headers: rid ++ [{"retry-after", "12"}, {"x-ratelimit-limit", "60"}]
      },
      "429_category_rate_limited.json" => %{
        status: 429,
        headers: [{"x-ratelimit-limit", "100"}, {"x-ratelimit-reset", "1700000060"}]
      },
      "500_internal_error.json" => %{status: 500, headers: rid},
      "503_service_unavailable.json" => %{status: 503, headers: rid ++ [{"retry-after", "5"}]}
    }
  end
end
