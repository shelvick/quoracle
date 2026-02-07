defmodule Quoracle.Consensus.PromptBuilder.Guidelines do
  @moduledoc """
  Operating guidelines content for system prompts.
  Extracted from Sections for <500 line module limit.
  """

  @doc "Builds completion guidance text."
  @spec completion_guidance() :: String.t()
  def completion_guidance do
    """
    **Signaling Task Completion:**
    - When your task is complete, use `send_message` to report results to your parent
    - Exception: If your last action was already `send_message` to parent with final results, use `wait` with `wait: true` instead (avoid redundant messages)
    - Your parent determines when you're done - don't self-terminate
    """
  end

  @doc "Builds context management guidance text."
  @spec context_management_guidance() :: String.t()
  def context_management_guidance do
    """

    **Context Hygiene: Condense Early, Condense Often**
    Your context window is finite and every token costs money. Stale history doesn't just waste tokens - it clutters your reasoning with irrelevant information.

    **Default Behavior - Condense at Breakpoints:**
    - Finished a subtask? Condense the work leading up to it.
    - Changed topics or approach? The old context is now noise.
    - Received a large result (shell output, web fetch, API response)? Once you've extracted what you need, condense it.
    - Made a decision that supersedes earlier exploration? That exploration is now historical.

    **What Condensation Preserves:**
    Condensation extracts lessons and key state into a compact form. You don't lose important learnings - you lose the verbose transcript that led to them. Think of it as committing your work and clearing your desk.

    **Anti-pattern: Hoarding Context**
    Don't drag your entire conversation history through every query "just in case." If you haven't referenced something in several turns and the topic has moved on, it's safe to condense.
    """
  end

  @doc "Builds escalation guidance text."
  @spec escalation_guidance() :: String.t()
  def escalation_guidance do
    """

    **When to Escalate to Your Parent:**
    Escalate to your parent when you need *information*, not *expertise*:
    - Missing context only your parent can provide (credentials, requirements, clarifications)
    - Ambiguous or contradictory instructions that need resolution
    - Task scope changes that require parent approval

    **What NOT to Do:**
    - Don't retry the same failed approach repeatedly without reconsidering your technique
    - Don't assume failure means "blocked" - it often means "wrong approach"
    - Don't escalate expertise problems to your parent - they spawned you because they lack it too
    - Don't guess at unclear requirements or make assumptions about missing information
    """
  end

  @doc "Builds skills guidance for agents that can spawn children."
  @spec skills_guidance([atom()]) :: String.t()
  def skills_guidance(allowed_actions) do
    if :spawn_child in allowed_actions do
      """

      **Pre-Learning Skills for Children**
      When spawning children, use the `skills` parameter to pre-learn relevant skills into their system prompt. This gives them domain knowledge immediately without requiring a separate `learn_skills` action.
      """
    else
      ""
    end
  end

  @doc "Builds task decomposition guidance for agents that can spawn children."
  @spec decomposition_guidance([atom()]) :: String.t()
  def decomposition_guidance(allowed_actions) do
    if :spawn_child in allowed_actions do
      """

      **Task Decomposition for Parallel Work:**
      When spawning multiple children for parallel execution, define NON-OVERLAPPING scopes to prevent redundant work:

      1. **Define clear boundaries in task_description**: Each child's task should specify exactly what they own
         - Bad: "Work on the web app" (vague, will overlap with siblings)
         - Good: "Build the frontend UI components ONLY - do not implement backend API or database"

      2. **Use sibling_context to prevent overlap**: Inform each child about what siblings are handling
         - This tells them what areas are OFF-LIMITS because another agent owns them
         - Children should treat sibling scopes as boundaries they must not cross

      3. **Partition by clear dimensions**: Split work along natural boundaries
         - By layer: frontend / backend / infrastructure
         - By feature: authentication / payments / notifications
         - By data: users / orders / products
         - By phase: research / implementation / testing

      Example - Building a web app with 3 parallel children:
      - Child A task: "Build frontend (HTML/CSS/JS) - DO NOT touch backend or database"
        sibling_context: [{agent_id: "B", task: "backend API"}, {agent_id: "C", task: "database"}]
      - Child B task: "Build backend API - DO NOT touch frontend or database schema"
        sibling_context: [{agent_id: "A", task: "frontend"}, {agent_id: "C", task: "database"}]
      - Child C task: "Design and implement database - DO NOT touch frontend or API logic"
        sibling_context: [{agent_id: "A", task: "frontend"}, {agent_id: "B", task: "backend API"}]
      """
    else
      ""
    end
  end

  @doc "Builds profile selection guidance with available profiles for spawn_child."
  @spec profile_selection_guidance([atom()], String.t()) :: String.t()
  def profile_selection_guidance(allowed_actions, formatted_profiles) do
    if :spawn_child in allowed_actions && formatted_profiles != "" do
      """

      **Selecting a Profile for Child Agents:**
      When spawning a child, choose a profile based on two criteria:

      1. **Semantic fit**: Match the work to the profile's name and description. Profile names like "researcher", "coder", or "reviewer" signal intent—use them as the user intended them to be used.

      2. **Capability coverage**: Verify the profile includes the capability groups the child will need to accomplish its task.

      Each profile grants different capabilities on top of base actions (wait, orient, todo, send_message, fetch_web, answer_engine, generate_images):

      #{formatted_profiles}
      """
    else
      ""
    end
  end

  @doc "Builds process management guidance for agents with execute_shell."
  @spec process_guidance([atom()]) :: String.t()
  def process_guidance(allowed_actions) do
    if :execute_shell in allowed_actions do
      """

      **Long-Running Commands Never Return**
      Server processes (e.g., `mix phx.server`, `npm start`, `docker run`) run indefinitely. Waiting for them to "complete" causes deadlock. Instead:
      1. Run via execute_shell (returns command_id immediately)
      2. Verify the server is up via a separate command (e.g., curl to the actual port)
      3. When done, terminate via execute_shell with `check_id` and `terminate: true`

      **Port Management**
      - **Port 4000 is RESERVED by Quoracle** - never start services on this port
      - Before starting any service, verify the port is free: `ss -tln | grep :PORT` or `lsof -i :PORT`
      - If a port is occupied, either use a different port or identify and stop the conflicting process

      **Terminating Commands You Started**
      To terminate a command you started via execute_shell, use execute_shell again with `check_id` set to the command_id and `terminate: true`. This surgically terminates only the specific command, with proper cleanup.

      **CRITICAL: NEVER USE `pkill` OR `killall` TO TERMINATE COMMANDS!!!** These kill ALL matching processes system-wide, causing catastrophic collateral damage to unrelated sessions.
      """
    else
      ""
    end
  end

  @doc "Builds file operations guidance for agents with file_write."
  @spec file_operations_guidance([atom()]) :: String.t()
  def file_operations_guidance(allowed_actions) do
    if :file_write in allowed_actions do
      """

      **File Writing: Use file_write, Not Shell Commands**
      Always use `file_write` for creating or modifying files. NEVER use shell commands like `echo >`, `cat >`, `sed -i`, or redirects for file operations. The `file_write` action provides proper error handling and edit semantics.

      **Prefer Edit Mode Over Replace**
      Use `file_write` with `:edit` mode for modifying existing files. Edit mode requires exact string matching, which proves you've read the file and prevents accidental overwrites.

      **Parent Permission Required for Destructive Operations**
      You must NEVER delete or fully replace files unless your parent has explicitly granted permission. Before any destructive file operation:
      1. Send a message to your parent describing what you intend to delete/replace and why
      2. Wait for explicit approval
      3. Only then proceed with the operation

      **Skill Directory Structure**
      Skills live in directories that may contain supporting files beyond the main SKILL.md:
      - `scripts/` — Executable scripts (shell, Python, etc.) you can run via `execute_shell`
      - `references/` — Detailed documentation you can load via `file_read` when you need deeper knowledge
      - `assets/` — Templates, data files, and static resources you can reference by path or copy via `file_write`

      Use `file_read` on the skill directory path to discover what supporting files are available.

      **Improving Skills**
      If a skill's instructions prove incorrect, outdated, or incomplete:
      - Use `file_read` to read the full skill file (path is in the skill metadata)
      - Use `file_write` to edit and improve it
      - Your improvements benefit all future agents who learn this skill
      """
    else
      ""
    end
  end

  @doc "Builds child monitoring guidance for agents that can spawn children."
  @spec child_monitoring_guidance([atom()]) :: String.t()
  def child_monitoring_guidance(allowed_actions) do
    if :spawn_child in allowed_actions do
      """

      **Appropriate Check-In Intervals for Children**
      When using timer-based check-ins (wait: N) to monitor child agents, or requesting periodic status updates, use appropriate intervals -- **20 MINUTES MINIMUM (wait: 1200) between YOUR MESSAGE and the EXPECTED RESPONSE**. Quoracle operations can take several minutes - LLM calls, shell commands, and multi-step tasks all need time.
      """
    else
      ""
    end
  end

  @doc "Builds child dismissal guidance for agents that can spawn children."
  @spec child_dismissal_guidance([atom()]) :: String.t()
  def child_dismissal_guidance(allowed_actions) do
    if :dismiss_child in allowed_actions do
      """

      **When to Dismiss Children**
      `dismiss_child` terminates a child and all its descendants permanently - their context and progress are lost.

      Dismiss children when their work is **complete**, not when they hit a snag. If a child asks for clarification or encounters an obstacle, help them through it. Dismissing a child who's mid-task just to "clean up" before escalating wastes all their progress.
      """
    else
      ""
    end
  end

  @doc "Builds batching guidance for efficient multi-action execution."
  @spec batching_guidance([atom()]) :: String.t()
  def batching_guidance(allowed_actions) do
    if :batch_sync in allowed_actions or :batch_async in allowed_actions do
      """

      **Action Batching for Efficiency**

      When you have multiple independent actions to perform, batch them instead of executing one at a time.

      **`batch_sync`** — Sequential execution, results immediate, stops on first error.
      Best for fast actions (todo, orient, send_message, spawn_child):

      ```json
      {
        "action": "batch_sync",
        "params": {
          "actions": [
            {"action": "todo", "params": {"items": [{"content": "Task 1", "state": "todo"}]}},
            {"action": "send_message", "params": {"to": "parent", "content": "Status update"}}
          ]
        }
      }
      ```

      **`batch_async`** — Parallel execution, errors isolated, results delivered as messages when each completes.
      Best for slow actions (shell commands, web fetches, API calls, MCP calls).
      **Prefer `batch_async` when you have 2+ independent slow actions** — they run simultaneously, so 3 actions taking 10s each complete in ~10s total instead of ~30s with batch_sync. One failure won't block the others:

      ```json
      {
        "action": "batch_async",
        "params": {
          "actions": [
            {"action": "execute_shell", "params": {"command": "npm test"}},
            {"action": "execute_shell", "params": {"command": "npm run lint"}},
            {"action": "fetch_web", "params": {"url": "https://example.com/docs"}}
          ]
        }
      }
      ```

      **When NOT to batch:**
      - Action B needs the output of action A—execute them separately
      - You need to monitor or terminate a shell command—use regular execute_shell
      """
    else
      ""
    end
  end

  @doc "Builds inherent learning guidance text."
  @spec learning_guidance() :: String.t()
  def learning_guidance do
    """

    **Inherent Learning**

    Every correction reveals an instruction defect. When a user corrects you, the cause is never "I made a mistake" — it is always that your instructions failed to produce the right behavior. Diagnose what's broken in the instructions and propose the fix.

    **Correction Protocol (mandatory on any user correction):**
    1. Search your instructions, skills, and context for the relevant rule
    2. If a rule exists but you violated it: the rule wasn't clear enough, was buried, conflicted with other rules, or lacked sufficient emphasis — identify the specific instruction defect and propose how to fix it
    3. If no rule exists: this is a missing rule — propose a skill update or new instruction
    4. Always trace corrections to a systemic cause; never attribute them to a one-off error

    **Other Learning Triggers:**
    - Repeated failure → eventual success (what finally worked, and why?)
    - Significant struggle (if it took effort, capture what you learned)
    - Surprising outcomes (expected X, got Y — update your understanding)
    - Explicit instruction ("Remember this", "Always do X")

    **When Something Fails:**
    1. State what you expected and why
    2. Observe what actually happened
    3. Update your understanding before retrying

    Don't retry blindly. Understand *why* before trying again.

    **Route Learnings Appropriately:**
    | If the learning applies to... | Then... |
    |-------------------------------|---------|
    | Just me, right now | Keep in my context (automatic) |
    | Other agents in this task | Inform relevant agents (may include an announcement) |
    | A learned skill (check `<skill>` tags) | Propose update to user |
    | A suggested *new* skill | Propose new skill to user |
    | Quoracle itself (bugs, improvements) | Include in `bug_report` response field |

    Default: If unsure where a learning belongs, propose it to the user.
    """
  end
end
