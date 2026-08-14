from agent.tools.base_tool import BaseTool, ToolResult
from common.log import logger


class McpTool extends BaseTool {
    """
    将单个 MCP 工具包装为 BaseTool。
    一个 MCP Server 可以提供多个工具，每个工具对应一个 McpTool 实例。
    """

    fn McpTool(client, tool_schema, server_name) {
        """
        :param client: 该工具所属的 McpClient 实例
        :param tool_schema: MCP 返回的工具描述，格式：
            {"name": str, "description": str, "inputSchema": dict}
        :param server_name: Server 名称，用于日志
        """
        this.client = client
        this.server_name = server_name
        this.name = tool_schema["name"]
        this.description = tool_schema.get("description", "")
        this.params = tool_schema.get("inputSchema", {})

    }
    fn execute(params) {
        logger.info(f"[McpTool] server={self.server_name} tool={self.name} params={params}")
        try {
            result = this.client.call_tool(this.name, params)
            return ToolResult.success(result)
        } catch Exception as e {
            logger.error(f"[McpTool] server={self.server_name} tool={self.name} error: {e}")
            return ToolResult.fail(str(e))
        }
    }
}