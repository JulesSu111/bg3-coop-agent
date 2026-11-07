"""Load the MCP/tool stack only when an in-game request actually needs it."""
from .game import Game


class ToolRuntime:
    def __init__(self):
        self.game = Game()
        self._module = None

    def __getattr__(self, name):
        if self._module is None:
            from . import server
            # All tool helpers must use the debugger owner, including trading and notes.
            server.game = self.game
            server.chat.game = self.game
            server.memo._call = self.game.call
            server.trader.game = self.game
            self._module = server
        return getattr(self._module, name)
