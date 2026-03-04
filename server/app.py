from microsoft_agents.activity import load_configuration_from_env
from microsoft_agents.authentication.msal import MsalConnectionManager
from microsoft_agents.hosting.core import (
   AgentApplication,
   Authorization,
   TurnState,
   TurnContext,
   MemoryStorage,
)
from microsoft_agents.hosting.aiohttp import CloudAdapter
from os import environ
from .server import start_server

agents_sdk_config = load_configuration_from_env(environ)
print(f"Loaded configuration: {agents_sdk_config}")
# Create storage and connection manager
STORAGE = MemoryStorage()
CONNECTION_MANAGER = MsalConnectionManager(**agents_sdk_config)
ADAPTER = CloudAdapter(connection_manager=CONNECTION_MANAGER)
AUTHORIZATION = Authorization(STORAGE, CONNECTION_MANAGER, **agents_sdk_config)

AGENT_APP = AgentApplication[TurnState](
    storage=STORAGE,
    adapter=ADAPTER,
    authorization=AUTHORIZATION
)

async def _help(context: TurnContext, _: TurnState):
    await context.send_activity(
        "Welcome to the Echo Agent sample 🚀. "
        "Type /help for help or send a message to see the echo feature in action."
    )

AGENT_APP.conversation_update("membersAdded")(_help)

AGENT_APP.message("/help")(_help)


@AGENT_APP.activity("message")
async def on_message(context: TurnContext, _):
    print(f"Received message: {context.activity.text}")
    await context.send_activity(f"you said: {context.activity.text}")

if __name__ == "__main__":
    try:
        start_server(AGENT_APP, {})
    except Exception as error:
        raise error