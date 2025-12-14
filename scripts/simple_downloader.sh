#!/bin/bash

#=========================================================
# Simple Parallel ComfyUI Downloader - Hardcoded Version
# (Amended to use token-in-URL for CivitAI downloads)
#=========================================================

# --- Configuration ---
# Set CIVITAI_API_KEY environment variable before running, e.g.:
# export CIVITAI_API_KEY="your_api_key_here"
CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"

# Directories aligned with our setup
BASE_PATH="/workspace/sweettea"
CHECKPOINTS="$BASE_PATH/models/checkpoints"
LORAS="$BASE_PATH/models/loras"
CONTROLNET="$BASE_PATH/models/controlnet"
VAE="$BASE_PATH/models/vae"
UPSCALE_MODELS="$BASE_PATH/models/upscale_models"
EMBEDDINGS="$BASE_PATH/models/embeddings"
CLIP="$BASE_PATH/models/clip"
CLIP_VISION="$BASE_PATH/models/clip_vision"
DIFFUSION_MODELS="$BASE_PATH/models/diffusion_models"
CUSTOM_NODE_DIR="$BASE_PATH/custom_nodes"

# Aria2c temporary input file
ARIA_INPUT_FILE="/tmp/aria2c_job_list.txt"

# Create Directories and clear old job list
mkdir -p "$CHECKPOINTS" "$LORAS" "$CONTROLNET" "$VAE" "$UPSCALE_MODELS" "$EMBEDDINGS" "$CLIP" "$CLIP_VISION" "$DIFFUSION_MODELS" "$CUSTOM_NODE_DIR"
> "$ARIA_INPUT_FILE" # Clear/create the file
echo "✅ Directories ensured and job list cleared."

# --- Hardcoded URLs from your models.conf ---
CIVITAI_CHECKPOINTS=(
    "https://civitai.com/api/download/models/1617798"
    "https://civitai.com/api/download/models/1240288"
)

CIVITAI_LORAS=(
    "https://civitai.com/models/1375170/wan-trans-and-futanari-cowgirl-i2v-t2v?modelVersionId=1553795"
    "https://civitai.com/models/1307155?modelVersionId=2073605"
    "https://civitai.com/models/1307155?modelVersionId=2083303"
    "https://civitai.com/models/1426284?modelVersionId=1612131"
    "https://huggingface.co/EdWalker/MasturbationCumshot/resolve/main/masturbation_cumshot_v1.1_e310.safetensors"
)

CIVITAI_EMBEDDINGS=(
    "https://civitai.com/api/download/models/9208"
)

HF_VAE=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
)

HF_UPSCALE_MODELS=(
    "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x-UltraSharp.pth"
)

HF_CONTROLNET=(
    "https://huggingface.co/xinsir/controlnet-openpose-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors"
    "https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors"
)

HF_CLIP=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
)

HF_DIFFUSION_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
)

HF_LORAS=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"
    "https://huggingface.co/GSennin/wanLoras/resolve/959f0cef3aacc300b2539c095a577d4bb657327b/wan-nsfw-e14-fixed.safetensors"
)

HF_CLIP_VISION=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
)

GIT_CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/WASasquatch/was-node-suite-comfyui"
    "https://github.com/rgthree/rgthree-comfy"
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts"
)

#===============================================
# SCRIPT LOGIC
#===============================================

# Append ?token=... (or &token=...) to CivitAI download URLs (solution #1)
tokenize_url() {
    local url="$1"
    if [[ "$url" == https://civitai.com/api/download/models/* ]]; then
        if [[ "$url" == *\?* ]]; then
            printf "%s&token=%s" "$url" "$CIVITAI_API_KEY"
        else
            printf "%s?token=%s" "$url" "$CIVITAI_API_KEY"
        fi
    else
        printf "%s" "$url"
    fi
}

# Build a nice output name for Hugging Face URLs:
# <repo>_<basename-of-file>, e.g. "wan2.1_vae.safetensors"
hf_out_name() {
  local url="$1"
  # Match: https://huggingface.co/<org>/<repo>/resolve/<rev>/<path/to/file>
  if [[ "$url" =~ ^https://huggingface\.co/[^/]+/([^/]+)/resolve/[^/]+/(.+)$ ]]; then
    local repo="${BASH_REMATCH[1]}"
    local pathpart="${BASH_REMATCH[2]}"
    local base="$(basename "$pathpart")"
    # Sanitize just in case
    repo="${repo//[^A-Za-z0-9._-]/_}"
    echo "${repo}_${base}"
  else
    echo ""
  fi
}

# --- Function to add a download job to the master list ---
add_to_queue() {
    local urls=("$@")
    local dest_dir="${!#}" # Last argument is the destination directory
    unset 'urls[${#urls[@]}-1]' # Remove dest_dir from urls array

    for url in "${urls[@]}"; do
        if [[ -n "$url" && "$url" != "PASTE"* && "$url" != "#"* ]]; then
            local resolved_url
            resolved_url="$(tokenize_url "$url")"
            echo "$resolved_url" >> "$ARIA_INPUT_FILE"
            echo "  dir=$dest_dir" >> "$ARIA_INPUT_FILE"

            # Force readable filenames for Hugging Face downloads
            if [[ "$resolved_url" == https://huggingface.co/* ]]; then
                local out_name
                out_name="$(hf_out_name "$resolved_url")"
                if [[ -n "$out_name" ]]; then
                    echo "  out=$out_name" >> "$ARIA_INPUT_FILE"
                fi
            fi
        fi
    done
}
# --- Build the master download list ---
echo "➡️ Building master download list..."

# Process all arrays
#add_to_queue "${CIVITAI_CHECKPOINTS[@]}" "$CHECKPOINTS"
add_to_queue "${CIVITAI_LORAS[@]}" "$LORAS"
#add_to_queue "${CIVITAI_EMBEDDINGS[@]}" "$EMBEDDINGS"
add_to_queue "${HF_VAE[@]}" "$VAE"
#add_to_queue "${HF_UPSCALE_MODELS[@]}" "$UPSCALE_MODELS"
#add_to_queue "${HF_CONTROLNET[@]}" "$CONTROLNET"
add_to_queue "${HF_CLIP[@]}" "$CLIP"
add_to_queue "${HF_LORAS[@]}" "$LORAS"
add_to_queue "${HF_CLIP_VISION[@]}" "$CLIP_VISION"
add_to_queue "${HF_DIFFUSION_MODELS[@]}" "$DIFFUSION_MODELS"

echo "✅ Master download list created at $ARIA_INPUT_FILE"

# Count downloads
TOTAL=$(grep -c "^http" "$ARIA_INPUT_FILE" 2>/dev/null || echo "0")
echo "Found $TOTAL files to download"

# --- Execute the entire download list at once ---
if [[ "$TOTAL" -gt 0 ]]; then
    echo "🚀 Unleashing aria2c on the entire job list. All downloads will now run in parallel."
    # --content-disposition: The crucial flag to get correct filenames
    aria2c -i "$ARIA_INPUT_FILE" \
        --console-log-level=warn \
        --content-disposition \
        --continue=true \
        --max-connection-per-server=16 \
        --split=16 \
        --min-split-size=1M \
        --max-concurrent-downloads=8 \
        --check-certificate=false
fi

# --- Clean up the temporary file ---
rm -f "$ARIA_INPUT_FILE"
echo "✅ Temporary job list removed."

# --- Clone Git Repos for Custom Nodes ---
echo "--- Cloning Custom Nodes ---"
for repo_url in "${GIT_CUSTOM_NODES[@]}"; do
    repo_name=$(basename "$repo_url" .git)
    if [ -d "$CUSTOM_NODE_DIR/$repo_name" ]; then
        echo "☑️ Custom node $repo_name already exists. Skipping."
    else
        echo "⬇️ Cloning custom node from $repo_url"
        git clone "$repo_url" "$CUSTOM_NODE_DIR/$repo_name"
    fi
done

echo "🎉 All assets installed!"

# Show stats
echo ""
echo "Model counts:"
find "$CHECKPOINTS" -type f 2>/dev/null | wc -l | xargs echo "  Checkpoints:"
find "$LORAS" -type f 2>/dev/null | wc -l | xargs echo "  LoRAs:"
find "$VAE" -type f 2>/dev/null | wc -l | xargs echo "  VAEs:"
find "$EMBEDDINGS" -type f 2>/dev/null | wc -l | xargs echo "  Embeddings:"
find "$UPSCALE_MODELS" -type f 2>/dev/null | wc -l | xargs echo "  Upscalers:"
find "$CONTROLNET" -type f 2>/dev/null | wc -l | xargs echo "  ControlNet:"
