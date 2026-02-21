#!/bin/bash
set -e

echo "========================================="
echo "  🌙 LUNA - Installation Script"
echo "========================================="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check if running on Linux
if [[ "$(uname)" != "Linux" ]]; then
    print_error "This script is designed for Linux systems only."
    exit 1
fi

echo "[1/8] Checking system requirements..."
echo

# Check for required commands
MISSING_DEPS=()

if ! command -v python3 &> /dev/null; then
    MISSING_DEPS+=("python3")
fi

if ! command -v pip3 &> /dev/null && ! command -v pip &> /dev/null; then
    MISSING_DEPS+=("python3-pip")
fi

if ! command -v socat &> /dev/null; then
    MISSING_DEPS+=("socat")
fi

if ! command -v ollama &> /dev/null; then
    print_warning "Ollama not found. You'll need to install it manually."
    echo "Visit: https://ollama.ai"
    MISSING_DEPS+=("ollama")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    print_error "Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    echo
    echo "Install them with:"
    if command -v pacman &> /dev/null; then
        echo "  sudo pacman -S python python-pip socat"
    elif command -v apt &> /dev/null; then
        echo "  sudo apt install python3 python3-pip socat"
    elif command -v dnf &> /dev/null; then
        echo "  sudo dnf install python3 python3-pip socat"
    fi
    echo
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    print_success "All system requirements met"
fi

echo
echo "[2/8] Creating directory structure..."

mkdir -p logs
mkdir -p memory/chroma_db
mkdir -p memory
mkdir -p prompts

print_success "Directories created"

echo
echo "[3/8] Making luna.sh executable..."

if [ -f "luna.sh" ]; then
    chmod +x luna.sh
    print_success "luna.sh is now executable"
else
    print_error "luna.sh not found in current directory"
    exit 1
fi

echo
echo "[4/8] Installing Python dependencies..."
echo

# Determine which pip command to use
if command -v pip3 &> /dev/null; then
    PIP_CMD="pip3"
elif command -v pip &> /dev/null; then
    PIP_CMD="pip"
else
    print_error "pip not found"
    exit 1
fi

# Check if we're on Arch/Manjaro (needs --break-system-packages)
if command -v pacman &> /dev/null; then
    PIP_FLAGS="--break-system-packages"
else
    PIP_FLAGS=""
fi

echo "Installing chromadb..."
$PIP_CMD install chromadb $PIP_FLAGS --quiet

echo "Installing sentence-transformers..."
$PIP_CMD install sentence-transformers $PIP_FLAGS --quiet

print_success "Python dependencies installed"

echo
echo "[5/8] Checking Ollama models..."
echo

if command -v ollama &> /dev/null; then
    MODELS=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}' || echo "")

    REQUIRED_MODELS=(
        "llama3.2:3b-instruct-q4_k_m"
    )

    MISSING_MODELS=()

    for model in "${REQUIRED_MODELS[@]}"; do
        if ! echo "$MODELS" | grep -q "^${model%:*}"; then
            MISSING_MODELS+=("$model")
        fi
    done

    if [ ${#MISSING_MODELS[@]} -gt 0 ]; then
        print_warning "Missing Ollama models:"
        for model in "${MISSING_MODELS[@]}"; do
            echo "  - $model"
        done
        echo
        echo "Install them with:"
        for model in "${MISSING_MODELS[@]}"; do
            echo "  ollama pull $model"
        done
        echo
        read -p "Install missing models now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for model in "${MISSING_MODELS[@]}"; do
                echo "Pulling $model..."
                ollama pull "$model"
            done
            print_success "Models installed"
        fi
    else
        print_success "All required models are installed"
    fi
else
    print_warning "Ollama not installed. Install from: https://ollama.ai"
    echo
    echo "Then run:"
    echo "  ollama pull llama3.2:3b-instruct-q4_k_m"
fi

echo
echo "[6/8] Checking system.txt..."

if [ ! -f "prompts/system.txt" ]; then
    print_warning "prompts/system.txt not found (will use the one from repo)"
else
    print_success "system.txt exists"
fi

echo
echo "[7/8] Pre-downloading embedding model..."
echo

echo "[8/8] Moving files to directories ..."

mv "rag.py" "$(pwd)/memory/"
mv "rag_daemon.py" "$(pwd)/memory/"
mv "system.txt" "$(pwd)/prompts/"
touch "$(pwd)/logs/log.txt"
touch "$(pwd)/logs/agent.log"
touch "$(pwd)/logs/model_stats.log"
touch "$(pwd)/logs/rag_daemon.log"

print_success "Files Moved"

# Pre-download the embedding model
python3 - <<'EOF'
import os
os.makedirs("memory/chroma_db", exist_ok=True)

try:
    from sentence_transformers import SentenceTransformer
    print("Downloading embedding model (this may take a minute)...")
    model = SentenceTransformer('all-MiniLM-L6-v2')
    print("✓ Embedding model downloaded")
except Exception as e:
    print(f"⚠ Could not pre-download model: {e}")
    print("It will be downloaded on first use")
EOF

echo
echo "========================================="
echo "  ✓ Installation Complete!"
echo "========================================="
echo
echo "Configuration:"
echo "  • Directory: $(pwd)"
echo "  • Logs: $(pwd)/logs/"
echo "  • Memory: $(pwd)/memory/"
echo "  • Prompts: $(pwd)/prompts/"
echo
echo "Usage:"
echo "  ./luna.sh hi"
echo "  ./luna.sh remember I like pizza"
echo "  ./luna.sh what do I like"
echo "  ./luna.sh open spotify"
echo "  ./luna.sh list files"
echo
echo "Customization:"
echo "  Edit luna.sh to change:"
echo "  • spotify=\"spotify\"     # Your Spotify command"
echo "  • editor=\"zeditor\"      # Your editor"
echo "  • browser=\"zen-browser\" # Your browser"
echo "  • explorer=\"thunar\"     # Your file manager"
echo
echo "Debug Mode:"
echo "  Edit luna.sh: DEBUG_MODE=true"
echo
echo "First run:"
echo "  ./luna.sh hi"
echo
echo "Optional — start RAG daemon for faster memory queries:"
echo "  ./luna.sh luna daemon start"
echo
print_success "Luna is ready! 🌙"
echo
