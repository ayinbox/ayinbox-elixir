defmodule AyInbox.Webhooks do
  @moduledoc """
  Verifies webhook deliveries. Local only, no HTTP.

  Each delivery carries `X-Ayinbox-Signature: t=<unix-seconds>,v1=<hex>`. The
  signature is HMAC-SHA256, keyed with the endpoint secret exactly as shown
  (including its `whsec_` prefix), over `"<t>.<raw body>"`.

  Verify the raw request body before any JSON parsing. In Plug, read it with a
  custom `body_reader` or `Plug.Conn.read_body/2` before `Plug.Parsers` runs.
  Deduplicate on `X-Ayinbox-Event-Id`, which stays the same across retries.
  """

  alias AyInbox.Error

  @default_tolerance 300

  @doc """
  Returns `true` when `header` is a valid signature of `payload` under `secret`.

  ## Options

    * `:tolerance` - maximum age in seconds, default `300`
    * `:now` - the current Unix time in seconds, default the system clock
  """
  @spec verify_signature(binary(), String.t() | nil, String.t(), keyword()) :: boolean()
  def verify_signature(payload, header, secret, opts \\ [])

  def verify_signature(payload, header, secret, opts)
      when is_binary(payload) and is_binary(header) and is_binary(secret) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, raw_t, t, signatures} <- parse_header(header),
         true <- abs(now - t) <= tolerance do
      expected =
        :crypto.mac(:hmac, :sha256, secret, [raw_t, ".", payload])
        |> Base.encode16(case: :lower)

      Enum.reduce(signatures, false, fn sig, acc -> secure_compare(expected, sig) or acc end)
    else
      _ -> false
    end
  end

  def verify_signature(_payload, _header, _secret, _opts), do: false

  @doc """
  Verifies the signature, then decodes the event envelope (`id`, `event_type`,
  `organization_id`, `created_at`, `data`).

  Returns `{:error, %AyInbox.Error{type: :signature_verification}}` when the
  signature does not verify or the body is not a JSON object.
  """
  @spec construct_event(binary(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def construct_event(payload, header, secret, opts \\ []) do
    with true <- verify_signature(payload, header, secret, opts),
         {:ok, event} when is_map(event) <- Jason.decode(payload) do
      {:ok, event}
    else
      false -> {:error, failure("the webhook signature did not verify")}
      _ -> {:error, failure("the webhook body is not a JSON object")}
    end
  end

  defp failure(message), do: %Error{type: :signature_verification, message: message}

  defp parse_header(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    raw_t = Enum.find_value(pairs, fn pair -> match_value(pair, "t") end)
    signatures = for ["v1", value] <- pairs, value != "", do: value

    with raw_t when is_binary(raw_t) <- raw_t,
         {t, ""} <- Integer.parse(raw_t),
         [_ | _] <- signatures do
      {:ok, raw_t, t, signatures}
    else
      _ -> :error
    end
  end

  defp match_value([key, value], key), do: value
  defp match_value(_pair, _key), do: nil

  defp secure_compare(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_compare(_a, _b), do: false
end
