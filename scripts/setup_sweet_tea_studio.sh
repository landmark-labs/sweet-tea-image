#!/bin/bash
# =============================================================================
# Sweet Tea Studio Setup & Start Script
# Clones, installs, and starts Sweet Tea Studio (frontend + backend)
# =============================================================================

# Don't use set -e - we want to handle errors gracefully and continue
# set -e

STS_PATH="${SWEET_TEA_PATH:-/opt/sweet-tea-studio}"
STS_REPO="${SWEET_TEA_REPO:-https://github.com/landmark-labs/sweet-tea-studio.git}"
LOG_DIR="/workspace/logs"

mkdir -p "$LOG_DIR"

echo "[sweet-tea] Starting Sweet Tea Studio setup..."

# Check for required tools
if ! command -v npm &> /dev/null; then
    echo "[sweet-tea] ERROR: npm not found. Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
    apt-get install -y nodejs 2>/dev/null
    if ! command -v npm &> /dev/null; then
        echo "[sweet-tea] FATAL: Could not install npm. Exiting."
        exit 1
    fi
    echo "[sweet-tea] Node.js installed: $(node --version), npm: $(npm --version)"
fi

# Clone repository if not present
if [ ! -d "$STS_PATH" ]; then
    echo "[sweet-tea] Cloning repository..."
    if ! git clone "$STS_REPO" "$STS_PATH"; then
        echo "[sweet-tea] ERROR: Failed to clone repository"
        exit 1
    fi
else
    echo "[sweet-tea] Repository already exists at $STS_PATH"
    # Optional: pull latest changes
    if [ "${SWEET_TEA_AUTO_UPDATE:-true}" = "true" ]; then
        echo "[sweet-tea] Checking for updates..."
        cd "$STS_PATH"
        git fetch origin 2>/dev/null || true
        LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "$LOCAL")
        if [ "$LOCAL" != "$REMOTE" ]; then
            echo "[sweet-tea] Updating to latest version..."
            git pull || echo "[sweet-tea] WARNING: git pull failed, continuing with existing version"
        else
            echo "[sweet-tea] Already up to date."
        fi
    fi
fi

# Setup and start Backend
echo "[sweet-tea] Setting up backend..."
cd "$STS_PATH/backend"

if [ ! -d "venv" ]; then
    echo "[sweet-tea] Creating backend virtual environment..."
    python3 -m venv venv
fi

source venv/bin/activate
echo "[sweet-tea] Installing backend dependencies..."
pip install -r requirements.txt
deactivate

echo "[sweet-tea] Starting backend on port 8000..."
source venv/bin/activate
nohup python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 > "$LOG_DIR/sweet-tea-backend.log" 2>&1 &
BACKEND_PID=$!
deactivate
echo "[sweet-tea] Backend started (PID: $BACKEND_PID)"

# Setup and start Frontend
echo "[sweet-tea] Setting up frontend..."
cd "$STS_PATH/frontend"

if [ ! -d "node_modules" ]; then
    echo "[sweet-tea] Installing frontend dependencies (this may take a minute)..."
    npm install 2>&1 | tail -10
fi

echo "[sweet-tea] Starting frontend on port 5173..."
nohup npm run dev -- --host 0.0.0.0 --port 5173 > "$LOG_DIR/sweet-tea-frontend.log" 2>&1 &
FRONTEND_PID=$!
echo "[sweet-tea] Frontend started (PID: $FRONTEND_PID)"

echo "[sweet-tea] ✅ Sweet Tea Studio is running!"
echo "[sweet-tea]    Frontend: http://localhost:5173 (via nginx: /studio/)"
echo "[sweet-tea]    Backend:  http://localhost:8000 (via nginx: /sts-api/)"
echo "[sweet-tea]    Logs: $LOG_DIR/sweet-tea-*.log"
