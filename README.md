# Aider Project Template

Copy this directory to start a new aider-powered project with autonomous development loop.

## Prerequisites

**Required:**
- Ollama installed and running
- Qwen2.5-Coder 14B model: `ollama pull qwen2.5-coder:14b`
- Create 32k context model:
  ```bash
  cat > /tmp/Modelfile-qwen25-coder-32k << 'EOF'
  FROM qwen2.5-coder:14b
  PARAMETER num_ctx 32768
  PARAMETER temperature 0.7
  EOF
  ollama create qwen2.5-coder:32k -f /tmp/Modelfile-qwen25-coder-32k
  ```

**GPU:** RTX 5080 16GB or equivalent (requires ~10-11GB VRAM with f16 KV cache)

## Setup

1. Copy this folder to your project location
2. Edit `.aider.conf.yml`:
   - Update `test-cmd` with your build/test command
3. Edit `INSTRUCTIONS.md`:
   - Add your project tasks
   - Update build commands
4. Edit `dev.sh`:
   - Change `FILE_PATTERN` to match your language (*.rs, *.py, *.ts, etc.)
   - Adjust GPU settings if needed (CUDA_VISIBLE_DEVICES)
5. Initialize git: `git init && git add -A && git commit -m "Initial commit"`
6. Run: `./dev.sh`

## Files

- `.aider.conf.yml` - Aider configuration (model: qwen2.5-coder:32k, map-tokens: 8192, chat-history: 8192)
- `.aider.model.metadata.json` - **CRITICAL:** Token limits (must match model name in config!)
- `INSTRUCTIONS.md` - Project roadmap (tasks marked [x] or [ ])
- `dev.sh` - Continuous development loop with ollama management
- `.gitignore` - Git ignore patterns (includes dev.log)

## Current Configuration

**Model:** Qwen2.5-Coder 14B (32k context)
- 32 transformer layers, ~8.5GB base model (Q4_K_M quant)
- Context budget: 4k map + 8k chat + ~12k for files
- Can read 300-400 line files without truncation

**Ollama Settings (in dev.sh):**
- `OLLAMA_KV_CACHE_TYPE=q8_0` - Quantized KV cache for stability (prevents OOM when ollama auto-expands context)
- `OLLAMA_NUM_CTX=32768` - 32k context (note: ollama may auto-expand to ~52k)
- `OLLAMA_FLASH_ATTENTION=1` - Memory optimization
- `OLLAMA_GPU_LAYERS=999` - Load all 32 layers on GPU

**Aider Token Limits (.aider.model.metadata.json):**
- `max_input_tokens: 20480` - Caps context at 20k input (prevents overwhelming 8B model)
- `max_output_tokens: 4096` - Limits response length
- **CRITICAL:** Model name in this file MUST exactly match `.aider.conf.yml` or aider ignores limits → hallucinations

**VRAM Usage:** ~12GB with q8_0 KV cache at ~52k context (ollama auto-expansion)

**Known Issues:**
- Ollama ignores OLLAMA_NUM_CTX and auto-expands to ~52k despite 32k setting
- For strict context control, consider llama.cpp server or vLLM

## Example test-cmd by language

**Rust:**
```yaml
test-cmd: RUSTFLAGS="-D warnings" cargo build --release 2>&1
```

**Python:**
```yaml
test-cmd: python -m pytest 2>&1
```

**Node/TypeScript:**
```yaml
test-cmd: npm run build && npm test 2>&1
```

**Go:**
```yaml
test-cmd: go build ./... && go test ./... 2>&1
```
