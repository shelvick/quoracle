defmodule QuoracleWeb.UI.TaskTree.NewTaskModal do
  @moduledoc """
  Phoenix Component for the new task creation modal.
  Extracted from TaskTree to keep module size under 500 lines.
  """

  use Phoenix.Component

  @doc """
  Renders the new task modal form.

  ## Assigns
    * `:show_modal` - Whether the modal is visible
    * `:target` - The phx-target for form events
    * `:profiles` - List of profiles for selection
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id="new-task-modal" class={if @show_modal, do: "fixed inset-0 z-50", else: "hidden"}>
      <%!-- Backdrop --%>
      <div
        class="fixed inset-0 bg-gray-500/75"
        phx-click="hide_modal"
        phx-target={@target}
        aria-hidden="true"
      >
      </div>

      <div class="fixed inset-0 overflow-y-auto p-4">
        <div class="flex min-h-full items-center justify-center">
          <div class="bg-white rounded-lg shadow-xl max-w-2xl w-full p-6">
            <h3 class="text-lg font-semibold mb-4">Create New Task</h3>

            <form id="new-task-form" phx-update="ignore" phx-submit="create_task" phx-target={@target}>
                <div class="mb-6">
                  <h4 class="text-md font-medium mb-3">Profile</h4>

                  <QuoracleWeb.UI.TaskFormFields.profile_selector
                    profiles={@profiles}
                    selected_profile=""
                    help_text="Determines which models and capability groups (file access, web, shell) the root agent can use."
                  />
                </div>

                <div class="mb-6">
                  <h4 class="text-md font-medium mb-3 text-indigo-700">Agent Identity (System Prompt)</h4>

                  <QuoracleWeb.UI.TaskFormFields.text_field
                    name="role"
                    label="Role"
                    value=""
                    placeholder="Agent identity..."
                    help_text="A persona or identity for the root agent. Injected into the system prompt to shape its behavior."
                  />

                  <QuoracleWeb.UI.TaskFormFields.list_input
                    name="skills"
                    label="Skills"
                    value={[]}
                    placeholder="deployment, code-review, testing"
                    help_text="Optional. Pre-load skills for the root agent."
                  />

                  <QuoracleWeb.UI.TaskFormFields.enum_dropdown
                    name="cognitive_style"
                    label="Cognitive Style"
                    value=""
                    options={QuoracleWeb.UI.TaskFormFields.cognitive_style_options()}
                    prompt="Select thinking mode..."
                    help_text="Controls how the root agent reasons. Affects the thinking style instructions in the system prompt."
                  />

                  <QuoracleWeb.UI.TaskFormFields.list_input
                    name="global_constraints"
                    label="Global Constraints"
                    value={[]}
                    placeholder="Use Elixir, Follow TDD..."
                    help_text="Hard rules ALL agents in this task must always follow. Added to the system prompt as non-negotiable constraints."
                  />

                  <QuoracleWeb.UI.TaskFormFields.enum_dropdown
                    name="output_style"
                    label="Output Style"
                    value=""
                    options={QuoracleWeb.UI.TaskFormFields.output_style_options()}
                    prompt="Select output format..."
                    help_text="Preferred format for the root agent's responses. Guides verbosity and structure in the system prompt."
                  />

                  <QuoracleWeb.UI.TaskFormFields.enum_dropdown
                    name="delegation_strategy"
                    label="Delegation Strategy"
                    value=""
                    options={QuoracleWeb.UI.TaskFormFields.delegation_strategy_options()}
                    prompt="Select delegation approach..."
                    help_text="How the root agent spawns child agents. Sequential runs one at a time, parallel runs concurrently."
                  />

                  <QuoracleWeb.UI.TaskFormFields.textarea_field
                    name="global_context"
                    label="Global Context"
                    value=""
                    rows={3}
                    placeholder="Project-wide context..."
                    help_text="Background information included in ALL agents' system prompts. Use for project details, conventions, or domain knowledge."
                  />
                </div>

                <div class="mb-6">
                  <h4 class="text-md font-medium mb-3 text-emerald-700">Task Work (User Prompt)</h4>

                  <QuoracleWeb.UI.TaskFormFields.textarea_field
                    name="task_description"
                    label="Task Description"
                    value=""
                    required={true}
                    rows={3}
                    placeholder="Describe the task..."
                    help_text="The main work instruction sent as the user message. This is what the root agent will actually try to accomplish."
                  />

                  <QuoracleWeb.UI.TaskFormFields.textarea_field
                    name="success_criteria"
                    label="Success Criteria"
                    value=""
                    rows={2}
                    placeholder="How to verify completion..."
                    help_text="How the root agent knows it's done. Appended to the user message so the agent can self-evaluate."
                  />

                  <QuoracleWeb.UI.TaskFormFields.textarea_field
                    name="immediate_context"
                    label="Immediate Context"
                    value=""
                    rows={2}
                    placeholder="Current situation..."
                    help_text="Situational details specific to this task. Appended to the user message alongside the task description. Child agents will receive a condensed version of this."
                  />

                  <QuoracleWeb.UI.TaskFormFields.textarea_field
                    name="approach_guidance"
                    label="Approach Guidance"
                    value=""
                    rows={2}
                    placeholder="How to approach the task..."
                    help_text="Strategy hints for tackling the task. Appended to the user message to steer the root agent's approach."
                  />
                </div>

                <div class="mb-6">
                  <h4 class="text-md font-medium mb-3 text-amber-700">Budget</h4>

                  <QuoracleWeb.UI.TaskFormFields.budget_input
                    name="budget_limit"
                    label="Budget Limit"
                    value=""
                    placeholder="Leave empty for unlimited"
                    help_text="Maximum dollar amount the task can spend on LLM calls. Leave empty for unlimited."
                  />
                </div>

                <%!-- Buttons inside form --%>
                <div class="flex gap-3 justify-end">
                  <button
                    type="button"
                    class="px-4 py-2 bg-gray-200 hover:bg-gray-300 text-gray-800 rounded"
                    phx-click="hide_modal"
                    phx-target={@target}
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded"
                  >
                    Create Task
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      </div>
    """
  end
end
