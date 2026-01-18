# Aider Project Template

Copy this directory to start a new aider-powered project.

## Setup

1. Copy this folder to your project location
2. Edit `.aider.conf.yml`:
   - Update `test-cmd` with your build/test command
3. Edit `INSTRUCTIONS.md`:
   - Add your project tasks
   - Update build commands
4. Edit `dev.sh`:
   - Change `FILE_PATTERN` to match your language (*.rs, *.py, *.ts, etc.)
5. Initialize git: `git init && git add -A && git commit -m "Initial commit"`
6. Run: `./dev.sh`

## Files

- `.aider.conf.yml` - Aider configuration
- `INSTRUCTIONS.md` - Project roadmap (tasks marked [x] or [ ])
- `dev.sh` - Continuous development loop
- `.gitignore` - Git ignore patterns

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
