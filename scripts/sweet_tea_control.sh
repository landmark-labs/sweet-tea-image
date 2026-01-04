#!/bin/bash
# =============================================================================
# Sweet Tea Studio Control Script
# Usage: sweet-tea [start|stop|restart|status|log]
# =============================================================================

STS_PATH="${SWEET_TEA_PATH:-/opt/sweet-tea-studio}"
LOG_DIR="/workspace/logs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

get_backend_pid() {
    pgrep -f "uvicorn app.main:app.*8000" 2>/dev/null | head -1
}

get_frontend_pid() {
    pgrep -f "vite.*5173" 2>/dev/null | head -1
}

stop_sweet_tea() {
    echo -e "${YELLOW}[sweet-tea] Stopping Sweet Tea Studio...${NC}"
    
    # Stop backend
    BACKEND_PID=$(get_backend_pid)
    if [[ -n "$BACKEND_PID" ]]; then
        kill "$BACKEND_PID" 2>/dev/null
        
        # Wait for graceful exit
        TIMEOUT=10
        while kill -0 "$BACKEND_PID" 2>/dev/null && [ $TIMEOUT -gt 0 ]; do
            sleep 1
            ((TIMEOUT--))
        done
        
        # Force kill if still running
        if kill -0 "$BACKEND_PID" 2>/dev/null; then
            echo "[sweet-tea] Backend did not exit gracefully, force killing..."
            kill -9 "$BACKEND_PID" 2>/dev/null
            sleep 1
        fi
        echo "[sweet-tea] Backend stopped (PID: $BACKEND_PID)"
    else
        echo "[sweet-tea] Backend not running"
    fi
    
    # Stop frontend
    FRONTEND_PID=$(get_frontend_pid)
    if [[ -n "$FRONTEND_PID" ]]; then
        kill "$FRONTEND_PID" 2>/dev/null
        # Also kill any child node processes
        pkill -f "node.*vite" 2>/dev/null || true
        
        # Wait for graceful exit
        TIMEOUT=10
        while kill -0 "$FRONTEND_PID" 2>/dev/null && [ $TIMEOUT -gt 0 ]; do
            sleep 1
            ((TIMEOUT--))
        done
        
        # Force kill if still running
        if kill -0 "$FRONTEND_PID" 2>/dev/null; then
            echo "[sweet-tea] Frontend did not exit gracefully, force killing..."
            kill -9 "$FRONTEND_PID" 2>/dev/null
            pkill -9 -f "node.*vite" 2>/dev/null || true
            sleep 1
        fi
        echo "[sweet-tea] Frontend stopped (PID: $FRONTEND_PID)"
    else
        echo "[sweet-tea] Frontend not running"
    fi
    
    # Final verification that all processes are dead
    if [[ -n "$(get_backend_pid)" ]] || [[ -n "$(get_frontend_pid)" ]]; then
        echo -e "${RED}[sweet-tea] Warning: Some processes may still be running${NC}"
        return 1
    fi
    
    echo "[sweet-tea] All processes stopped successfully"
}

start_sweet_tea() {
    echo -e "${GREEN}[sweet-tea] Starting Sweet Tea Studio...${NC}"
    
    if [[ ! -d "$STS_PATH" ]]; then
        echo -e "${RED}[sweet-tea] Error: Sweet Tea Studio not found at $STS_PATH${NC}"
        echo "[sweet-tea] Run the setup script first: /scripts/setup_sweet_tea_studio.sh"
        exit 1
    fi
    
    mkdir -p "$LOG_DIR"
    
    # Start Backend
    cd "$STS_PATH/backend"
    if [[ ! -d "venv" ]]; then
        echo "[sweet-tea] Backend venv not found, running setup..."
        python3 -m venv venv
        source venv/bin/activate
        pip install --no-cache-dir -q -r requirements.txt
        deactivate
    fi
    
    source venv/bin/activate
    nohup python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 > "$LOG_DIR/sweet-tea-backend.log" 2>&1 &
    BACKEND_PID=$!
    deactivate
    echo "[sweet-tea] Backend started (PID: $BACKEND_PID)"
    
    # Start Frontend
    cd "$STS_PATH/frontend"
    if [[ ! -d "node_modules" ]]; then
        echo "[sweet-tea] Installing frontend dependencies..."
        npm install --silent
    fi
    
    nohup npm run dev -- --host 0.0.0.0 --port 5173 > "$LOG_DIR/sweet-tea-frontend.log" 2>&1 &
    FRONTEND_PID=$!
    echo "[sweet-tea] Frontend started (PID: $FRONTEND_PID)"
    
    echo -e "${GREEN}[sweet-tea] ✅ Sweet Tea Studio is running!${NC}"
    echo "[sweet-tea]    Frontend: http://localhost:5173 (via nginx: /studio/)"
    echo "[sweet-tea]    Backend:  http://localhost:8000 (via nginx: /sts-api/)"
}

status_sweet_tea() {
    echo "[sweet-tea] Status:"
    
    BACKEND_PID=$(get_backend_pid)
    if [[ -n "$BACKEND_PID" ]]; then
        echo -e "  Backend:  ${GREEN}Running${NC} (PID: $BACKEND_PID)"
    else
        echo -e "  Backend:  ${RED}Stopped${NC}"
    fi
    
    FRONTEND_PID=$(get_frontend_pid)
    if [[ -n "$FRONTEND_PID" ]]; then
        echo -e "  Frontend: ${GREEN}Running${NC} (PID: $FRONTEND_PID)"
    else
        echo -e "  Frontend: ${RED}Stopped${NC}"
    fi
}

show_logs() {
    echo "[sweet-tea] Showing logs (Ctrl+C to exit)..."
    echo "=== Backend ===" 
    tail -20 "$LOG_DIR/sweet-tea-backend.log" 2>/dev/null || echo "No backend log found"
    echo ""
    echo "=== Frontend ==="
    tail -20 "$LOG_DIR/sweet-tea-frontend.log" 2>/dev/null || echo "No frontend log found"
}

update_sweet_tea() {
    echo -e "${YELLOW}[sweet-tea] Updating Sweet Tea Studio...${NC}"
    
    if [[ ! -d "$STS_PATH" ]]; then
        echo "[sweet-tea] Not installed. Running setup..."
        bash /scripts/setup_sweet_tea_studio.sh
        return
    fi
    
    cd "$STS_PATH"
    git fetch origin
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "$LOCAL")
    
    if [[ "$LOCAL" != "$REMOTE" ]]; then
        echo "[sweet-tea] Update found! Pulling latest..."
        git pull
        
        # Reinstall dependencies
        cd "$STS_PATH/backend"
        source venv/bin/activate
        pip install --no-cache-dir -q -r requirements.txt
        deactivate
        
        cd "$STS_PATH/frontend"
        npm install --silent
        
        echo -e "${GREEN}[sweet-tea] Updated to $(git rev-parse --short HEAD)${NC}"
        echo "[sweet-tea] Restart with: sweet-tea restart"
    else
        echo "[sweet-tea] Already up to date."
    fi
}

# Main command handler
case "${1:-status}" in
    start)
        start_sweet_tea
        ;;
    stop)
        stop_sweet_tea
        ;;
    restart)
        stop_sweet_tea
        start_sweet_tea
        ;;
    status)
        status_sweet_tea
        ;;
    log|logs)
        show_logs
        ;;
    update)
        update_sweet_tea
        ;;
    *)
        echo "Usage: sweet-tea [start|stop|restart|status|log|update]"
        echo ""
        echo "Commands:"
        echo "  start   - Start Sweet Tea Studio"
        echo "  stop    - Stop Sweet Tea Studio"
        echo "  restart - Restart Sweet Tea Studio"
        echo "  status  - Show running status"
        echo "  log     - Show recent logs"
        echo "  update  - Pull latest code and update dependencies"
        exit 1
        ;;
esac
