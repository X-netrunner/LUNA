#!/usr/bin/env python3
"""
LUNA RAG Daemon
Keeps ChromaDB and the embedding model loaded in memory between calls.
Communicates via a Unix socket so luna.sh avoids Python startup overhead on every query.

Protocol: newline-terminated JSON request -> newline-terminated JSON response
  add:   {"mode": "add",   "text": "..."}  ->  {"status": "ok"|"error", "message": "..."}
  query: {"mode": "query", "text": "..."}  ->  {"status": "ok", "result": "..."}
  ping:  {"mode": "ping"}                  ->  {"status": "ok", "message": "pong"}

Usage (from luna.sh):
  python3 memory/rag_daemon.py start &   # start daemon in background
  python3 memory/rag_daemon.py stop      # graceful shutdown
  python3 memory/rag_daemon.py status    # check if running
"""

import hashlib
import json
import os
import signal
import socket
import sys

SOCKET_PATH = "/tmp/luna_rag.sock"
PID_FILE = "/tmp/luna_rag.pid"
CHROMA_PATH = "memory/chroma_db"
SIMILARITY_THRESHOLD = 0.8


# ---------------------------------------------------------------------------
# Heavy imports — done once at daemon startup, not on every call
# ---------------------------------------------------------------------------

def _load_collection():
    import chromadb
    from chromadb.utils import embedding_functions

    os.makedirs(CHROMA_PATH, exist_ok=True)

    ef = embedding_functions.SentenceTransformerEmbeddingFunction(
        model_name="all-MiniLM-L6-v2"
    )
    client = chromadb.PersistentClient(path=CHROMA_PATH)
    collection = client.get_or_create_collection(name="memory", embedding_function=ef)
    return collection


# ---------------------------------------------------------------------------
# Core operations (same logic as rag.py, but reuses the loaded collection)
# ---------------------------------------------------------------------------

def _add(collection, text):
    text = text.strip()

    if not text:
        return {"status": "error", "message": "Empty memory."}
    if text.endswith("?"):
        return {"status": "error", "message": "Refusing to store a question."}
    if len(text.split()) < 3:
        return {"status": "error", "message": "Too short to store."}

    doc_id = hashlib.sha256(text.encode()).hexdigest()
    collection.upsert(documents=[text], ids=[doc_id])
    return {"status": "ok", "message": "✓ Memory saved."}


def _query(collection, text, top_k=1):
    if not text.strip():
        return {"status": "ok", "result": ""}

    results = collection.query(
        query_texts=[text],
        n_results=top_k,
        include=["documents", "distances"],
    )

    docs = results.get("documents", [[]])[0]
    distances = results.get("distances", [[]])[0]

    relevant = [
        doc for doc, dist in zip(docs, distances)
        if dist is not None and dist < SIMILARITY_THRESHOLD
    ]

    return {"status": "ok", "result": "\n".join(relevant)}


def _handle(collection, raw):
    try:
        req = json.loads(raw)
        mode = req.get("mode", "")
        text = req.get("text", "")

        if mode == "add":
            return _add(collection, text)
        elif mode == "query":
            return _query(collection, text)
        elif mode == "ping":
            return {"status": "ok", "message": "pong"}
        else:
            return {"status": "error", "message": f"Unknown mode: {mode}"}

    except Exception as e:
        return {"status": "error", "message": str(e)}


# ---------------------------------------------------------------------------
# Daemon server
# ---------------------------------------------------------------------------

def _run_daemon():
    # Record PID for stop/status commands
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    # Clean up any stale socket from a previous crash
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    print(f"[LUNA RAG daemon] Loading models...", flush=True)
    collection = _load_collection()
    print(f"[LUNA RAG daemon] Ready — PID {os.getpid()}", flush=True)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(5)
    os.chmod(SOCKET_PATH, 0o600)  # owner-only access

    def _shutdown(sig, frame):
        print("[LUNA RAG daemon] Shutting down...", flush=True)
        server.close()
        for path in (SOCKET_PATH, PID_FILE):
            if os.path.exists(path):
                os.unlink(path)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    while True:
        try:
            conn, _ = server.accept()
            with conn:
                data = conn.recv(8192).decode().strip()
                if data:
                    response = _handle(collection, data)
                    conn.sendall((json.dumps(response) + "\n").encode())
        except OSError:
            break  # server was closed by signal handler
        except Exception as e:
            print(f"[LUNA RAG daemon] Error: {e}", flush=True)


# ---------------------------------------------------------------------------
# CLI for start / stop / status — and direct add/query for testing
# ---------------------------------------------------------------------------

def _daemon_running():
    if not os.path.exists(PID_FILE):
        return False
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)  # signal 0 just checks existence
        return True
    except (ProcessLookupError, ValueError):
        return False


def _socket_call(req_dict):
    """Send a request to the running daemon and return the parsed response."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCKET_PATH)
    s.sendall((json.dumps(req_dict) + "\n").encode())
    raw = s.recv(8192).decode()
    s.close()
    return json.loads(raw)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: rag_daemon.py [start|stop|status|add <text>|query <text>]")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "start":
        if _daemon_running():
            print("Daemon is already running.")
            sys.exit(0)
        _run_daemon()

    elif cmd == "stop":
        if not _daemon_running():
            print("Daemon is not running.")
            sys.exit(0)
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
        print(f"Daemon stopped (PID {pid}).")

    elif cmd == "status":
        if _daemon_running():
            with open(PID_FILE) as f:
                pid = f.read().strip()
            print(f"Daemon running (PID {pid})")
        else:
            print("Daemon not running.")

    elif cmd in ("add", "query") and len(sys.argv) >= 3:
        text = " ".join(sys.argv[2:])
        if os.path.exists(SOCKET_PATH):
            res = _socket_call({"mode": cmd, "text": text})
            print(res.get("result") or res.get("message", ""))
        else:
            print("Daemon not running. Start with: python3 memory/rag_daemon.py start &")
            sys.exit(1)

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
