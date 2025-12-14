# Model Downloader Quick Start Guide

## 🚀 Basic Usage

### Method 1: Using a Configuration File (Recommended)

1. **First-time setup - Create your config file:**
```bash
# Copy the sample configuration
cp /usr/local/share/models.conf.sample /workspace/models.conf

# Edit it with your Civitai API key and desired models
nano /workspace/models.conf
# or use Code Server at http://<pod-ip>:7777
```

2. **Add your Civitai API key:**
```bash
# Either edit the file directly, or set as environment variable:
export CIVITAI_API_KEY="your_api_key_here"

# To make it permanent:
echo 'export CIVITAI_API_KEY="your_api_key_here"' >> /workspace/.bashrc
```

3. **Run the downloader:**
```bash
# Download all models from your config
download-models --config /workspace/models.conf

# Or if models.conf is in /workspace (default location):
download-models
```

### Method 2: Quick Download Commands

```bash
# Show help
download-models --help

# Download essential models only (SDXL VAE, etc.)
download-models --essential

# Show model statistics (what you have)
download-models --stats
```

## 📝 Config File Format

Edit `/workspace/models.conf` to add your models:

```bash
# Your Civitai API Key (get from https://civitai.com/user/account)
CIVITAI_API_KEY="your_key_here"

# Checkpoints
CIVITAI_CHECKPOINTS=(
    "https://civitai.com/api/download/models/1617798"  # Model name/comment
    # Add more URLs here
)

# LoRAs
CIVITAI_LORAS=(
    "https://civitai.com/api/download/models/1387203"
    "https://civitai.com/api/download/models/1268294"
)

# VAE files
HF_VAE=(
    "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors"
)

# Upscale Models
HF_UPSCALE_MODELS=(
    "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x-UltraSharp.pth"
)

# Custom Nodes to install
GIT_CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/WASasquatch/was-node-suite-comfyui"
)
```

## 🔍 Finding Model URLs

### For Civitai:
1. Go to the model page on Civitai
2. Click the "Download" button
3. Right-click and "Copy Link Address"
4. The URL should look like: `https://civitai.com/api/download/models/XXXXXX`

### For HuggingFace:
1. Go to the model repository
2. Navigate to the "Files and versions" tab
3. Find the `.safetensors` or `.ckpt` file
4. Click the download icon (↓)
5. Right-click and "Copy Link Address"
6. The URL should look like: `https://huggingface.co/USER/REPO/resolve/main/FILE.safetensors`

## ⚡ Download Speed

The downloader uses aria2c with:
- **16 parallel connections** per file
- **8 simultaneous file downloads**
- **Automatic resume** if interrupted
- **10-16x faster** than wget

Typical speeds:
- Single checkpoint (7GB): ~30 seconds on good connection
- 10 LoRAs (5GB total): ~20 seconds
- Full model set (50GB): ~3-5 minutes

## 📊 Check Your Models

```bash
# See what models you have
download-models --stats

# This shows:
# - Number of checkpoints, LoRAs, VAEs, etc.
# - Total disk usage
# - Custom nodes installed
```

## 🔄 Updating Models

The downloader automatically skips files that already exist, so you can:

1. Add new model URLs to your config
2. Run `download-models` again
3. Only new models will be downloaded

## 🛠️ Troubleshooting

```bash
# If downloads fail, check:

# 1. Civitai API key is set
echo $CIVITAI_API_KEY

# 2. Network connectivity
ping civitai.com

# 3. Disk space
df -h /workspace

# 4. View download log
tail -f /workspace/logs/downloads.log

# 5. Test with a single model
download-models --essential
```

## 💡 Pro Tips

1. **First time setup:** Run with `--essential` first to get basic models quickly
2. **Organize your config:** Comment each URL with the model name
3. **Backup your config:** `cp /workspace/models.conf /workspace/models.conf.backup`
4. **Custom nodes:** They auto-install dependencies from requirements.txt

## Example First-Time Setup

```bash
# 1. Set your API key (get from https://civitai.com/user/account)
export CIVITAI_API_KEY="your_api_key_here"

# 2. Create config with your models
cat > /workspace/models.conf << 'EOF'
CIVITAI_API_KEY="${CIVITAI_API_KEY}"

CIVITAI_CHECKPOINTS=(
    "https://civitai.com/api/download/models/1617798"  # Hassaku XL
)

CIVITAI_LORAS=(
    "https://civitai.com/api/download/models/1387203"  # B-mix
)

HF_VAE=(
    "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors"
)

HF_UPSCALE_MODELS=(
    "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x-UltraSharp.pth"
)

GIT_CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/WASasquatch/was-node-suite-comfyui"
)
EOF

# 3. Run downloader
download-models --config /workspace/models.conf

# 4. Check results
download-models --stats
```