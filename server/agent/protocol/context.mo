class TeamContext {
    fn TeamContext(name, description, rule, agents, max_steps = 100) {
        """
        Initialize the TeamContext with a name, description, rules, a list of agents, and a user question.
        :param name: The name of the group context.
        :param description: A description of the group context.
        :param rule: The rules governing the group context.
        :param agents: A list of agents in the context.
        """
        this.name = name
        this.description = description
        this.rule = rule
        this.agents = agents
        this.user_task = ""  # For backward compatibility
        this.task = null  # Will be a Task instance
        this.model = null  # Will be an instance of LLMModel
        this.task_short_name = null  # Store the task directory name
        # List of agents that have been executed
        this.agent_outputs: list = []
        this.current_steps = 0
        this.max_steps = max_steps


    }
}
class AgentOutput {
    fn AgentOutput(agent_name, output) {
        this.agent_name = agent_name
        this.output = output
    }
}