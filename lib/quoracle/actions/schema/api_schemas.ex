defmodule Quoracle.Actions.Schema.ApiSchemas do
  @moduledoc """
  Schema definitions for API and integration actions.

  Includes: answer_engine, execute_shell, fetch_web, call_api,
  call_mcp, generate_secret, search_secrets, file_read, file_write.
  """

  @schemas %{
    answer_engine: %{
      required_params: [:prompt],
      optional_params: [],
      param_types: %{
        prompt: :string
      },
      param_descriptions: %{
        prompt:
          "Question to answer using web-grounded search - gets current information from the internet"
      },
      consensus_rules: %{
        prompt: {:semantic_similarity, threshold: 0.95}
      }
    },
    execute_shell: %{
      required_params: [],
      optional_params: [:command, :check_id, :working_dir, :terminate],
      xor_params: [[:command], [:check_id]],
      param_types: %{
        command: :string,
        check_id: :string,
        working_dir: :string,
        terminate: :boolean
      },
      param_descriptions: %{
        command:
          "Shell command to execute (use this to START a new command) - for commands <100ms you get immediate results, longer commands run async",
        check_id:
          "ID of running command to check status (use this to CHECK on async command) - mutually exclusive with 'command'",
        working_dir: "Absolute path to directory to execute command in (defaults to /tmp)",
        terminate: "Set to true with check_id to stop a running command (kills the process)"
      },
      consensus_rules: %{
        command: :exact_match,
        check_id: :exact_match,
        working_dir: :exact_match,
        terminate: :exact_match
      }
    },
    fetch_web: %{
      required_params: [:url],
      optional_params: [
        :security_check,
        :timeout,
        :user_agent,
        :follow_redirects
      ],
      param_types: %{
        url: :string,
        security_check: :boolean,
        timeout: :number,
        user_agent: :string,
        follow_redirects: :boolean
      },
      param_descriptions: %{
        url: "Web page URL to fetch (http or https) - content will be converted to markdown",
        security_check:
          "Enable SSRF protection to block private IPs and localhost (default: false)",
        timeout: "HTTP request timeout in seconds (default: 30)",
        user_agent: "Custom User-Agent header for the request (default: HTTP client default)",
        follow_redirects: "Whether to follow HTTP redirects (default: true)"
      },
      consensus_rules: %{
        url: :exact_match,
        security_check: :mode_selection,
        timeout: {:percentile, 50},
        user_agent: :exact_match,
        follow_redirects: :mode_selection
      }
    },
    call_api: %{
      required_params: [:api_type, :url],
      optional_params: [
        :method,
        :query_params,
        :body,
        :headers,
        :auth,
        :query,
        :variables,
        :rpc_method,
        :rpc_params,
        :rpc_id,
        :timeout,
        :max_body_size
      ],
      param_types: %{
        api_type: {:enum, [:rest, :graphql, :jsonrpc]},
        url: :string,
        timeout: :integer,
        headers: :map,
        auth: :map,
        max_body_size: :integer,
        method: :string,
        query_params: :map,
        body: :any,
        query: :string,
        variables: :map,
        rpc_method: :string,
        rpc_params: :any,
        rpc_id: :string
      },
      param_descriptions: %{
        api_type: "Protocol type: :rest, :graphql, or :jsonrpc",
        url: "Target API endpoint URL (required for all types)",
        timeout: "Request timeout in seconds (default: 30)",
        headers: "Custom HTTP headers (optional)",
        auth: "Authentication configuration (auth_type, token, credentials)",
        method: "HTTP method for REST: GET, POST, PUT, DELETE, PATCH",
        query_params: "URL query parameters for REST (optional)",
        body: "Request body for REST POST/PUT/PATCH (optional)",
        query: "GraphQL query or mutation string (required for GraphQL)",
        variables: "GraphQL query variables (optional)",
        rpc_method: "JSON-RPC method name (required for JSON-RPC)",
        rpc_params: "JSON-RPC parameters as map or array (optional)",
        rpc_id: "JSON-RPC request ID (optional, auto-generated if missing)",
        max_body_size: "Maximum request body size in bytes (default: 5MB)"
      },
      consensus_rules: %{
        api_type: :exact_match,
        url: :exact_match,
        method: :exact_match,
        timeout: {:percentile, 100},
        auth: :exact_match,
        query_params: :exact_match,
        body: :exact_match,
        headers: :exact_match,
        query: :exact_match,
        variables: :exact_match,
        rpc_method: :exact_match,
        rpc_params: :exact_match,
        rpc_id: :exact_match,
        max_body_size: {:percentile, 100}
      }
    },
    call_mcp: %{
      required_params: [],
      optional_params: [
        :transport,
        :command,
        :url,
        :cwd,
        :connection_id,
        :tool,
        :arguments,
        :terminate,
        :timeout
      ],
      xor_params: [[:transport], [:connection_id]],
      param_types: %{
        transport: {:enum, [:stdio, :http]},
        command: :string,
        url: :string,
        cwd: :string,
        connection_id: :string,
        tool: :string,
        arguments: :map,
        terminate: :boolean,
        timeout: :number
      },
      param_descriptions: %{
        transport: "Transport type: 'stdio' for subprocess servers, 'http' for remote servers",
        command:
          "Shell command to spawn MCP server (required for stdio transport, e.g., 'npx @modelcontextprotocol/server-filesystem /tmp')",
        url: "URL of MCP server (required for http transport)",
        cwd: "Working directory for stdio command (defaults to application root)",
        connection_id: "ID of existing connection (returned by CONNECT)",
        tool: "Name of tool to call (from the tools list returned by CONNECT)",
        arguments: "Arguments to pass to the tool (optional map)",
        terminate: "Set to true to close the connection and free resources",
        timeout: "Timeout in milliseconds (default: 30000)"
      },
      consensus_rules: %{
        transport: :exact_match,
        command: :exact_match,
        url: :exact_match,
        cwd: :exact_match,
        connection_id: :exact_match,
        tool: :exact_match,
        arguments: :exact_match,
        terminate: :exact_match,
        timeout: {:percentile, 50}
      }
    },
    generate_secret: %{
      required_params: [:name],
      optional_params: [
        :length,
        :include_symbols,
        :include_numbers,
        :description
      ],
      param_types: %{
        name: :string,
        length: :integer,
        include_symbols: :boolean,
        include_numbers: :boolean,
        description: :string
      },
      param_descriptions: %{
        name:
          "Unique identifier for this secret (alphanumeric and underscores only) - use {{SECRET:name}} to reference it later",
        length: "Length of generated secret in characters (default: 32, min: 8, max: 128)",
        include_symbols:
          "Include special characters like !@#$%^&*-_=+ in the secret (default: false)",
        include_numbers: "Include digits 0-9 in the secret (default: true)",
        description: "Human-readable note about what this secret is for (not shown to LLMs)"
      },
      consensus_rules: %{
        name: :exact_match,
        length: {:percentile, 50},
        include_symbols: :mode_selection,
        include_numbers: :mode_selection,
        description: {:semantic_similarity, threshold: 0.8}
      }
    },
    search_secrets: %{
      required_params: [:search_terms],
      optional_params: [],
      param_types: %{
        search_terms: {:list, :string}
      },
      param_descriptions: %{
        search_terms:
          "List of search strings - returns secret names containing ANY term (case-insensitive substring match)"
      },
      consensus_rules: %{
        search_terms: :union_merge
      }
    },
    generate_images: %{
      required_params: [:prompt],
      optional_params: [:source_image],
      param_types: %{
        prompt: :string,
        source_image: :string
      },
      param_descriptions: %{
        prompt:
          "Text prompt describing the image to generate - be specific and detailed for best results",
        source_image:
          "Base64-encoded source image for editing mode - when provided, the prompt describes changes to make"
      },
      consensus_rules: %{
        prompt: {:semantic_similarity, threshold: 0.95},
        source_image: :first_non_nil
      }
    },
    record_cost: %{
      required_params: [:amount],
      optional_params: [:description, :category, :metadata],
      param_types: %{
        amount: :string,
        description: :string,
        category: :string,
        metadata: :map
      },
      param_descriptions: %{
        amount: "Cost amount in USD as decimal string (e.g., '0.05', '1.50')",
        description: "Human-readable description of what was charged",
        category: "Optional category for grouping (e.g., 'api_call', 'cloud_compute', 'storage')",
        metadata:
          "Optional map of additional context (e.g., {\"service\": \"aws\", \"region\": \"us-east-1\"})"
      },
      consensus_rules: %{
        amount: :exact_match,
        description: :first_non_nil,
        category: :first_non_nil,
        metadata: :merge_maps
      }
    },
    file_read: %{
      required_params: [:path],
      optional_params: [:offset, :limit],
      param_types: %{
        path: :string,
        offset: :integer,
        limit: :integer
      },
      param_descriptions: %{
        path: "Absolute path to file to read",
        offset: "Line number to start reading from (1-indexed, default: 1)",
        limit: "Maximum number of lines to read (default: all)"
      },
      consensus_rules: %{
        path: :exact_match,
        offset: {:percentile, 50},
        limit: {:percentile, 50}
      }
    },
    file_write: %{
      required_params: [:path, :mode],
      optional_params: [:content, :old_string, :new_string, :replace_all],
      xor_params: [[:content], [:old_string, :new_string]],
      param_types: %{
        path: :string,
        mode: {:enum, [:write, :edit]},
        content: :string,
        old_string: :string,
        new_string: :string,
        replace_all: :boolean
      },
      param_descriptions: %{
        path: "Absolute path to file to write or edit",
        mode: "Operation mode: :write (overwrite entire file) or :edit (find and replace)",
        content:
          "Complete file content for :write mode - mutually exclusive with old_string/new_string",
        old_string: "Text to find for :edit mode - mutually exclusive with content",
        new_string: "Replacement text for :edit mode - mutually exclusive with content",
        replace_all: "Replace all occurrences in :edit mode (default: false, replaces first only)"
      },
      consensus_rules: %{
        path: :exact_match,
        mode: :exact_match,
        content: {:semantic_similarity, threshold: 0.95},
        old_string: :exact_match,
        new_string: :exact_match,
        replace_all: :mode_selection
      }
    },
    learn_skills: %{
      required_params: [:skills],
      optional_params: [:permanent],
      param_types: %{
        skills: {:list, :string},
        permanent: :boolean
      },
      param_descriptions: %{
        skills: "List of skill names to load (e.g., [\"deployment\", \"security-audit\"])",
        permanent:
          "If true, skill content injected into system prompt for all future requests. If false (default), content returned as temporary context."
      },
      consensus_rules: %{
        skills: :union_merge,
        permanent: :mode_selection
      }
    },
    create_skill: %{
      required_params: [:name, :description, :content],
      optional_params: [:metadata, :attachments],
      param_types: %{
        name: :string,
        description: :string,
        content: :string,
        metadata: :map,
        attachments: {:list, :map}
      },
      param_descriptions: %{
        name:
          "Skill name (lowercase alphanumeric with hyphens, max 64 chars, e.g., 'my-new-skill')",
        description: "Brief description of what the skill does (max 1024 chars)",
        content: "Markdown content for the skill body",
        metadata:
          "Optional metadata (complexity: low/medium/high, capability_groups_required, etc.)",
        attachments:
          "Optional file attachments [{type: 'script'|'reference'|'asset', filename: '...', content: '...'}]"
      },
      consensus_rules: %{
        name: :exact_match,
        description: {:semantic_similarity, threshold: 0.90},
        content: {:semantic_similarity, threshold: 0.95},
        metadata: :merge_maps,
        attachments: :union_merge
      }
    },
    batch_sync: %{
      required_params: [:actions],
      optional_params: [],
      param_types: %{
        actions: {:list, :action_spec}
      },
      param_descriptions: %{
        actions:
          "List of action specifications to execute synchronously. Minimum 2 actions required. Each action has {action, params} structure. Only batchable actions allowed (no :wait, :batch_sync, or slow async actions)."
      },
      consensus_rules: %{
        actions: :batch_sequence_merge
      }
    },
    batch_async: %{
      required_params: [:actions],
      optional_params: [],
      param_types: %{
        actions: {:list, :action_spec}
      },
      param_descriptions: %{
        actions:
          "List of actions to execute in parallel. Minimum 2 actions required. Each action is {action, params}. All actions except :wait, :batch_sync, :batch_async are allowed."
      },
      consensus_rules: %{
        actions: :batch_sequence_merge
      }
    }
  }

  @spec schemas() :: map()
  def schemas, do: @schemas
end
