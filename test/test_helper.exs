ExUnit.start()

# Filter out expected errors during test cleanup
# 1. Postgrex disconnect: when sandbox owner exits while agent terminate/2 is mid-DB-operation
# 2. GenServer termination: when agents do consensus DB queries during shutdown
:logger.add_primary_filter(
  :test_cleanup_error_filter,
  {fn
     %{msg: {:string, msg}}, _extra ->
       msg_str = to_string(msg)

       cond do
         String.contains?(msg_str, "Postgrex.Protocol") and
             String.contains?(msg_str, "disconnected") ->
           :stop

         String.contains?(msg_str, "GenServer") and
             String.contains?(msg_str, "terminating") ->
           :stop

         true ->
           :ignore
       end

     %{msg: {:report, report}}, _extra ->
       # Filter GenServer crash reports from OTP
       case report do
         %{label: {:gen_server, :terminate}} -> :stop
         %{label: {:proc_lib, :crash}} -> :stop
         %{label: {:error_logger, _}} -> :ignore
         _ -> :ignore
       end

     _log_event, _extra ->
       :ignore
   end, %{}}
)

# Start req_llm for Google Vertex AI tests (TokenCache GenServer)
{:ok, _} = Application.ensure_all_started(:req_llm)

# Start only the essential dependencies, NOT the full application
# This avoids global singleton GenServers that cause DB ownership issues
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)

# Start only the minimal required services for tests
# 1. Repo - needed for database access
{:ok, _} =
  case Quoracle.Repo.start_link() do
    {:ok, pid} -> {:ok, pid}
    {:error, {:already_started, pid}} -> {:ok, pid}
  end

# 2. Registry - REMOVED to enable test isolation
# Each test will create its own isolated Registry instance

# 3. DynSup - REMOVED to enable test isolation
# Each test will create its own isolated DynamicSupervisor instance

# Configure the sandbox for concurrent testing
Ecto.Adapters.SQL.Sandbox.mode(Quoracle.Repo, :manual)
