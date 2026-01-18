#!/bin/bash
# Continuous development script
# Edit GPU_UUID and TEST_CMD for your project

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CMD="echo 'TODO: set your test command'"  # e.g., "RUSTFLAGS='-D warnings' cargo build --release"
MODEL="qwen3-30b-aider:latest"  # Your ollama model name
INSTRUCTIONS_FILE="INSTRUCTIONS.md"  # Your roadmap/instructions file

# GPU Configuration - use UUID for stability (find with: nvidia-smi -L)
# Leave empty to use all GPUs, or set to specific UUID like: GPU-707f560b-e5d9-3fea-9af2-c6dd2b77abbe
GPU_UUID=""

if [ -n "$GPU_UUID" ]; then
    export CUDA_VISIBLE_DEVICES="$GPU_UUID"
fi
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export OLLAMA_NUM_CTX=12288

cd "$PROJECT_DIR"

echo "Starting continuous development..."
echo "Press Ctrl+C to stop"
echo ""

# Kill any existing ollama/aider processes and reap zombies
echo "Cleaning up any existing processes..."
pkill -9 -f "ollama" 2>/dev/null
pkill -9 -f "aider" 2>/dev/null

# Reap any zombie children from this shell
wait 2>/dev/null

# Wait for live (non-zombie) processes to die
for i in {1..10}; do
    LIVE_OLLAMA=$(pgrep -f "ollama" | xargs -r ps -o pid=,state= -p 2>/dev/null | grep -v " Z" | wc -l)
    if [ "$LIVE_OLLAMA" -eq 0 ]; then
        break
    fi
    echo "Waiting for $LIVE_OLLAMA ollama process(es) to terminate..."
    pkill -9 -f "ollama" 2>/dev/null
    sleep 1
done

# Orphan any remaining zombies by killing their parent shells (stopped dev.sh instances)
ZOMBIE_COUNT=$(ps aux | grep -E 'ollama|aider' | grep ' Z ' | wc -l)
if [ "$ZOMBIE_COUNT" -gt 0 ]; then
    echo "Cleaning up $ZOMBIE_COUNT zombie process(es)..."
    ps aux | grep 'dev.sh' | grep ' T ' | awk '{print $2}' | xargs -r kill -9 2>/dev/null
    sleep 1
fi

# Start fresh ollama instance
echo "Starting ollama..."
ollama serve &>/dev/null &
sleep 3

# Wait for ollama to be ready
echo "Waiting for ollama to be ready..."
for i in {1..30}; do
    if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
        echo "Ollama is ready."
        break
    fi
    sleep 1
done

# Function to load model with timeout and retries
load_model() {
    local max_attempts=3
    local timeout_secs=120

    for attempt in $(seq 1 $max_attempts); do
        echo "Loading model into VRAM (attempt $attempt/$max_attempts)..."

        # Use timeout on curl to prevent hanging
        if timeout $timeout_secs curl -s http://localhost:11434/api/generate -d "{
          \"model\": \"$MODEL\",
          \"prompt\": \"hi\",
          \"stream\": false,
          \"options\": {\"num_predict\": 1}
        }" >/dev/null 2>&1; then
            echo "Model loaded successfully."
            return 0
        else
            echo "Model load failed or timed out."
            if [ $attempt -lt $max_attempts ]; then
                echo "Restarting ollama and retrying..."
                pkill -9 -f "ollama" 2>/dev/null
                wait 2>/dev/null
                sleep 2
                ollama serve &>/dev/null &
                sleep 3
                # Wait for ollama API
                for i in {1..30}; do
                    if curl -s --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
                        break
                    fi
                    sleep 1
                done
            fi
        fi
    done

    echo "ERROR: Failed to load model after $max_attempts attempts"
    return 1
}

# Function to check if ollama is responsive
check_ollama_health() {
    curl -s --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1
}

# Load the model
if ! load_model; then
    echo "Could not load model. Exiting."
    exit 1
fi
echo ""

SESSION=0
STUCK_COUNT=0

while true; do
    SESSION=$((SESSION + 1))
    COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    DONE=$(grep -c "\[x\]" "$INSTRUCTIONS_FILE" 2>/dev/null || echo "0")
    TODO=$(grep -c "\[ \]" "$INSTRUCTIONS_FILE" 2>/dev/null || echo "0")

    # Get next 3 unchecked items
    NEXT_TASKS=$(grep -m3 "\[ \]" "$INSTRUCTIONS_FILE" | sed 's/- \[ \] /  - /')

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ Session: $SESSION | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "║ Commits: $COMMITS | Done: $DONE | Todo: $TODO"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # CHECK BUILD STATUS - tell aider about errors if any
    echo "Checking build status..."
    BUILD_PRE_CHECK=$($TEST_CMD 2>&1)
    BUILD_ERRORS=$(echo "$BUILD_PRE_CHECK" | tail -30)

    if echo "$BUILD_PRE_CHECK" | grep -qi "error\|failed"; then
        echo "⚠ Build has errors - telling aider to fix them first..."
        BUILD_STATUS_MSG="
URGENT: The build is currently BROKEN. Fix these errors FIRST before doing anything else:

\`\`\`
$BUILD_ERRORS
\`\`\`

After fixing, run the build command to verify.
"
    else
        echo "✓ Build OK"
        BUILD_STATUS_MSG=""
    fi

    # Pre-flight check: ensure ollama is healthy before starting aider
    if ! check_ollama_health; then
        echo "⚠ Ollama not responding, restarting..."
        pkill -9 -f "ollama" 2>/dev/null
        wait 2>/dev/null
        sleep 2
        ollama serve &>/dev/null &
        sleep 3
        if ! load_model; then
            echo "Failed to restart ollama, skipping this session..."
            sleep 5
            continue
        fi
    fi

    # Don't pre-load source files - let aider discover via repo map
    # Use timeout to prevent indefinite hangs (15 minutes max per session)
    timeout 900 aider \
        "$INSTRUCTIONS_FILE" \
        --message "
$BUILD_STATUS_MSG
Read $INSTRUCTIONS_FILE. Work through unchecked [ ] items.

NEXT TASKS:
$NEXT_TASKS

CRITICAL RULES:
1. You MUST actually create files using the edit blocks - do not just describe what you would do
2. After EVERY change, run the build/test command
3. Code must pass ALL tests with ZERO warnings before marking [x]
4. If creating a new module, BOTH create the file AND add it to the main file

WORKFLOW:
1. Create/edit files with COMPLETE code (not snippets)
2. RUN THE BUILD/TEST - do not skip this
3. Fix ALL errors and warnings
4. Only mark [x] when tests pass
5. Commit your changes

Use WHOLE edit format - output complete file contents.
"

    EXIT_CODE=$?

    # If aider timed out (exit 124) or crashed, restart ollama to clear VRAM
    if [ $EXIT_CODE -eq 124 ]; then
        echo ""
        echo "⚠ Aider session timed out (15 min limit). Likely ollama hung."
        echo "Killing aider and restarting ollama..."
        pkill -9 -f "aider" 2>/dev/null
    fi

    if [ $EXIT_CODE -ne 0 ]; then
        echo ""
        echo "Aider exited with code $EXIT_CODE. Restarting ollama..."

        # Kill all ollama processes and reap zombies
        pkill -9 -f "ollama" 2>/dev/null
        wait 2>/dev/null
        sleep 2

        # Wait for live processes to die (max 10 seconds)
        for i in {1..10}; do
            LIVE_OLLAMA=$(pgrep -f "ollama" | xargs -r ps -o pid=,state= -p 2>/dev/null | grep -v " Z" | wc -l)
            [ "$LIVE_OLLAMA" -eq 0 ] && break
            echo "Waiting for $LIVE_OLLAMA ollama process(es)..."
            pkill -9 -f "ollama" 2>/dev/null
            sleep 1
        done

        # Start fresh instance and load model using the robust function
        ollama serve &>/dev/null &
        sleep 3
        load_model
    fi

    COMMITS_AFTER=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    NEW_COMMITS=$((COMMITS_AFTER - COMMITS))

    # Check for uncommitted changes (sign of hallucination - aider made partial changes)
    DIRTY_FILES=$(git status --porcelain 2>/dev/null | wc -l)

    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ Session $SESSION complete (exit: $EXIT_CODE)"
    echo "│ New commits: $NEW_COMMITS | Uncommitted files: $DIRTY_FILES"
    echo "└─────────────────────────────────────────────────────────────┘"

    # If there are dirty files, check if they compile
    if [ $DIRTY_FILES -gt 0 ]; then
        echo "Found uncommitted changes, testing build..."
        if $TEST_CMD 2>&1; then
            echo "Build passes! Committing aider's uncommitted work..."
            git add -A
            git commit -m "Auto-commit: aider changes that compile"
            NEW_COMMITS=1
        else
            echo "Build fails with uncommitted changes - reverting hallucinated code..."
            git checkout -- .
            git clean -fd
        fi
    fi

    if [ $NEW_COMMITS -gt 0 ]; then
        echo ""
        echo "Recent commits:"
        git log --oneline -n $NEW_COMMITS
        echo ""
        echo "Pushing to origin..."
        git push
        STUCK_COUNT=0
    else
        STUCK_COUNT=$((STUCK_COUNT + 1))
        echo "No progress made (stuck count: $STUCK_COUNT)"

        # Call Claude Code for help after 2 failed attempts
        if [ $STUCK_COUNT -ge 2 ]; then
            echo ""
            echo "════════════════════════════════════════════════════════════"
            echo "Calling Claude Code to fix the issue..."
            echo "════════════════════════════════════════════════════════════"

            BUILD_OUTPUT=$($TEST_CMD 2>&1 | tail -50)

            # Snapshot git state before Claude runs (for hallucination detection)
            COMMIT_BEFORE=$(git rev-parse HEAD 2>/dev/null)
            DIRTY_BEFORE=$(git status --porcelain 2>/dev/null | md5sum)

            # Run Claude non-interactively with --print and skip permissions
            # --dangerously-skip-permissions allows file edits and bash without prompts
            timeout 300 claude --print --dangerously-skip-permissions "
The local AI is stuck on this project. Please help.

Current task from $INSTRUCTIONS_FILE:
$NEXT_TASKS

Last build output:
$BUILD_OUTPUT

Please:
1. Read the relevant source files
2. Create or fix the files needed for the current task
3. Run the build/test command to verify
4. Fix any errors until build passes
5. Update $INSTRUCTIONS_FILE to mark [x] the completed task
6. Commit and push the changes

Work autonomously until the task is complete.
"
            CLAUDE_EXIT=$?

            # Verify Claude actually made changes (anti-hallucination check)
            COMMIT_AFTER=$(git rev-parse HEAD 2>/dev/null)
            DIRTY_AFTER=$(git status --porcelain 2>/dev/null | md5sum)

            if [ "$COMMIT_BEFORE" = "$COMMIT_AFTER" ] && [ "$DIRTY_BEFORE" = "$DIRTY_AFTER" ]; then
                echo ""
                echo "⚠ Claude claimed to work but made NO actual changes!"
                echo "  Files unchanged, no commits, no dirty files."
                echo "  This was likely a hallucination. Continuing..."
                # Don't reset stuck count - let it try again or escalate
            else
                echo ""
                echo "✓ Claude made actual changes."
                # Check if changes compile
                DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l)
                if [ "$DIRTY_COUNT" -gt 0 ]; then
                    echo "Testing uncommitted changes..."
                    if $TEST_CMD 2>&1; then
                        echo "✓ Build passes! Auto-committing Claude's work..."
                        git add -A
                        git commit -m "Auto-commit: Claude Code changes that compile"
                        git push
                    else
                        echo "✗ Build FAILS - reverting Claude's broken code..."
                        git checkout -- .
                        git clean -fd 2>/dev/null
                    fi
                fi
                STUCK_COUNT=0
            fi
        fi
    fi

    # Periodic sanity check every 5 sessions (uses haiku to keep costs low)
    if [ $((SESSION % 5)) -eq 0 ] && [ $SESSION -gt 0 ]; then
        echo ""
        echo "Running periodic sanity check (session $SESSION)..."
        BUILD_CHECK=$($TEST_CMD 2>&1)
        if echo "$BUILD_CHECK" | grep -qi "error\|failed"; then
            echo "⚠ Sanity check found errors - calling Claude haiku to fix..."

            # Run haiku non-interactively
            timeout 120 claude --print --dangerously-skip-permissions --model haiku "
Quick sanity check. Build/test is failing:

$BUILD_CHECK

Please fix any issues and ensure build passes. Be brief.
"
            # Verify and commit haiku's changes
            DIRTY_HAIKU=$(git status --porcelain 2>/dev/null | wc -l)
            if [ "$DIRTY_HAIKU" -gt 0 ]; then
                if $TEST_CMD 2>&1; then
                    echo "✓ Haiku fixed the build!"
                    git add -A
                    git commit -m "Auto-commit: Claude haiku build fix"
                    git push
                else
                    echo "✗ Haiku's fix didn't work - reverting..."
                    git checkout -- .
                    git clean -fd 2>/dev/null
                fi
            fi
        else
            echo "✓ Sanity check passed"
        fi
    fi

    # Stop when all tasks complete
    if [ "$TODO" -eq 0 ]; then
        echo "All tasks complete!"
        break
    fi

    echo ""
    sleep 1
done
