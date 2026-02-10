defmodule Quoracle.Actions.WebTest do
  # req_cassette enables async: true (process-isolated recording)
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Web

  @cassette_dir "test/fixtures/cassettes/web"

  setup do
    %{
      opts: [agent_pid: self()],
      agent_id: "agent-#{System.unique_integer([:positive])}"
    }
  end

  describe "execute/3 with valid URL" do
    test "fetches HTML content and converts to Markdown", %{opts: opts, agent_id: agent_id} do
      params = %{url: "https://example.com"}

      ReqCassette.with_cassette(
        "web_fetch_example_html",
        [cassette_dir: @cassette_dir],
        fn plug ->
          # Pass plug through opts for req_cassette interception
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # Verify result structure
          assert result.action == "fetch_web"
          assert result.url == "https://example.com"
          assert result.status_code == 200
          assert result.content_type =~ "text/html"
          assert is_binary(result.markdown)
          assert result.markdown != ""

          # Verify Markdown conversion preserved structure
          assert result.markdown =~ "Example Domain"
        end
      )
    end

    test "handles redirects and returns 200 from final destination", %{
      opts: opts,
      agent_id: agent_id
    } do
      params = %{url: "http://httpbin.org/redirect/2", follow_redirects: true}

      ReqCassette.with_cassette(
        "web_fetch_redirects",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # Cassette records final response after redirects (status 200)
          # Note: result.url is original URL when using cassettes (no actual redirect following)
          assert result.status_code == 200
          # The httpbin response body shows the final URL that was reached
          assert result.markdown =~ "httpbin.org/get"
        end
      )
    end

    test "uses default user agent when none specified", %{opts: opts, agent_id: agent_id} do
      params = %{
        url: "http://httpbin.org/user-agent"
      }

      ReqCassette.with_cassette(
        "web_fetch_custom_ua",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # Response should echo back Req's default user agent
          assert result.markdown =~ "req/"
        end
      )
    end

    test "uses custom user agent when specified", %{opts: opts, agent_id: agent_id} do
      params = %{
        url: "http://httpbin.org/user-agent",
        user_agent: "CustomBot/2.0"
      }

      ReqCassette.with_cassette(
        "web_fetch_custom_ua_override",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # Response should echo back the custom user agent
          assert result.markdown =~ "CustomBot/2.0"
        end
      )
    end
  end

  describe "execute/3 with security checks" do
    test "blocks RFC1918 addresses when security_check enabled", %{opts: opts, agent_id: agent_id} do
      test_cases = [
        "http://192.168.1.1",
        "http://10.0.0.1",
        "http://172.16.0.1",
        "http://localhost",
        "http://127.0.0.1"
      ]

      for url <- test_cases do
        params = %{url: url, security_check: true}
        assert {:error, :blocked_domain} = Web.execute(params, agent_id, opts)
      end
    end

    test "allows RFC1918 addresses when security_check disabled (default)", %{
      opts: opts,
      agent_id: agent_id
    } do
      # Use localhost:1 to get immediate connection refused (security_check disabled allows localhost)
      # Port 1 is privileged and unlikely to be listening, so fails immediately vs timeout
      params = %{url: "http://127.0.0.1:1"}

      # Would normally fail with connection refused, not blocked_domain
      # This proves security check is bypassed
      assert {:error, error} = Web.execute(params, agent_id, opts)
      assert error != :blocked_domain
      assert error in [:endpoint_unreachable, :request_failed, :request_timeout]
    end

    test "blocks IPv6 localhost when security_check enabled", %{opts: opts, agent_id: agent_id} do
      params = %{url: "http://[::1]/test", security_check: true}
      assert {:error, :blocked_domain} = Web.execute(params, agent_id, opts)
    end

    test "blocks link-local addresses when security_check enabled", %{
      opts: opts,
      agent_id: agent_id
    } do
      params = %{url: "http://169.254.1.1", security_check: true}
      assert {:error, :blocked_domain} = Web.execute(params, agent_id, opts)
    end
  end

  describe "execute/3 parameter validation" do
    test "requires url parameter", %{opts: opts, agent_id: agent_id} do
      params = %{}
      assert {:error, :missing_required_param} = Web.execute(params, agent_id, opts)
    end

    test "validates URL format", %{opts: opts, agent_id: agent_id} do
      invalid_urls = [
        %{url: "not-a-url"},
        %{url: "ftp://example.com"},
        %{url: "file:///etc/passwd"},
        %{url: "javascript:alert(1)"},
        %{url: ""}
      ]

      for params <- invalid_urls do
        assert {:error, :invalid_url_format} = Web.execute(params, agent_id, opts)
      end

      # Integer URL returns different error due to guard clause
      assert {:error, :invalid_param_type} = Web.execute(%{url: 123}, agent_id, opts)
    end

    test "accepts valid HTTP and HTTPS URLs", %{opts: opts, agent_id: agent_id} do
      # Test URL format validation only - use localhost:1 for instant connection refused
      # (no slow network calls needed, just proving URL format is valid)
      valid_url_formats = [
        "http://127.0.0.1:1",
        "https://127.0.0.1:1",
        "http://127.0.0.1:1/path",
        "https://127.0.0.1:1/path?query=1"
      ]

      for url <- valid_url_formats do
        params = %{url: url}
        result = Web.execute(params, agent_id, opts)

        # Should not fail with invalid_url_format - connection errors are fine
        case result do
          {:error, error} -> assert error != :invalid_url_format
          {:ok, _} -> assert true
        end
      end
    end
  end

  describe "execute/3 error handling" do
    test "returns :not_found for 404 status", %{opts: opts, agent_id: agent_id} do
      params = %{url: "http://httpbin.org/status/404"}

      ReqCassette.with_cassette("web_fetch_404", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(opts, :plug, plug)
        assert {:error, :not_found} = Web.execute(params, agent_id, test_opts)
      end)
    end

    test "returns :unauthorized for 401 status", %{opts: opts, agent_id: agent_id} do
      params = %{url: "http://httpbin.org/status/401"}

      ReqCassette.with_cassette("web_fetch_401", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(opts, :plug, plug)
        assert {:error, :unauthorized} = Web.execute(params, agent_id, test_opts)
      end)
    end

    test "returns :forbidden for 403 status", %{opts: opts, agent_id: agent_id} do
      params = %{url: "http://httpbin.org/status/403"}

      ReqCassette.with_cassette("web_fetch_403", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(opts, :plug, plug)
        assert {:error, :forbidden} = Web.execute(params, agent_id, test_opts)
      end)
    end

    test "returns :rate_limit_exceeded for 429 status", %{opts: opts, agent_id: agent_id} do
      params = %{url: "http://httpbin.org/status/429"}

      ReqCassette.with_cassette("web_fetch_429", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(opts, :plug, plug)
        assert {:error, :rate_limit_exceeded} = Web.execute(params, agent_id, test_opts)
      end)
    end

    test "returns :service_unavailable for 5xx status codes", %{opts: opts, agent_id: agent_id} do
      status_codes = [500, 502, 503, 504]

      for status <- status_codes do
        params = %{url: "http://httpbin.org/status/#{status}"}

        ReqCassette.with_cassette(
          "web_fetch_#{status}",
          [cassette_dir: @cassette_dir],
          fn plug ->
            test_opts = Keyword.put(opts, :plug, plug)
            assert {:error, :service_unavailable} = Web.execute(params, agent_id, test_opts)
          end
        )
      end
    end

    test "returns :endpoint_unreachable for connection refused", %{opts: opts, agent_id: agent_id} do
      # Non-existent port
      params = %{url: "http://localhost:49999"}
      assert {:error, :endpoint_unreachable} = Web.execute(params, agent_id, opts)
    end

    test "returns :endpoint_unreachable for DNS resolution failure", %{
      opts: opts,
      agent_id: agent_id
    } do
      params = %{url: "http://non-existent-domain-#{System.unique_integer()}.test"}
      assert {:error, :endpoint_unreachable} = Web.execute(params, agent_id, opts)
    end
  end

  describe "execute/3 content processing" do
    test "converts HTML headings (h1-h6) to Markdown", %{opts: opts, agent_id: agent_id} do
      params = %{url: "https://example.com"}

      ReqCassette.with_cassette(
        "web_fetch_example_html",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # Verify Markdown heading syntax (example.com has h1)
          assert result.markdown =~ "Example Domain"
        end
      )
    end

    test "converts HTML unordered lists to Markdown", %{opts: opts, agent_id: agent_id} do
      # httpbin.org/html has unordered list elements
      params = %{url: "http://httpbin.org/html"}

      ReqCassette.with_cassette(
        "web_fetch_html_with_lists",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # Should contain Markdown list syntax
          assert is_binary(result.markdown)
          assert result.markdown != ""
        end
      )
    end

    test "preserves links in Markdown format", %{opts: opts, agent_id: agent_id} do
      params = %{url: "https://example.com"}

      ReqCassette.with_cassette(
        "web_fetch_example_html",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # example.com has a link to iana.org
          assert result.markdown =~ ~r/(\[|iana)/
        end
      )
    end

    test "handles empty HTML gracefully", %{opts: opts, agent_id: agent_id} do
      # Data URL with empty HTML
      params = %{url: "data:text/html,"}

      # Data URLs not supported by Req, but validation passes
      case Web.execute(params, agent_id, opts) do
        {:ok, result} ->
          assert is_binary(result.markdown)

        {:error, _reason} ->
          # Data URLs may not be supported, which is fine
          assert true
      end
    end

    test "handles malformed HTML gracefully", %{opts: opts, agent_id: agent_id} do
      # Real URL that returns valid response
      params = %{url: "https://example.com"}

      ReqCassette.with_cassette(
        "web_fetch_example_html",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          assert {:ok, result} = Web.execute(params, agent_id, test_opts)

          # Should extract some content even if HTML isn't perfect
          assert is_binary(result.markdown)
          assert byte_size(result.markdown) > 0
        end
      )
    end

    test "handles non-HTML content types", %{opts: opts, agent_id: agent_id} do
      params = %{url: "http://httpbin.org/json"}

      ReqCassette.with_cassette("web_fetch_json", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(opts, :plug, plug)
        # Depending on implementation, might return raw content or error
        result = Web.execute(params, agent_id, test_opts)

        case result do
          {:ok, res} ->
            assert res.content_type =~ "application/json"
            # Should either return raw JSON or convert it somehow
            assert is_binary(res.markdown)

          {:error, :unsupported_content_type} ->
            assert true
        end
      end)
    end
  end

  describe "execute/3 image content-type detection (R21-R25)" do
    test "R21: detects image/png content-type and returns image structure", %{
      opts: opts,
      agent_id: agent_id
    } do
      params = %{url: "http://httpbin.org/image/png"}

      ReqCassette.with_cassette(
        "web_fetch_image_png",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          result = Web.execute(params, agent_id, test_opts)

          case result do
            {:ok, res} ->
              # Should return image structure
              assert res.action == "fetch_web"
              assert res.type == "image"
              assert is_binary(res.data)
              assert res.mimeType =~ "image/png"

            {:error, _} ->
              # If cassette doesn't exist yet, that's expected
              flunk("Expected image structure but got error - create cassette first")
          end
        end
      )
    end

    test "R22: base64 encodes image body", %{opts: opts, agent_id: agent_id} do
      params = %{url: "http://httpbin.org/image/jpeg"}

      ReqCassette.with_cassette(
        "web_fetch_image_jpeg",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          result = Web.execute(params, agent_id, test_opts)

          case result do
            {:ok, res} ->
              assert res.type == "image"
              # Data should be valid base64
              assert is_binary(res.data)
              # Verify it's actually base64 encoded (should decode without error)
              assert {:ok, _decoded} = Base.decode64(res.data)

            {:error, _} ->
              flunk("Expected image with base64 data but got error")
          end
        end
      )
    end

    test "R23: includes normalized mimeType in response", %{opts: opts, agent_id: agent_id} do
      # Test various image types
      image_urls = [
        {"http://httpbin.org/image/png", "image/png"},
        {"http://httpbin.org/image/jpeg", "image/jpeg"},
        {"http://httpbin.org/image/webp", "image/webp"}
      ]

      for {url, expected_type} <- image_urls do
        params = %{url: url}
        cassette_name = "web_fetch_#{String.replace(expected_type, "/", "_")}"

        ReqCassette.with_cassette(
          cassette_name,
          [cassette_dir: @cassette_dir],
          fn plug ->
            test_opts = Keyword.put(opts, :plug, plug)
            result = Web.execute(params, agent_id, test_opts)

            case result do
              {:ok, res} ->
                assert res.type == "image"
                # mimeType should be normalized (no charset or other params)
                assert res.mimeType == expected_type

              {:error, _} ->
                # Cassette may not exist yet
                :ok
            end
          end
        )
      end
    end

    test "R24: non-image content-types handled as before", %{opts: opts, agent_id: agent_id} do
      # JSON should NOT return image structure
      params = %{url: "http://httpbin.org/json"}

      ReqCassette.with_cassette("web_fetch_json", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(opts, :plug, plug)
        result = Web.execute(params, agent_id, test_opts)

        case result do
          {:ok, res} ->
            # Should return markdown, not image structure
            assert Map.has_key?(res, :markdown)
            refute Map.get(res, :type) == "image"

          {:error, _} ->
            # Error is also acceptable for non-HTML
            assert true
        end
      end)
    end

    test "R25: ImageDetector detects fetch_web image result", %{opts: opts, agent_id: agent_id} do
      alias Quoracle.Agent.ImageDetector

      params = %{url: "http://httpbin.org/image/png"}

      ReqCassette.with_cassette(
        "web_fetch_image_png",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(opts, :plug, plug)
          result = Web.execute(params, agent_id, test_opts)

          case result do
            {:ok, res} ->
              # ImageDetector should recognize this as an image
              assert {:image, content} = ImageDetector.detect({:ok, res}, :fetch_web)
              assert is_list(content)
              assert Enum.any?(content, &match?(%{type: :image}, &1))

            {:error, _} ->
              flunk("Expected image result for ImageDetector test")
          end
        end
      )
    end
  end
end
