#  Luna - Local Autonomous AI Agent
A ReAct-style (Reason + Action) AI agent for Linux that runs entirely locally using Ollama. Luna can execute shell commands, manage files, remember information using vector memory, and intelligently route tasks.

## Features

- **ReAct Agent Loop** - Thinks step-by-step before taking action
- **Vector Memory** - ChromaDB-powered long-term memory with semantic search
- **Smart Model Escalation** - Medium → Large models for efficiency
- **Safety Guardrails** - Protected files, repeat detection, error recovery
- **Fast Routing** - Common commands bypass AI for instant responses
- **Context-Aware** - Uses scratchpad and relevant memory for each task

## Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/luna.git
cd luna

# Run installation script
chmod +x install.sh
./install.sh

# Start using Luna
./luna.sh hi
```

## Installation

### Prerequisites

- **Linux** (tested on Arch Linux, Ubuntu, Fedora)
- **Python 3.8+**
- **Ollama** - [Install from ollama.ai](https://ollama.ai)
- **socat** - for daemon socket communication (`sudo pacman -S socat` / `sudo apt install socat`)

### Automated Installation

```bash
./install.sh
```

The install script will:
1. Check system requirements
2. Create necessary directories
3. Install Python dependencies (chromadb, sentence-transformers)
4. Download required Ollama models
5. Pre-download embedding models

### Manual Installation

```bash
# Create directories
mkdir -p logs memory/chroma_db prompts

# Install socat (for daemon socket communication)
sudo pacman -S socat          # Arch
sudo apt install socat        # Ubuntu/Debian
sudo dnf install socat        # Fedora

# Install Python dependencies
pip3 install -r requirements.txt --break-system-packages  # On Arch
pip3 install -r requirements.txt  # On Ubuntu/Debian

# Download Ollama models
ollama pull llama3.2:3b-instruct-q4_k_m
ollama pull mannix/llama3.1-8b-lexi:q4_k_m

# Make executable
chmod +x luna.sh

# Test
./luna.sh hi
```

## Usage

### RAG Daemon (Optional but Recommended)

The RAG daemon keeps ChromaDB and the embedding model loaded in memory between calls, cutting RAG query time from ~2-5s to near-instant.

```bash
# Start the daemon in the background
./luna.sh luna daemon start

# Check if it's running
./luna.sh luna daemon status

# Stop it
./luna.sh luna daemon stop
```

When the daemon is running, all memory operations automatically use the socket. If it's not running, Luna falls back to direct Python calls transparently — no behaviour change.

### Basic Commands

```bash
# Casual conversation
./luna.sh hi
./luna.sh how are you

# Open applications
./luna.sh open spotify
./luna.sh open browser
./luna.sh open editor

# File operations
./luna.sh list files
./luna.sh find logs
```

### Memory System

```bash
# Store information
./luna.sh remember I like pizza
./luna.sh remember My favorite color is blue

# Retrieve information
./luna.sh what do I like
./luna.sh what is my favorite color
```

Luna also automatically prompts you when you say things like:
```bash
./luna.sh I use Arch Linux
# Luna: "You mentioned: I use Arch Linux"
#       "Should I remember this? (yes/no)"
```

### Agent Actions

Luna can execute multi-step tasks using the ReAct framework:

```bash
# File creation
./luna.sh create a file called notes.txt

# Shell commands
./luna.sh list all python files in current directory

# Complex queries
./luna.sh what do I know about programming
```

## Configuration

Edit `luna.sh` to customize your setup:

```bash
# User-based variables (lines 25-28)
spotify="spotify"           # Change to "flatpak run com.spotify.Client" if using Flatpak
editor="zeditor"           # Your preferred editor (code, vim, etc.)
browser="zen-browser"      # Your browser
explorer="thunar"          # Your file manager
```

### Debug Mode

Enable debugging to see the scratchpad:

```bash
# Edit luna.sh, line 17:
DEBUG_MODE=true
```

### Models

Configure which models to use (lines 8-10):

```bash
MODEL_MEDIUM="llama3.2:3b-instruct-q4_k_m"     # General tasks
MODEL_LARGE="mannix/llama3.1-8b-lexi:q4_k_m"   # Complex reasoning (optional)
```

## Architecture

### ReAct Loop

Luna uses a Reason + Action pattern:

1. **Reason** - Model thinks step-by-step about the task
2. **Action** - Selects and executes a tool
3. **Observation** - Processes tool output
4. **Repeat** - Continues until task is complete (max 6 steps)

### Model Escalation

- **Medium model (3B)** - If small model fails or gives malformed output
- **Large model (8B)** - For complex tasks or after repeated failures

### Tools Available

- `shell` - Execute bash commands (safe, with timeout)
- `read_file` - Read file contents
- `write_file` - Create/write files (protects critical files)
- `scratchpad_update` - Update working memory
- `memory_store` - Save to vector memory (ChromaDB)
- `finish` - Complete the task

### Entry Routing

Fast commands bypass the AI agent entirely. Intent classification uses MODEL_SMALL (1.5b), a tiny model that does a single-token classification call — much smarter than regex but still fast:

```
app_open    → open app directly
memory_save → store to ChromaDB (with optional confirmation)
memory_ask  → run_agent (so RAG context gets injected)
file_op     → ls / find directly
chat        → MODEL_MEDIUM brief response
agent       → full ReAct loop
```

### RAG Daemon

`rag_daemon.py` is a persistent Python process that keeps ChromaDB and the embedding model (`all-MiniLM-L6-v2`) warm in memory. It communicates via a Unix socket (`/tmp/luna_rag.sock`). `rag_call()` in `luna.sh` transparently uses the socket when the daemon is running, and falls back to direct Python calls otherwise.

## Project Structure

```
luna/
├── luna.sh              # Main agent script
├── memory/
│   ├── rag.py          # Vector memory (ChromaDB) — direct CLI fallback
│   ├── rag_daemon.py   # Persistent daemon, keeps embedding model warm
│   └── chroma_db/      # Persistent vector database
├── prompts/
│   └── system.txt      # Agent system prompt
├── logs/
│   ├── agent.log       # Agent reasoning logs
│   ├── model_stats.log # Response times per model
│   └── rag_daemon.log  # Daemon output (when running)
├── install.sh          # Installation script
└── requirements.txt    # Python dependencies
```

## How It Works

### 1. Entry Point (`luna.sh`)

User input goes through fast routing first:
- Pattern matching for common commands → Instant execution
- Everything else → ReAct agent

### 2. ReAct Agent Loop

```
User Input → Retrieve Relevant Memory
           ↓
    Build Context Prompt
           ↓
    Model Generates: THOUGHT, ACTION, ARGS
           ↓
    Execute Tool (shell, read_file, etc.)
           ↓
    Update Scratchpad with Result
           ↓
    Repeat until ACTION: finish
```

### 3. Vector Memory (`rag.py`)

- Uses ChromaDB with sentence-transformers
- Embedding model: `all-MiniLM-L6-v2`
- Semantic search with similarity threshold
- Deduplication via content hashing

### 4. Safety Features

- **Protected files**: luna.sh and system.txt cannot be modified
- **Repeat detection**: Escalates to larger model after 2 identical actions
- **Error recovery**: Escalates after 2 consecutive failures
- **Command timeout**: Shell commands timeout after 10s
- **Question filtering**: Prevents storing questions as memory

## Examples

### Example 1: Knowledge Retrieval

```bash
$ ./luna.sh remember Python is my favorite programming language
✓ Memory saved.

$ ./luna.sh what is my favorite programming language
[MEMORY 1] Python is my favorite programming language
```

### Example 2: File Operations

```bash
$ ./luna.sh create a file called todo.txt with "Buy groceries"

THOUGHT: Need to create a file with content
ACTION: write_file
ARGS: todo.txt|Buy groceries

Write attempted.
Task complete.
```

### Example 3: Shell Commands

```bash
$ ./luna.sh list all markdown files

THOUGHT: Need to find .md files in current directory
ACTION: shell
ARGS: find . -maxdepth 2 -name "*.md"

./README.md
./FIXES-SUMMARY.md
./LEARNING-QUICK-START.md
```

## Troubleshooting

### "ModuleNotFoundError: No module named 'chromadb'"

```bash
pip3 install chromadb sentence-transformers --break-system-packages
```

### Ollama models not found

```bash
ollama pull llama3.2:3b-instruct-q4_k_m
```

### Agent gets stuck in a loop

- Check `logs/agent.log` to see reasoning
- Enable `DEBUG_MODE=true` in luna.sh
- The agent has repeat detection and will escalate to larger model

### Memory not working

```bash
# Check if ChromaDB directory exists
ls -la memory/chroma_db/

# Should see: chroma.sqlite3
# If not, run:
python3 memory/rag.py add "test memory"
```

### Permission denied

```bash
chmod +x luna.sh
```

## Performance

- **Fast commands** (open, list files): ~0.1s (no AI)
- **Memory retrieval**: ~0.3s (ChromaDB search)
- **Agent tasks** (medium model): 3-8s
- **Complex reasoning** (large model): 10-20s

## Limitations

- Maximum 6 reasoning steps per task
- 10-second timeout for shell commands
- Linux only
- Requires Ollama and local models

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes (preserve existing comments)
4. Test thoroughly
5. Submit a pull request

## License

MIT License - See LICENSE file for details

## Credits

- ReAct framework inspiration: [Yao et al., 2022](https://arxiv.org/abs/2210.03629)
- Vector memory: [ChromaDB](https://www.trychroma.com/)
- Embeddings: [Sentence Transformers](https://www.sbert.net/)
- Local LLMs: [Ollama](https://ollama.ai/)
- Claude Ai : for optimizing and, making this readme.md and install.sh
- Chatgpt : for ideas

## Respect

LUNA v1 was the first assistant I had , although it was highly unoptimized and using txt files for memories and having multi functions which made it unstable. 
That is my starting point and it helped alot ❤️  .

## Author

Created with ❤️ for local, private AI agents 

---
