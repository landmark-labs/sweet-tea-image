#!/usr/bin/env bash
# =========================[ R2 / rclone Integration ]=========================
# Mirror all script output to both console and a startup log.
mkdir -p /workspace/logs
exec > >(tee -a /workspace/logs/startup.log) 2>&1
echo "[init] startup logging to /workspace/logs/startup.log"

# Set LOCAL_ROOT to ComfyUI directory
: "${LOCAL_ROOT:=/opt/ComfyUI}"
export LOCAL_ROOT
echo "[r2] LOCAL_ROOT resolved to: ${LOCAL_ROOT}"

# Install rclone if missing
install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    echo "[r2] rclone present; attempting selfupdate..."
    return 0
  fi

  echo "[r2] Installing rclone..."
	if command -v apt-get >/dev/null 2>&1; then
	  apt-get update -y
	  apt-get install -y curl unzip ca-certificates
	fi

  # Pick a binary for the current arch
  ARCH="amd64"
  case "$(uname -m)" in
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7)  ARCH="arm-v7" ;;
  esac

  TMP="$(mktemp -d)"
  curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${ARCH}.zip" -o "${TMP}/rclone.zip"
  unzip -q "${TMP}/rclone.zip" -d "${TMP}"
  install -m 0755 "${TMP}"/rclone-*-linux-${ARCH}/rclone /usr/local/bin/rclone
  rm -rf "${TMP}"

  rclone version | head -n1 | awk '{print "[r2] rclone installed " $2}'
}

# Configure R2 credentials
configure_rclone() {
  mkdir -p /root/.config/rclone

  if [[ -z "${R2_ACCOUNT_ID}" || -z "${R2_ACCESS_KEY_ID}" || -z "${R2_SECRET_ACCESS_KEY}" ]]; then
      echo "[r2] WARNING: R2 credentials not set. Sync will be disabled."
      return 1
  fi

  cat >/root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF

  echo "[r2] rclone remote configured."
}

# Common rclone args
r2_common_args() {
  echo "--fast-list --transfers ${RCLONE_TRANSFERS:-12} --checkers ${RCLONE_CHECKERS:-24} --size-only"
}

# Synchronous sync-down for CRITICAL files (scripts, custom_nodes, user, sweet_tea)
r2_sync_critical() {
  if [[ -z "${R2_BUCKET:-}" ]]; then
    echo "[r2] R2_BUCKET not set; skipping critical sync."
    return 0
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    echo "[r2] rclone missing; skipping critical sync."
    return 0
  fi

  local REMOTE="r2:${R2_BUCKET}${R2_PREFIX:+/${R2_PREFIX}}"
  echo "[r2] Starting CRITICAL sync (scripts, custom_nodes, user, sweet_tea)..."

  # Ensure directories exist
  for d in scripts custom_nodes user sweet_tea; do
    mkdir -p "${LOCAL_ROOT}/${d}"
  done

  echo "[r2] Syncing critical components..."
  for p in scripts custom_nodes user sweet_tea; do
    echo "[r2] copy ${REMOTE}/${p} -> ${LOCAL_ROOT}/${p}"
    set +e
    rclone copy \
      "${REMOTE}/${p}" "${LOCAL_ROOT}/${p}" \
      $(r2_common_args) \
      --order-by size,ascending \
      --no-traverse \
      --create-empty-src-dirs \
      --stats 10s --stats-one-line --log-level NOTICE \
      $(for e in "/**/.git/**" "/**/__pycache__/**" "/**/outputs/**" "/**/temp/**" "/**/*.tmp" "/**/*.part"; do printf -- "--exclude %q " "$e"; done) \
      2>&1 | grep --line-buffered -v "Failed to read mtime"
    rc=${PIPESTATUS[0]}; set -e
    if [[ $rc -ne 0 ]]; then
      echo "[r2] WARNING: rclone copy for ${p} exited with ${rc}; continuing."
    fi
  done
  echo "[r2] CRITICAL sync finished."
}

# Async sync-down for ASSETS (output, input, models)
r2_sync_assets_async() {
  if [[ -z "${R2_BUCKET:-}" ]]; then
    return 0
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    return 0
  fi

  local REMOTE="r2:${R2_BUCKET}${R2_PREFIX:+/${R2_PREFIX}}"
  local LOG="${R2_DOWN_LOG:-/workspace/logs/rclone_down.log}"

  echo "[r2] Starting BACKGROUND sync (output, input, models, vlm)..."

  # Ensure directories exist
  for d in output input models vlm; do
    mkdir -p "${LOCAL_ROOT}/${d}"
  done

  # Run entire sync in a backgrounded subshell at lowest priority
  # nice -n 19 = lowest CPU priority, ionice -c 3 = idle IO class (only runs when nothing else needs IO)
  # Structure: ( subshell with all work ) &
  #   - The outer parentheses create a subshell
  #   - The & at the end backgrounds the ENTIRE subshell
  #   - This guarantees the function returns immediately
  local RCLONE_ARGS
  RCLONE_ARGS="$(r2_common_args)"
  
  (
    echo "[r2] Sync-down (copy) from ${REMOTE}/{output,input,models,vlm} -> ${LOCAL_ROOT}/..."
    for p in output input models vlm; do
      echo "[r2] copy ${REMOTE}/${p} -> ${LOCAL_ROOT}/${p}"
      nice -n 19 ionice -c 3 rclone copy \
        "${REMOTE}/${p}" "${LOCAL_ROOT}/${p}" \
        ${RCLONE_ARGS} \
        --order-by size,ascending \
        --no-traverse \
        --create-empty-src-dirs \
        --stats 10s --stats-one-line --log-level NOTICE \
        --exclude "/**/.git/**" \
        --exclude "/**/__pycache__/**" \
        --exclude "/**/outputs/**" \
        --exclude "/**/temp/**" \
        --exclude "/**/*.tmp" \
        --exclude "/**/*.part" || echo "[r2] WARNING: rclone copy for ${p} exited with $?; continuing."
    done
    echo "[r2] Background sync-down finished."
  ) >> "${LOG}" 2>&1 &
  
  SYNC_DOWN_PID=$!
  export SYNC_DOWN_PID
  echo "[r2] Background pull started (pid=${SYNC_DOWN_PID}); tail -f ${LOG} to watch progress."
}

# Sync-up to R2 (not currently used by default)
r2_sync_up_sync() {
  local LOCAL_ROOT="${LOCAL_ROOT:-/opt/ComfyUI}"
  local REMOTE="r2:${R2_BUCKET}${R2_PREFIX:+/${R2_PREFIX}}"
  local EXCLUDES=( "/**/.git/**" "/**/__pycache__/**" "/**/outputs/**" "/**/temp/**" "/**/*.tmp" "/**/*.part" )

  for p in scripts custom_nodes user sweet_tea output input models vlm; do
    rclone sync \
      "${LOCAL_ROOT}/${p}" "${REMOTE}/${p}" \
      $(r2_common_args) \
      $(r2_common_args) \
      --no-update-modtime \
      --copy-links \
      --delete-after \
      $(for e in "${EXCLUDES[@]}"; do printf -- "--exclude %q " "$e"; done)
  done
}

# Cleanup handler
cleanup() {
  echo "[exit] stopping background pull (if any)..."
  if [[ -n "${SYNC_DOWN_PID:-}" ]] && kill -0 "${SYNC_DOWN_PID}" 2>/dev/null; then
    kill -TERM "${SYNC_DOWN_PID}" 2>/dev/null || true
    wait "${SYNC_DOWN_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Install and configure rclone
if install_rclone && configure_rclone; then
  trap cleanup EXIT INT TERM
else
  echo "[r2] rclone/R2 not configured; skipping EXIT sync."
fi

set -e

# ---------------------------------------------------------------------------- #
#                          Optimized Startup Script                            #
# ---------------------------------------------------------------------------- #

echo "Starting optimized ComfyUI environment..."

# Generate SSH host keys
generate_ssh_host_keys() {
    echo "Generating SSH host keys..."
    ssh-keygen -A
}

# Compile SageAttention on first run
install_or_verify_sageattention() {
    local VENV_PYTHON="/opt/ComfyUI/venv/bin/python3"
    local DONE_FILE="/opt/ComfyUI/.sageattention_installed"

    if [ -f "$DONE_FILE" ]; then
        echo "✅ SageAttention is already compiled. Skipping."
        return
    fi

    echo "🚀 First run detected. Compiling SageAttention..."
    
    source /opt/ComfyUI/venv/bin/activate
    
    export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas
    export CUDA_HOME=/usr/local/cuda
    export TORCH_CUDA_ARCH_LIST="8.9;12.0"
	export FORCE_CUDA=1

    rm -rf /tmp/SageAttention

    echo "Cloning and building SageAttention..."
    cd /tmp
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention

    echo "Compiling kernels..."
    $VENV_PYTHON setup.py build_ext --inplace
    pip3 install --no-build-isolation --no-deps .

    echo "Verifying installation..."
    $VENV_PYTHON -c "import torch, triton, sageattention; print('✅ SageAttention compiled and installed successfully')"
    
    cd /
    rm -rf /tmp/SageAttention
    touch "$DONE_FILE"
    
    deactivate
    echo "SageAttention setup complete."
}

# Setup Code Server
setup_code_server() {
    echo "Setting up enhanced Code Server..."
    
    mkdir -p /workspace/.code-server/{data,extensions}
    mkdir -p /workspace/.code-server/data/User
    
    cp /config/code_server_settings.json /workspace/.code-server/data/User/settings.json
    
    echo "Installing Code Server extensions..."
    code-server --user-data-dir /workspace/.code-server/data \
                --extensions-dir /workspace/.code-server/extensions \
                --install-extension PKief.material-icon-theme 2>/dev/null || true
    code-server --user-data-dir /workspace/.code-server/data \
                --extensions-dir /workspace/.code-server/extensions \
                --install-extension ms-python.python 2>/dev/null || true
    
    nohup code-server \
        --bind-addr 0.0.0.0:7778 \
        --auth none \
        --user-data-dir /workspace/.code-server/data \
        --extensions-dir /workspace/.code-server/extensions \
        / > /workspace/logs/code-server.log 2>&1 &
    
    echo "Code Server started (access via port 7777)"
}

# Setup FileBrowser
setup_filebrowser() {
    echo "Setting up FileBrowser..."
    
    DB_PATH="/workspace/.filebrowser.db"
    LOG_PATH="/workspace/logs/filebrowser.log"

    rm -f "${DB_PATH}"

    filebrowser config init --database "${DB_PATH}"
    filebrowser users add admin filebrowser --database "${DB_PATH}"

    nohup filebrowser \
        --database "${DB_PATH}" \
        --address 0.0.0.0 \
        --port 8889 \
        --root / > "${LOG_PATH}" 2>&1 &

    echo "FileBrowser started (access via port 8888, admin/filebrowser)"
}

# Create download helper
create_download_helper() {
    cp /scripts/download_outputs.py /workspace/download_outputs.py
    chmod +x /workspace/download_outputs.py
    
    echo "Download helper created at /workspace/download_outputs.py"
}

# Create ComfyUI helper
create_comfyui_helper() {
    cp /scripts/comfyui_control.sh /workspace/comfyui_control.sh
    chmod +x /workspace/comfyui_control.sh
    ln -sf /workspace/comfyui_control.sh /usr/local/bin/comfyui
    
    cp /scripts/batch_workflow.py /usr/local/bin/batch
    chmod +x /usr/local/bin/batch
    
    echo "ComfyUI control script created. Use 'comfyui start/stop/restart/status/log'"
    echo "Batch workflow helper installed. Use 'batch start/list/select/clear/stats'"
}

# Setup monitoring
setup_monitoring() {
    cp /scripts/monitor.py /workspace/monitor.py
    chmod +x /workspace/monitor.py
}

# Check GPU compatibility
check_gpu_compatibility() {
    echo "Checking GPU compatibility..."
    
    CUDA_VERSION=$(nvidia-smi | grep -oP "CUDA Version: \K[0-9.]+")
    echo "CUDA Version: $CUDA_VERSION"
    
    DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    echo "Driver Version: $DRIVER_VERSION"
    
    source /opt/ComfyUI/venv/bin/activate
    python3 -c "
import torch
print(f'PyTorch: {torch.__version__}')
print(f'CUDA Available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'CUDA Version: {torch.version.cuda}')
    print(f'Device: {torch.cuda.get_device_name(0)}')
    print(f'Memory: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB')
"
    deactivate
}

# Patch libcuda for Triton
ensure_cuda_linkable() {
    if [ -e /usr/lib/x86_64-linux-gnu/libcuda.so.1 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libcuda.so ]; then
        echo "Patching libcuda symlink..."
        ln -s /usr/lib/x86_64-linux-gnu/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so || true
    fi
}
export TRITON_CACHE_DIR=/opt/ComfyUI/triton-cache
mkdir -p "$TRITON_CACHE_DIR"

# Fix custom node dependencies
fix_custom_nodes_env() {
    echo "Applying ComfyUI custom node dependency fixes..."

    if [ -d "/opt/ComfyUI/venv" ]; then
        source /opt/ComfyUI/venv/bin/activate
        PYBIN="/opt/ComfyUI/venv/bin/python"
    else
        echo "WARNING: /opt/ComfyUI/venv not found; using system python."
        PYBIN="$(which python3 || which python)"
    fi

    set +e
    $PYBIN -m pip install -U pip setuptools wheel

    # Fix Gemini import
    $PYBIN -m pip uninstall -y google
    $PYBIN -m pip install -U google-genai google-auth google-auth-oauthlib

    # MingNodes deps
    if [ -f "/opt/ComfyUI/custom_nodes/ComfyUI-MingNodes/requirements.txt" ]; then
        $PYBIN -m pip install -r /opt/ComfyUI/custom_nodes/ComfyUI-MingNodes/requirements.txt
    fi
    $PYBIN -m pip install -U litelama

    # pyOpenSSL
    $PYBIN -m pip install -U pyOpenSSL

    # Gemini node requirements
    if [ -f "/opt/ComfyUI/custom_nodes/ComfyUI_Gemini_Expanded_API/requirements.txt" ]; then
        $PYBIN -m pip install -r /opt/ComfyUI/custom_nodes/ComfyUI_Gemini_Expanded_API/requirements.txt
    fi

    # Check for shadowing
    find /opt/ComfyUI/custom_nodes -maxdepth 3 -type d -name "google" -not -path "*/site-packages/*" -print 2>/dev/null \
      | sed '1q' | grep -q . && echo "WARNING: Local custom_nodes/**/google/ may shadow google-genai."

    # Sanity check
    $PYBIN - <<'PY'
import importlib.util, os, shutil, sys
def has(name): return importlib.util.find_spec(name) is not None
errors=[]
try:
    from google import genai  # noqa
except Exception as e:
    errors.append(("google.genai", str(e)))
if not has("litelama"):
    errors.append(("litelama","not importable"))
if errors:
    base="/opt/ComfyUI/custom_nodes"; q=os.path.join(base,"_QUARANTINE"); os.makedirs(q,exist_ok=True)
    offenders={"google.genai":"ComfyUI_Gemini_Expanded_API","litelama":"ComfyUI-MingNodes"}
    for key, folder in offenders.items():
        if any(key==e[0] for e in errors):
            src=os.path.join(base,folder)
            if os.path.isdir(src):
                dst=os.path.join(q,folder)
                try:
                    shutil.rmtree(dst,ignore_errors=True); shutil.move(src,dst)
                    print(f"Quarantined {folder} -> {dst}")
                except Exception as ex:
                    print(f"Failed to quarantine {folder}: {ex}")
    sys.exit(1)
print("Dependency sanity check OK")
PY
    set -e

    [ -n "$VIRTUAL_ENV" ] && deactivate || true
    echo "Custom node dependency fixes complete."
}

echo "Starting optimized ComfyUI environment..."

# Initialize services
generate_ssh_host_keys
mkdir -p /run/nginx /run/sshd /var/run/sshd
nginx
/usr/sbin/sshd



# Setup RunPod Uploader (tusd)
setup_runpod_uploader() {
    echo "Starting RunPod Uploader (tusd)..."
    mkdir -p /workspace/uploads
    nohup tusd -host 0.0.0.0 -port 8080 -upload-dir /workspace/uploads -hooks-dir /etc/tusd/hooks > /workspace/logs/tusd.log 2>&1 &
    echo "RunPod Uploader started on port 8080"
}

# Create download-models alias
create_downloader_alias() {
    # README says 'download-models', script installs 'download-model'
    ln -sf /usr/local/bin/download-model /usr/local/bin/download-models
    echo "Created 'download-models' alias"

    # Sync-up alias
    cp /scripts/sync_up.sh /usr/local/bin/sync-up
    chmod +x /usr/local/bin/sync-up
    echo "Created 'sync-up' alias"

    # Sweet Tea Studio control script
    cp /scripts/sweet_tea_control.sh /usr/local/bin/sweet-tea
    chmod +x /usr/local/bin/sweet-tea
    ln -sf /usr/local/bin/sweet-tea /usr/local/bin/restart-sweet-tea
    echo "Created 'sweet-tea' and 'restart-sweet-tea' commands"
}

# Setup tools
setup_code_server
setup_filebrowser
setup_runpod_uploader
create_download_helper
create_comfyui_helper
create_downloader_alias
setup_monitoring

# Checks and fixes
check_gpu_compatibility
ensure_cuda_linkable


# Check for updates
check_for_updates() {
    if [ "${DISABLE_AUTO_UPDATE}" = "true" ]; then
        echo "[update] Auto-update disabled by env var."
        return
    fi

    # If FROZEN_COMMIT was set to a specific hash at build time, do not update
    if [ -n "${FROZEN_COMMIT}" ] && [ "${FROZEN_COMMIT}" != "master" ]; then
        echo "[update] Image is pinned to commit ${FROZEN_COMMIT}. Skipping auto-update."
        return
    fi

    # Fix for "dubious ownership" error since repo is owned by 'comfy' user
    git config --global --add safe.directory /opt/ComfyUI

    echo "[update] Checking for ComfyUI updates..."
    cd /opt/ComfyUI
    
    # Check if we are behind
    git fetch origin
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse @{u})
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        echo "[update] Update found! Pulling latest changes..."
        git pull
        
        # Re-install requirements if they changed
        if git diff --name-only HEAD@{1} HEAD | grep -qE "requirements.txt|pyproject.toml"; then
            echo "[update] Dependencies changed. Installing..."
            source venv/bin/activate
            pip install -r requirements.txt
            deactivate
        fi
        echo "[update] ComfyUI updated to $(git rev-parse --short HEAD)"
    else
        echo "[update] ComfyUI is up to date."
    fi
}

# Sync from R2
# 1. Critical components (foreground) - MUST complete before starting services
# This syncs: scripts, custom_nodes, user, sweet_tea folders
r2_sync_critical

# 2. Heavy assets (background) - Start immediately after critical sync
# Can load in background while other services start
r2_sync_assets_async

# =============================================================================
# START SWEET TEA STUDIO
# Start after critical sync (which brings sweet_tea config)
# Run in foreground to ensure services are actually started before continuing
# =============================================================================
echo "[startup] Starting Sweet Tea Studio..."
if [ -f /scripts/setup_sweet_tea_studio.sh ]; then
    bash /scripts/setup_sweet_tea_studio.sh 2>&1 | tee /workspace/logs/sweet-tea-setup.log
    echo "[startup] Sweet Tea Studio setup complete."
else
    echo "[startup] WARNING: Sweet Tea Studio setup script not found at /scripts/setup_sweet_tea_studio.sh"
fi

# 3. Fix custom node environment (depends on critical sync)
fix_custom_nodes_env

# 4. Compile SageAttention (if needed) - Runs while assets download
# Setup SageAttention
cp /scripts/sageattention_setup.py /opt/ComfyUI/custom_nodes/00_enable_sageattention.py
install_or_verify_sageattention

# Check for updates (if not pinned)
check_for_updates

# Start ComfyUI
echo "Starting ComfyUI..."
/workspace/comfyui_control.sh start ${COMFYUI_EXTRA_ARGS}

# Keep container alive and show ComfyUI logs
# NOTE: Do NOT tail startup.log here, as it creates a feedback loop with the exec >(tee) redirection!
touch /workspace/logs/comfyui.log
tail -f /workspace/logs/comfyui.log