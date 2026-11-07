"""Durable ordered tasks. Interrupted work requires reconciliation before replay."""
import json
import sqlite3


class TaskQueue:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY, key TEXT UNIQUE, payload TEXT, state TEXT DEFAULT 'pending', error TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)")
        self.db.execute("UPDATE tasks SET state='interrupted', error='进程退出，执行结果未知，请继续后先检查游戏状态' WHERE state='running'")
        self.db.commit()

    def get(self, key, default=None):
        row = self.db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set(self, key, value):
        if self.get(key) == value:
            return
        self.db.execute("INSERT OR REPLACE INTO settings VALUES (?,?)", (key, json.dumps(value)))
        self.db.commit()

    def put(self, key, payload):
        self.db.execute("INSERT OR IGNORE INTO tasks(key,payload) VALUES (?,?)", (key, json.dumps(payload, ensure_ascii=False)))
        self.db.commit()

    def next(self):
        row = self.db.execute("SELECT id,payload FROM tasks WHERE state='pending' ORDER BY id LIMIT 1").fetchone()
        if row:
            self.finish(row[0], "running")
            return row[0], json.loads(row[1])

    def finish(self, ident, state, error=None):
        self.db.execute("UPDATE tasks SET state=?,error=? WHERE id=?", (state, error, ident))
        self.db.commit()

    def recover(self):
        self.db.execute("UPDATE tasks SET state='pending' WHERE state IN ('failed','interrupted')")
        self.db.commit()

    def cancel_pending(self):
        self.db.execute("UPDATE tasks SET state='cancelled' WHERE state='pending'")
        self.db.commit()

    def close(self):
        self.db.close()
