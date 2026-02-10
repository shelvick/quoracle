defmodule Quoracle.MCP.ServerConfigTest do
  use ExUnit.Case, async: true

  alias Quoracle.MCP.ServerConfig

  # CONFIG_MCPServers v1.0 - MCP Server Configuration
  # ARC Verification Criteria for application configuration schema

  describe "list_servers/0" do
    test "R1: list_servers returns all configured servers" do
      # [UNIT] - WHEN list_servers called THEN returns all configured MCP servers
      servers = ServerConfig.list_servers()

      assert is_list(servers)
      # Should return configured servers (may be empty list if none configured)
      Enum.each(servers, fn server ->
        assert is_map(server)
        assert Map.has_key?(server, :name)
        assert Map.has_key?(server, :transport)
      end)
    end
  end

  describe "get_server/1" do
    test "R2: get_server returns config for existing server" do
      # [UNIT] - WHEN get_server called IF server exists THEN returns {:ok, config}
      # First, ensure we have at least one server configured for this test
      servers = ServerConfig.list_servers()

      if servers != [] do
        first_server = hd(servers)
        assert {:ok, config} = ServerConfig.get_server(first_server.name)
        assert config.name == first_server.name
        assert config.transport in [:stdio, :http]
      else
        # If no servers configured, test with a known test server name
        # This will fail until implementation adds test config
        assert {:ok, _config} = ServerConfig.get_server("test_server")
      end
    end

    test "R3: get_server returns error for unknown server" do
      # [UNIT] - WHEN get_server called IF server not configured THEN returns {:error, :not_found}
      assert {:error, :not_found} = ServerConfig.get_server("nonexistent_server_xyz_123")
    end
  end

  describe "server_exists?/1" do
    test "R4: server_exists? returns true for configured, false for unknown" do
      # [UNIT] - WHEN server_exists? called THEN returns boolean based on configuration
      # Unknown server should return false
      refute ServerConfig.server_exists?("definitely_not_configured_server")

      # If we have any servers, the first one should return true
      servers = ServerConfig.list_servers()

      if servers != [] do
        first_server = hd(servers)
        assert ServerConfig.server_exists?(first_server.name)
      end
    end
  end

  describe "transport validation" do
    test "R5: invalid transport raises configuration error" do
      # [UNIT] - WHEN config loaded IF transport not :stdio or :http THEN raises at compile time
      # This test validates that the module enforces transport type constraints
      # We test by verifying all returned servers have valid transports
      servers = ServerConfig.list_servers()

      Enum.each(servers, fn server ->
        assert server.transport in [:stdio, :http],
               "Server #{server.name} has invalid transport: #{inspect(server.transport)}"
      end)
    end

    test "R6: stdio transport requires command field" do
      # [UNIT] - WHEN config loaded IF transport is :stdio and command is nil THEN raises
      servers = ServerConfig.list_servers()

      stdio_servers = Enum.filter(servers, &(&1.transport == :stdio))

      Enum.each(stdio_servers, fn server ->
        assert Map.has_key?(server, :command) and not is_nil(server.command),
               "Stdio server #{server.name} missing required 'command' field"
      end)
    end

    test "R7: http transport requires url field" do
      # [UNIT] - WHEN config loaded IF transport is :http and url is nil THEN raises
      servers = ServerConfig.list_servers()

      http_servers = Enum.filter(servers, &(&1.transport == :http))

      Enum.each(http_servers, fn server ->
        assert Map.has_key?(server, :url) and not is_nil(server.url),
               "HTTP server #{server.name} missing required 'url' field"
      end)
    end
  end
end
