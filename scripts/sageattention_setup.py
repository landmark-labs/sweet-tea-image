import logging
import torch
import atexit

logger = logging.getLogger(__name__)

# simple counters so you can confirm usage in logs
_used = 0
_fallback = 0

def initialize_sageattention3():
    """
    Install a wrapper around PyTorch SDPA for SageAttention3.
    We lazily import SageAttention3 on first GPU half/bfloat16 call.
    If anything fails, we fall back to vanilla SDPA.
    """
    original_sdpa = torch.nn.functional.scaled_dot_product_attention

    def sage3_wrapper(q, k, v, attn_mask=None, dropout_p=0.0, is_causal=False, scale=None):
        global _used, _fallback
        try:
            # Only attempt on CUDA half/bfloat16 tensors
            if not (torch.cuda.is_available() and q.is_cuda and q.dtype in (torch.float16, torch.bfloat16)):
                _fallback += 1
                return original_sdpa(q, k, v, attn_mask=attn_mask, dropout_p=dropout_p, is_causal=is_causal, scale=scale)

            major, _ = torch.cuda.get_device_capability()
            if major < 8:
                _fallback += 1
                logger.info(f"SageAttention3 skipped (compute capability {major}.x < 8.0).")
                return original_sdpa(q, k, v, attn_mask=attn_mask, dropout_p=dropout_p, is_causal=is_causal, scale=scale)

            # SageAttention3 FP4 attention doesn't support attn_mask or dropout
            # Fall back to SDPA for those cases
            if attn_mask is not None or dropout_p > 0.0:
                _fallback += 1
                return original_sdpa(q, k, v, attn_mask=attn_mask, dropout_p=dropout_p, is_causal=is_causal, scale=scale)

            # Lazy import: this is where CUDA kernels may compile
            from sageattn3 import sageattn3_blackwell
            _used += 1
            return sageattn3_blackwell(q, k, v, is_causal=is_causal, pv_accum_dtype="fp32")
        except Exception as e:
            _fallback += 1
            logger.info(f"SageAttention3 unavailable ({e}); falling back to SDPA.")
            return original_sdpa(q, k, v, attn_mask=attn_mask, dropout_p=dropout_p, is_causal=is_causal, scale=scale)

    torch.nn.functional.scaled_dot_product_attention = sage3_wrapper
    logger.info("SageAttention3 wrapper installed (lazy import).")
    return True

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

# Auto-run so ComfyUI gets the wrapper at startup
initialize_sageattention3()

@atexit.register
def _report():
    logger.info(f"SageAttention3 stats: used={_used}, fallback={_fallback}")
