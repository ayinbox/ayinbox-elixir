defmodule AyInboxTest do
  use ExUnit.Case, async: true

  import AyInbox.Fixtures
  import Plug.Conn

  alias AyInbox.Error

  @campaign_id "11111111-1111-4111-8111-111111111111"
  @contact_id "22222222-2222-4222-8222-111111111111"

  describe "client" do
    test "sends the auth header, user agent and accept header" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        send(self(), {:headers, conn.req_headers, conn.request_path})
        respond(conn, 200, "me.json")
      end)

      assert {:ok, me} = AyInbox.Me.get(client())
      assert me["email"] == "dana@example.com"
      assert me["scopes"] == ["read_campaigns", "read_contacts", "write_contacts"]

      assert_received {:headers, headers, "/v1/me"}
      assert {"authorization", "Bearer aybox_test_key"} in headers
      assert {"user-agent", "ayinbox-elixir/0.1.0"} in headers
      assert {"accept", "application/json"} in headers
      refute List.keymember?(headers, "idempotency-key", 0)
    end

    test "reads the key and base URL from the environment" do
      System.put_env("AYINBOX_API_KEY", "aybox_from_env")
      System.put_env("AYINBOX_BASE_URL", "https://example.test/v1/")

      try do
        client = AyInbox.new()
        assert client.api_key == "aybox_from_env"
        assert client.base_url == "https://example.test/v1"
      after
        System.delete_env("AYINBOX_API_KEY")
        System.delete_env("AYINBOX_BASE_URL")
      end
    end

    test "never shows the key when inspected" do
      refute inspect(client()) =~ "aybox_test_key"
    end

    test "raises without a key" do
      System.delete_env("AYINBOX_API_KEY")
      assert_raise ArgumentError, fn -> AyInbox.new(api_key: "") end
    end
  end

  describe "errors" do
    for {fixture, type, status, code} <- [
          {"400_bad_request.json", :bad_request, 400, "bad_request"},
          {"400_invalid_cursor.json", :bad_request, 400, "bad_request"},
          {"401_unauthorized.json", :authentication, 401, "unauthorized"},
          {"401_api_key_holder_left.json", :authentication, 401, "api_key_holder_left"},
          {"402_insufficient_credits.json", :payment_required, 402, "insufficient_credits"},
          {"403_forbidden.json", :permission_denied, 403, "forbidden"},
          {"403_api_key_mailbox_limited.json", :permission_denied, 403,
           "api_key_mailbox_limited"},
          {"404_not_found.json", :not_found, 404, "not_found"},
          {"409_conflict.json", :conflict, 409, "conflict"},
          {"409_idempotency_outcome_unknown.json", :conflict, 409,
           "idempotency_outcome_unknown"},
          {"409_idempotent_secret_withheld.json", :conflict, 409, "idempotent_secret_withheld"},
          {"422_unprocessable.json", :unprocessable, 422, "unprocessable"},
          {"500_internal_error.json", :internal_server, 500, "internal_error"}
        ] do
      @fixture fixture
      @type_ type
      @status status
      @code code

      test "maps #{fixture}" do
        Req.Test.stub(AyInbox.Stub, fn conn -> error(conn, @fixture) end)

        assert {:error, %Error{} = error} = AyInbox.Campaigns.get(client(), @campaign_id)
        assert error.type == @type_
        assert error.status == @status
        assert error.code == @code
        assert error.request_id == "req-fixture-0001"
        assert is_binary(error.message) and error.message != ""
        refute Exception.message(error) =~ "aybox_test_key"
        refute_received {:slept, _}
      end
    end

    test "maps a 429 with a code and retry_after" do
      Req.Test.stub(AyInbox.Stub, fn conn -> error(conn, "429_api_key_rate_limited.json") end)

      assert {:error, error} = AyInbox.Me.get(client(max_retries: 0))
      assert error.type == :rate_limit
      assert error.code == "rate_limit_exceeded"
      assert error.retry_after == 12
      assert Error.rate_limited?(error)
    end

    test "maps a 429 with no code and no request_id" do
      Req.Test.stub(AyInbox.Stub, fn conn -> error(conn, "429_category_rate_limited.json") end)

      assert {:error, error} = AyInbox.Me.get(client(max_retries: 0))
      assert error.type == :rate_limit
      assert error.code == "rate_limit_exceeded"
      assert error.request_id == nil
      assert error.retry_after == 12
    end

    test "maps 503 and keeps a non-JSON body" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        conn |> put_resp_content_type("text/plain") |> send_resp(503, "upstream down")
      end)

      assert {:error, error} = AyInbox.Me.get(client(max_retries: 0))
      assert error.type == :service_unavailable
      assert error.code == "service_unavailable"
      assert error.message == "upstream down"
      assert Error.server_error?(error)
    end

    test "maps a transport failure to a connection error" do
      Req.Test.stub(AyInbox.Stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, error} = AyInbox.Me.get(client(max_retries: 0))
      assert error.type == :connection
      assert Error.network?(error)
    end
  end

  describe "retries" do
    test "retries a 503 then succeeds" do
      Req.Test.expect(AyInbox.Stub, fn conn -> error(conn, "503_service_unavailable.json") end)
      Req.Test.expect(AyInbox.Stub, fn conn -> respond(conn, 200, "me.json") end)

      assert {:ok, %{"user_id" => _}} = AyInbox.Me.get(client())
      assert_received {:slept, 5000}
    end

    test "honours Retry-After on a 429 then succeeds" do
      Req.Test.expect(AyInbox.Stub, fn conn -> error(conn, "429_api_key_rate_limited.json") end)
      Req.Test.expect(AyInbox.Stub, fn conn -> respond(conn, 200, "me.json") end)

      assert {:ok, _} = AyInbox.Me.get(client())
      assert_received {:slept, 12_000}
    end

    test "retries a keyless POST on 429, which never ran" do
      Req.Test.expect(AyInbox.Stub, fn conn -> error(conn, "429_api_key_rate_limited.json") end)
      Req.Test.expect(AyInbox.Stub, fn conn -> respond(conn, 200, "campaign.json") end)

      assert {:ok, _} = AyInbox.Campaigns.create(client(), %{name: "Q4"})
    end

    test "does not retry a keyless POST on 503" do
      Req.Test.expect(AyInbox.Stub, 1, fn conn ->
        error(conn, "503_service_unavailable.json")
      end)

      assert {:error, %Error{status: 503}} = AyInbox.Campaigns.create(client(), %{name: "Q4"})
      refute_received {:slept, _}
    end

    test "retries a POST that carries an idempotency key" do
      Req.Test.expect(AyInbox.Stub, fn conn ->
        send(self(), {:key, get_req_header(conn, "idempotency-key")})
        error(conn, "503_service_unavailable.json")
      end)

      Req.Test.expect(AyInbox.Stub, fn conn ->
        send(self(), {:key, get_req_header(conn, "idempotency-key")})
        respond(conn, 200, "campaign.json")
      end)

      assert {:ok, _} =
               AyInbox.Campaigns.create(client(), %{name: "Q4"}, idempotency_key: "key-1")

      assert_received {:key, ["key-1"]}
      assert_received {:key, ["key-1"]}
    end

    test "does not retry a 500" do
      Req.Test.expect(AyInbox.Stub, 1, fn conn -> error(conn, "500_internal_error.json") end)
      assert {:error, %Error{status: 500}} = AyInbox.Me.get(client())
    end

    test "gives up after max_retries" do
      Req.Test.expect(AyInbox.Stub, 3, fn conn ->
        error(conn, "503_service_unavailable.json")
      end)

      assert {:error, %Error{type: :service_unavailable}} = AyInbox.Me.get(client())
    end
  end

  describe "idempotency" do
    test "sends the Idempotency-Key header" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        send(self(), {:key, get_req_header(conn, "idempotency-key")})
        respond(conn, 200, "contacts_create.json")
      end)

      assert {:ok, [contact]} =
               AyInbox.Contacts.create(client(), %{email: "lee@example.com"},
                 idempotency_key: "create-lee-1"
               )

      assert contact["email"] == "lee@example.com"
      assert_received {:key, ["create-lee-1"]}
    end
  end

  describe "pagination" do
    test "walks two pages of campaigns" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        conn = fetch_query_params(conn)
        send(self(), {:query, conn.query_params})

        case conn.query_params["cursor"] do
          nil -> respond(conn, 200, "campaigns_list.json")
          "c1_ZmFrZS1jdXJzb3ItcGFnZS0y" -> respond(conn, 200, "campaigns_list_page2.json")
        end
      end)

      campaigns = client() |> AyInbox.Campaigns.stream(%{status: "draft"}) |> Enum.to_list()

      expected =
        length(json("campaigns_list.json")["data"]) +
          length(json("campaigns_list_page2.json")["data"])

      assert length(campaigns) == expected
      assert_received {:query, %{"status" => "draft"} = first}
      refute Map.has_key?(first, "cursor")

      assert_received {:query,
                       %{"status" => "draft", "cursor" => "c1_ZmFrZS1jdXJzb3ItcGFnZS0y"}}
    end

    test "raises the error when a page fails" do
      Req.Test.stub(AyInbox.Stub, fn conn -> error(conn, "400_invalid_cursor.json") end)

      assert_raise Error, fn ->
        client() |> AyInbox.paginate("/campaigns", query: [cursor: "bad"]) |> Enum.to_list()
      end
    end
  end

  describe "resources" do
    test "campaigns: list, get, create and pause" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        {:ok, body, conn} = read_body(conn)
        send(self(), {:req, conn.method, conn.request_path, body})

        case {conn.method, conn.request_path} do
          {"GET", "/v1/campaigns"} -> respond(conn, 200, "campaigns_list.json")
          {"GET", "/v1/campaigns/" <> _} -> respond(conn, 200, "campaign.json")
          {"POST", "/v1/campaigns"} -> respond(conn, 200, "campaign.json")
          {"POST", "/v1/campaigns/" <> _} -> respond(conn, 200, "campaign_stop.json")
        end
      end)

      c = client()
      assert {:ok, %{"data" => [_ | _], "pagination" => %{"has_more" => true}}} =
               AyInbox.Campaigns.list(c, limit: 10)

      assert {:ok, %{"id" => _}} = AyInbox.Campaigns.get(c, @campaign_id)
      assert {:ok, %{"name" => _}} = AyInbox.Campaigns.create(c, %{name: "Q4 outreach"})
      assert_received {:req, "POST", "/v1/campaigns", ~s({"name":"Q4 outreach"})}

      assert {:ok, %{"status" => "stopped"}} = AyInbox.Campaigns.pause(c, @campaign_id)
      assert_received {:req, "POST", "/v1/campaigns/" <> @campaign_id <> "/stop", ""}
    end

    test "contacts: list, get, create, update and delete" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        conn = fetch_query_params(conn)
        {:ok, body, conn} = read_body(conn)
        send(self(), {:req, conn.method, conn.request_path, conn.query_params, body})

        case {conn.method, conn.request_path} do
          {"POST", "/v1/contacts/search"} -> respond(conn, 200, "contacts_list.json")
          {"GET", "/v1/contacts/" <> _} -> respond(conn, 200, "contact.json")
          {"POST", "/v1/contacts"} -> respond(conn, 200, "contacts_create.json")
          {"PATCH", "/v1/contacts/" <> _} -> respond(conn, 200, "contact.json")
          {"DELETE", "/v1/contacts/" <> _} -> send_resp(conn, 204, "")
        end
      end)

      c = client()

      assert {:ok, %{"data" => [_ | _]}} =
               AyInbox.Contacts.list(c, %{limit: 25, query: "lee", subscribed: true})

      assert_received {:req, "POST", "/v1/contacts/search", %{"limit" => "25"}, body}
      assert Jason.decode!(body) == %{"query" => "lee", "subscribed" => true}

      assert [_ | _] = c |> AyInbox.Contacts.stream() |> Enum.to_list()
      assert_received {:req, "POST", "/v1/contacts/search", _, "{}"}

      assert {:ok, %{"id" => _}} = AyInbox.Contacts.get(c, @contact_id)
      assert {:ok, [_]} = AyInbox.Contacts.create(c, [%{email: "lee@example.com"}])

      assert {:ok, %{"id" => _}} =
               AyInbox.Contacts.update(c, @contact_id, %{company: "Example Co"})

      assert_received {:req, "PATCH", _, _, ~s({"company":"Example Co"})}

      assert {:ok, nil} = AyInbox.Contacts.delete(c, @contact_id)
      assert_received {:req, "DELETE", "/v1/contacts/" <> @contact_id, _, ""}
    end

    test "mailboxes: list and stream" do
      Req.Test.stub(AyInbox.Stub, fn conn -> respond(conn, 200, "mailboxes_list.json") end)

      assert {:ok, %{"data" => [mailbox | _]}} = AyInbox.Mailboxes.list(client())
      assert mailbox["email"] == "sales@example.com"
      assert length(Enum.to_list(AyInbox.Mailboxes.stream(client()))) == 2
    end

    test "unibox: list_threads and get_thread" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        conn = fetch_query_params(conn)
        send(self(), {:req, conn.request_path, conn.query_params})

        case conn.request_path do
          "/v1/unibox" -> respond(conn, 200, "unibox_threads.json")
          "/v1/unibox/thread" -> respond(conn, 200, "unibox_thread.json")
        end
      end)

      c = client()
      assert {:ok, %{"data" => [thread]}} = AyInbox.Unibox.list_threads(c, unseen: true)
      assert_received {:req, "/v1/unibox", %{"unseen" => "true"}}

      assert {:ok, %{"data" => [_, _]}} = AyInbox.Unibox.get_thread(c, thread["thread_id"])
      assert_received {:req, "/v1/unibox/thread", %{"thread_id" => "thread-example-001"}}
    end

    test "request reaches any route" do
      Req.Test.stub(AyInbox.Stub, fn conn ->
        send(self(), {:req, conn.method, conn.request_path})
        send_resp(conn, 200, "")
      end)

      assert {:ok, nil} = AyInbox.request(client(), "DELETE", "/campaigns/x/steps/y")
      assert_received {:req, "DELETE", "/v1/campaigns/x/steps/y"}
    end
  end
end
