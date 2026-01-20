# Aider Project Template

Copy this directory to start a new aider-powered project with autonomous development loop.

## Prerequisites

**Required:**
- Ollama installed and running
- Llama 3.1 8B model: `ollama pull llama3.1:8b`
- Create 32k context model:
  ```bash
  cat > /tmp/Modelfile-llama31-32k << 'EOF'
  FROM llama3.1:8b
  PARAMETER num_ctx 32768
  PARAMETER temperature 0.7
  EOF
  ollama create llama3.1:32k -f /tmp/Modelfile-llama31-32k
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

- `.aider.conf.yml` - Aider configuration (model: llama3.1:32k, map-tokens: 8192, chat-history: 8192)
- `INSTRUCTIONS.md` - Project roadmap (tasks marked [x] or [ ])
- `dev.sh` - Continuous development loop with ollama management
- `.gitignore` - Git ignore patterns (includes dev.log)

## Current Configuration

**Model:** Llama 3.1 8B (32k context)
- 32 transformer layers, ~4.9GB base model (Q4_K_M quant)
- Context budget: 8k map + 8k chat + ~15k for files
- Can read 300-400 line files without truncation

**Ollama Settings (in dev.sh):**
- `OLLAMA_KV_CACHE_TYPE=f16` - Maximum quality KV cache
- `OLLAMA_NUM_CTX=32768` - 32k context (note: ollama may auto-expand to ~47k)
- `OLLAMA_FLASH_ATTENTION=1` - Memory optimization
- `OLLAMA_GPU_LAYERS=999` - Load all 32 layers on GPU

**VRAM Usage:** ~10-11GB with f16 KV cache at 32k context

**Known Issue:** Ollama ignores OLLAMA_NUM_CTX and may auto-expand context. This is a known ollama quirk. For strict context control, consider llama.cpp server or vLLM.

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
