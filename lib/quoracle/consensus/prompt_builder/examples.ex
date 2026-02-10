defmodule Quoracle.Consensus.PromptBuilder.Examples do
  @moduledoc """
  Action example templates for LLM prompts.
  Extracted from Sections module to maintain 500-line limit.
  """

  @doc "Builds example action invocations showing proper wait parameter usage."
  @spec build_action_examples([atom()] | nil) :: String.t()
  def build_action_examples(allowed_actions \\ nil) do
    examples = [
      send_message_block_example(),
      send_message_continue_example(),
      spawn_child_example(),
      wait_example(),
      call_api_rest_example(),
      call_api_graphql_example(),
      call_api_jsonrpc_example(),
      call_mcp_connect_example(),
      call_mcp_call_example(),
      call_mcp_terminate_example()
    ]

    # Filter examples based on allowed_actions if provided
    filtered =
      if allowed_actions do
        Enum.filter(examples, fn {action, _text} -> action in allowed_actions end)
      else
        examples
      end

    example_texts = Enum.map(filtered, fn {_action, text} -> text end)

    """
    Example action invocations (note: reasoning comes FIRST):

    #{Enum.join(example_texts, "\n")}
    """
  end

  defp send_message_block_example do
    {:send_message,
     """
         // Send message and block until reply (common pattern)
         {
           "reasoning": "I need data analysis from my child agent. After delegating, I have nothing else to do until they respond, so I should block.",
           "action": "send_message",
           "params": {
             "to": "children",
             "content": "Please analyze this data"
           },
           "wait": true
         }
     """}
  end

  defp send_message_continue_example do
    {:send_message,
     """
         // Continue working immediately
         {
           "reasoning": "Parent requested status updates. I'm at 50% and have more work to do, so I'll send an update and continue immediately.",
           "action": "send_message",
           "params": {
             "to": "parent",
             "content": "Status: 50% complete"
           },
           "wait": false
         }
     """}
  end

  defp spawn_child_example do
    {:spawn_child,
     """
         // Timer-based check-in
         {
           "reasoning": "This analysis could take a while. I'll spawn a child for it and check back in 10 minutes if I haven't heard anything.",
           "action": "spawn_child",
           "params": {
             "task_description": "Run long analysis"
           },
           "wait": 600
         }
     """}
  end

  defp wait_example do
    {:wait,
     """
         // Simple delay (no wait parameter on :wait action)
         {
           "reasoning": "The API returned a rate limit error. I should wait 5 seconds before retrying.",
           "action": "wait",
           "params": {
             "wait": 5
           }
         }
     """}
  end

  defp call_api_rest_example do
    {:call_api,
     """
         // REST API call with bearer token authentication
         {
           "reasoning": "I need to list the user's GitHub repositories to understand their project structure. This requires authentication.",
           "action": "call_api",
           "params": {
             "api_type": "rest",
             "method": "GET",
             "url": "https://api.github.com/user/repos",
             "auth": {
               "auth_type": "bearer",
               "token": "{{SECRET:github_token}}"
             }
           },
           "wait": true
         }
     """}
  end

  defp call_api_graphql_example do
    {:call_api,
     """
         // GraphQL query with basic authentication
         {
           "reasoning": "I need the user's name and email from the external service. GraphQL lets me request exactly these fields.",
           "action": "call_api",
           "params": {
             "api_type": "graphql",
             "url": "https://api.example.com/graphql",
             "query": "query { user(id: 1) { name email } }",
             "auth": {
               "auth_type": "basic",
               "username": "{{SECRET:api_username}}",
               "password": "{{SECRET:api_password}}"
             }
           },
           "wait": true
         }
     """}
  end

  defp call_api_jsonrpc_example do
    {:call_api,
     """
         // JSON-RPC method call with OAuth2
         {
           "reasoning": "I need to check the account balance before proceeding with the transaction. The RPC endpoint requires OAuth2.",
           "action": "call_api",
           "params": {
             "api_type": "jsonrpc",
             "url": "https://rpc.example.com",
             "method": "getBalance",
             "params": {"account": "0x123"},
             "auth": {
               "auth_type": "oauth2",
               "client_id": "{{SECRET:oauth_client_id}}",
               "client_secret": "{{SECRET:oauth_client_secret}}"
             }
           },
           "wait": true
         }
     """}
  end

  defp call_mcp_connect_example do
    {:call_mcp,
     """
         // MCP: Connect to a server via stdio transport
         {
           "reasoning": "I need to read and manipulate files in /tmp. The filesystem MCP server provides the tools I need.",
           "action": "call_mcp",
           "params": {
             "transport": "stdio",
             "command": "npx @modelcontextprotocol/server-filesystem /tmp"
           },
           "wait": true
         }
     """}
  end

  defp call_mcp_call_example do
    {:call_mcp,
     """
         // MCP: Call a tool on an existing connection
         {
           "reasoning": "I have an active MCP connection and need to read the contents of data.txt to analyze it.",
           "action": "call_mcp",
           "params": {
             "connection_id": "mcp_abc123",
             "tool": "read_file",
             "arguments": {"path": "/tmp/data.txt"}
           },
           "wait": true
         }
     """}
  end

  defp call_mcp_terminate_example do
    {:call_mcp,
     """
         // MCP: Terminate a connection when done
         {
           "reasoning": "I've finished all file operations. I should close the MCP connection to free up resources.",
           "action": "call_mcp",
           "params": {
             "connection_id": "mcp_abc123",
             "terminate": true
           },
           "wait": false
         }
     """}
  end
end
