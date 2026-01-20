#!/bin/bash
# Continuous development script
# Edit the CONFIGURATION section for your project

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === CONFIGURATION ===
TEST_CMD="echo 'TODO: set your test command'"  # e.g., "RUSTFLAGS='-D warnings' cargo build --release"
MODEL="llama3.1:24k"  # Llama 3.1 8B with 24k context - efficient and capable
INSTRUCTIONS_FILE="INSTRUCTIONS.md"  # Your roadmap/instructions file
PROJECT_NAME="MyProject"  # Used in planning session prompts

# GPU Configuration - use UUID for stability (find with: nvidia-smi -L)
# Leave empty to use all GPUs, or set to specific UUID like: GPU-707f560b-e5d9-3fea-9af2-c6dd2b77abbe
GPU_UUID=""

# === DEBUG / LOGGING ===
DEBUG=1
LOG_FILE="dev.log"
START_TIME=$(date +%s)

# Configuration intervals
PLANNING_INTERVAL=10  # Run planning session every N sessions
SANITY_CHECK_INTERVAL=5  # Run sanity check every N sessions

# Stats counters
STAT_SESSIONS=0
STAT_OLLAMA_RESTARTS=0
STAT_MODEL_LOAD_FAILURES=0
STAT_AIDER_TIMEOUTS=0
STAT_AIDER_CRASHES=0
STAT_HEALTH_CHECK_FAILURES=0
STAT_BUILD_FAILURES=0
STAT_HALLUCINATIONS=0
STAT_MISSING_FILES=0
STAT_MISPLACED_FILES=0
STAT_STUCK_EVENTS=0
STAT_CLAUDE_CALLS=0
STAT_CLAUDE_HALLUCINATIONS=0
STAT_PLANNING_SESSIONS=0
STAT_REVERTS=0
STAT_COMMITS=0

# Log function - writes to file
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local entry="[$timestamp] [$level] $msg"

    if [ "$DEBUG" -eq 1 ]; then
        echo "$entry" >> "$LOG_FILE"
    fi
}

# Print summary stats
print_stats() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "                    SESSION SUMMARY"
    echo "════════════════════════════════════════════════════════════"
    echo "Runtime: ${hours}h ${minutes}m"
    echo "Sessions completed: $STAT_SESSIONS"
    echo ""
    echo "Issues encountered:"
    echo "  Ollama restarts:        $STAT_OLLAMA_RESTARTS"
    echo "  Model load failures:    $STAT_MODEL_LOAD_FAILURES"
    echo "  Health check failures:  $STAT_HEALTH_CHECK_FAILURES"
    echo "  Aider timeouts:         $STAT_AIDER_TIMEOUTS"
    echo "  Aider crashes:          $STAT_AIDER_CRASHES"
    echo "  Build failures:         $STAT_BUILD_FAILURES"
    echo "  Hallucinations:         $STAT_HALLUCINATIONS"
    echo "  Missing file claims:    $STAT_MISSING_FILES"
    echo "  Misplaced files fixed:  $STAT_MISPLACED_FILES"
    echo "  Code reverts:           $STAT_REVERTS"
    echo "  Stuck events:           $STAT_STUCK_EVENTS"
    echo ""
    echo "Claude usage:"
    echo "  Claude calls:           $STAT_CLAUDE_CALLS"
    echo "  Claude hallucinations:  $STAT_CLAUDE_HALLUCINATIONS"
    echo "  Planning sessions:      $STAT_PLANNING_SESSIONS"
    echo ""
    echo "Progress:"
    echo "  Commits made:           $STAT_COMMITS"
    echo "════════════════════════════════════════════════════════════"

    log "INFO" "=== SESSION SUMMARY ==="
    log "INFO" "Runtime: ${hours}h ${minutes}m, Sessions: $STAT_SESSIONS"
    log "INFO" "Ollama restarts: $STAT_OLLAMA_RESTARTS, Model failures: $STAT_MODEL_LOAD_FAILURES"
    log "INFO" "Aider timeouts: $STAT_AIDER_TIMEOUTS, Aider crashes: $STAT_AIDER_CRASHES"
    log "INFO" "Build failures: $STAT_BUILD_FAILURES, Reverts: $STAT_REVERTS"
    log "INFO" "Stuck events: $STAT_STUCK_EVENTS, Claude calls: $STAT_CLAUDE_CALLS"
    log "INFO" "Planning sessions: $STAT_PLANNING_SESSIONS, Commits: $STAT_COMMITS"
}

# Cleanup on exit
cleanup() {
    echo ""
    echo "Shutting down..."
    log "INFO" "Shutdown requested"
    print_stats
    pkill -9 -f "ollama" 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

# === GPU SETUP ===
# For multi-GPU systems, isolate to best GPU
# Example: export GPU_UUID=1 for RTX 5080 on dual-GPU system
if [ -n "$GPU_UUID" ]; then
    export CUDA_DEVICE_ORDER=PCI_BUS_ID
    export CUDA_VISIBLE_DEVICES="$GPU_UUID"
    export GPU_DEVICE_ORDINAL="$GPU_UUID"
fi
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0  # q8_0 for quality (use q4_0 if VRAM constrained)
export OLLAMA_GPU_LAYERS=999  # Auto-detect optimal GPU layer count
export OLLAMA_KEEP_ALIVE=-1  # Keep model loaded between requests
# Note: 64k context configured in model itself, not via OLLAMA_NUM_CTX

cd "$PROJECT_DIR"

# Initialize log file
echo "" >> "$LOG_FILE"
log "INFO" "========================================"
log "INFO" "dev.sh started for $PROJECT_NAME"
log "INFO" "========================================"

echo "Starting continuous development for $PROJECT_NAME..."
echo "Press Ctrl+C to stop"
echo "Log file: $LOG_FILE"
echo ""

# Kill any existing ollama/aider processes and reap zombies
echo "Cleaning up any existing processes..."
pkill -9 -f "ollama" 2>/dev/null
pkill -9 -f "aider" 2>/dev/null
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

# Kill stopped dev.sh instances holding zombies
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
        log "INFO" "Model load attempt $attempt/$max_attempts"

        if timeout $timeout_secs curl -s http://localhost:11434/api/generate -d "{
          \"model\": \"$MODEL\",
          \"prompt\": \"hi\",
          \"stream\": false,
          \"options\": {\"num_predict\": 1}
        }" >/dev/null 2>&1; then
            echo "Model loaded successfully."
            log "INFO" "Model loaded successfully"
            return 0
        else
            echo "Model load failed or timed out."
            log "WARN" "Model load failed/timed out (attempt $attempt)"
            STAT_MODEL_LOAD_FAILURES=$((STAT_MODEL_LOAD_FAILURES + 1))
            if [ $attempt -lt $max_attempts ]; then
                echo "Restarting ollama and retrying..."
                log "INFO" "Restarting ollama for model load retry"
                STAT_OLLAMA_RESTARTS=$((STAT_OLLAMA_RESTARTS + 1))
                pkill -9 -f "ollama" 2>/dev/null
                wait 2>/dev/null
                sleep 2
                ollama serve &>/dev/null &
                sleep 3
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
    log "ERROR" "Failed to load model after $max_attempts attempts"
    return 1
}

# Function to check if ollama is responsive
check_ollama_health() {
    curl -s --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1
}

# Load the model
if ! load_model; then
    echo "Could not load model. Exiting."
    log "ERROR" "Initial model load failed, exiting"
    exit 1
fi
echo ""

SESSION=0
STUCK_COUNT=0

while true; do
    SESSION=$((SESSION + 1))
    STAT_SESSIONS=$((STAT_SESSIONS + 1))
    COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    DONE=$(grep -c "\[x\]" "$INSTRUCTIONS_FILE" 2>/dev/null || echo "0")
    TODO=$(grep -c "\[ \]" "$INSTRUCTIONS_FILE" 2>/dev/null || echo "0")

    # Get next 3 unchecked items
    NEXT_TASKS=$(grep -m3 "\[ \]" "$INSTRUCTIONS_FILE" | sed 's/- \[ \] /  - /')
    NEXT_TASK_ONELINE=$(echo "$NEXT_TASKS" | head -1 | sed 's/^[[:space:]]*//')

    log "INFO" "--- Session $SESSION started ---"
    log "INFO" "Task: $NEXT_TASK_ONELINE"
    log "INFO" "Progress: Done=$DONE, Todo=$TODO"

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ Session: $SESSION | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "║ Commits: $COMMITS | Done: $DONE | Todo: $TODO"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # CHECK BUILD STATUS - tell aider about errors if any
    echo "Checking build status..."
    BUILD_PRE_CHECK=$($TEST_CMD 2>&1)
    # Keep error output small to avoid OOM (15 lines max)
    BUILD_ERRORS=$(echo "$BUILD_PRE_CHECK" | grep -iE "error|failed|warning" | head -15)

    if echo "$BUILD_PRE_CHECK" | grep -qi "error\|failed"; then
        echo "⚠ Build has errors - telling aider to fix them first..."
        log "WARN" "Build broken at session start"
        STAT_BUILD_FAILURES=$((STAT_BUILD_FAILURES + 1))
        BUILD_STATUS_MSG="
URGENT: The build is currently BROKEN. Fix these errors FIRST before doing anything else:

\`\`\`
$BUILD_ERRORS
\`\`\`

After fixing, run the build command to verify.
"
    else
        echo "✓ Build OK"
        log "INFO" "Build OK at session start"
        BUILD_STATUS_MSG=""
    fi

    # Pre-flight check: ensure ollama is healthy before starting aider
    if ! check_ollama_health; then
        echo "⚠ Ollama not responding, restarting..."
        log "WARN" "Health check failed, restarting ollama"
        STAT_HEALTH_CHECK_FAILURES=$((STAT_HEALTH_CHECK_FAILURES + 1))
        STAT_OLLAMA_RESTARTS=$((STAT_OLLAMA_RESTARTS + 1))
        pkill -9 -f "ollama" 2>/dev/null
        wait 2>/dev/null
        sleep 2
        ollama serve &>/dev/null &
        sleep 3
        if ! load_model; then
            echo "Failed to restart ollama, skipping this session..."
            log "ERROR" "Failed to restart ollama, skipping session"
            sleep 5
            continue
        fi
    fi

    # Run aider with 15-minute timeout
    # 8B model with 64k context budget:
    #   - 8k map tokens (repo structure + summaries)
    #   - 8k chat history (conversation memory)
    #   - ~31k available for file content
    # No file size limits - can read entire large files
    log "INFO" "Starting aider session"
    timeout 900 aider \
        "$INSTRUCTIONS_FILE" \
        --model "ollama/$MODEL" \
        --no-stream \
        --yes \
        --auto-commits \
        --map-tokens 6144 \
        --max-chat-history-tokens 6144 \
        --env-file /dev/null \
        --encoding utf-8 \
        --show-model-warnings \
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
1. If creating a new module, create the .rs file FIRST using edit blocks
2. THEN add the mod statement to lib.rs
3. RUN THE BUILD/TEST - do not skip this
4. Fix ALL errors and warnings
5. Only mark [x] when tests pass
6. Commit your changes

CRITICAL: Do NOT add 'mod foo;' to lib.rs without FIRST creating src/foo.rs!
You MUST use edit blocks to create files - describing what you would write is NOT enough.

FILE LOCATION: All .rs module files MUST be in the src/ directory, not in the project root!
  CORRECT: src/mymodule.rs
  WRONG: mymodule.rs (in root)

Use WHOLE edit format - output complete file contents.
"

    EXIT_CODE=$?
    log "INFO" "Aider exited with code $EXIT_CODE"

    # If aider timed out (exit 124) or crashed, restart ollama
    if [ $EXIT_CODE -eq 124 ]; then
        echo ""
        echo "⚠ Aider session timed out (15 min limit). Likely ollama hung."
        echo "Killing aider and restarting ollama..."
        log "WARN" "Aider timed out (15 min limit)"
        STAT_AIDER_TIMEOUTS=$((STAT_AIDER_TIMEOUTS + 1))
        pkill -9 -f "aider" 2>/dev/null
    fi

    if [ $EXIT_CODE -ne 0 ]; then
        echo ""
        echo "Aider exited with code $EXIT_CODE. Restarting ollama..."

        if [ $EXIT_CODE -ne 124 ]; then
            log "WARN" "Aider crashed with exit code $EXIT_CODE"
            STAT_AIDER_CRASHES=$((STAT_AIDER_CRASHES + 1))
        fi

        STAT_OLLAMA_RESTARTS=$((STAT_OLLAMA_RESTARTS + 1))
        pkill -9 -f "ollama" 2>/dev/null
        wait 2>/dev/null
        sleep 2

        for i in {1..10}; do
            LIVE_OLLAMA=$(pgrep -f "ollama" | xargs -r ps -o pid=,state= -p 2>/dev/null | grep -v " Z" | wc -l)
            [ "$LIVE_OLLAMA" -eq 0 ] && break
            echo "Waiting for $LIVE_OLLAMA ollama process(es)..."
            pkill -9 -f "ollama" 2>/dev/null
            sleep 1
        done

        ollama serve &>/dev/null &
        sleep 3
        load_model
    fi

    COMMITS_AFTER=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    NEW_COMMITS=$((COMMITS_AFTER - COMMITS))
    DIRTY_FILES=$(git status --porcelain 2>/dev/null | wc -l)

    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ Session $SESSION complete (exit: $EXIT_CODE)"
    echo "│ New commits: $NEW_COMMITS | Uncommitted files: $DIRTY_FILES"
    echo "└─────────────────────────────────────────────────────────────┘"

    # If there are dirty files, check if they compile
    if [ $DIRTY_FILES -gt 0 ]; then
        echo "Found uncommitted changes, testing build..."
        log "INFO" "Testing $DIRTY_FILES uncommitted files"

        # AUTO-FIX: Move misplaced .rs files from root to src/ (common aider mistake)
        if [ -f src/lib.rs ]; then
            for mod_name in $(grep -oP '(?<=^mod )\w+(?=;)' src/lib.rs 2>/dev/null); do
                if [ -f "${mod_name}.rs" ] && [ ! -f "src/${mod_name}.rs" ]; then
                    echo "⚠ Auto-fixing: Moving ${mod_name}.rs to src/${mod_name}.rs"
                    log "WARN" "Auto-fixing misplaced file: ${mod_name}.rs -> src/${mod_name}.rs"
                    mv "${mod_name}.rs" "src/${mod_name}.rs"
                    STAT_MISPLACED_FILES=$((STAT_MISPLACED_FILES + 1))
                fi
            done
        fi

        # PRE-BUILD CHECK: Detect missing module files (common hallucination)
        MISSING_MODS=""
        if [ -f src/lib.rs ]; then
            for mod_name in $(grep -oP '(?<=^mod )\w+(?=;)' src/lib.rs 2>/dev/null); do
                if [ ! -f "src/${mod_name}.rs" ] && [ ! -d "src/${mod_name}" ]; then
                    MISSING_MODS="$MISSING_MODS $mod_name"
                fi
            done
        fi

        if [ -n "$MISSING_MODS" ]; then
            echo "✗ HALLUCINATION DETECTED: mod statement(s) without files:$MISSING_MODS"
            log "WARN" "Missing module files:$MISSING_MODS (aider claimed to create but didn't)"
            STAT_MISSING_FILES=$((STAT_MISSING_FILES + 1))
            STAT_HALLUCINATIONS=$((STAT_HALLUCINATIONS + 1))
            STAT_REVERTS=$((STAT_REVERTS + 1))
            git checkout -- .
            git clean -fd
        elif $TEST_CMD 2>&1; then
            echo "Build passes! Committing aider's uncommitted work..."
            log "INFO" "Uncommitted changes compile, auto-committing"
            git add -A
            git commit -m "Auto-commit: aider changes that compile"
            NEW_COMMITS=1
            STAT_COMMITS=$((STAT_COMMITS + 1))
        else
            echo "Build fails with uncommitted changes - reverting hallucinated code..."
            log "WARN" "Uncommitted changes don't compile, reverting (hallucination)"
            STAT_HALLUCINATIONS=$((STAT_HALLUCINATIONS + 1))
            STAT_REVERTS=$((STAT_REVERTS + 1))
            git checkout -- .
            git clean -fd
        fi
    fi

    if [ $NEW_COMMITS -gt 0 ]; then
        echo ""
        echo "Recent commits:"
        git log --oneline -n $NEW_COMMITS

        # CRITICAL: Verify committed code compiles before pushing
        echo ""
        echo "Verifying committed code compiles before pushing..."
        if ! $TEST_CMD 2>&1; then
            echo "✗ Committed code FAILS to build - reverting commits!"
            log "ERROR" "Committed code doesn't compile, reverting $NEW_COMMITS commit(s)"
            STAT_BUILD_FAILURES=$((STAT_BUILD_FAILURES + 1))
            STAT_REVERTS=$((STAT_REVERTS + 1))
            git reset --hard HEAD~$NEW_COMMITS
            echo "Reverted to pre-session state."
        else
            echo "✓ Build verified"
            echo ""
            echo "Pushing to origin..."
            git push
            log "INFO" "Pushed $NEW_COMMITS commit(s)"
        fi
        STUCK_COUNT=0
    else
        STUCK_COUNT=$((STUCK_COUNT + 1))
        STAT_STUCK_EVENTS=$((STAT_STUCK_EVENTS + 1))
        echo "No progress made (stuck count: $STUCK_COUNT)"
        log "WARN" "No progress, stuck count: $STUCK_COUNT"

        # Call Claude Code for help after 2 failed attempts
        if [ $STUCK_COUNT -ge 2 ]; then
            echo ""
            echo "════════════════════════════════════════════════════════════"
            echo "Calling Claude Code to fix the issue..."
            echo "════════════════════════════════════════════════════════════"
            log "INFO" "Escalating to Claude Code"
            STAT_CLAUDE_CALLS=$((STAT_CLAUDE_CALLS + 1))

            # Keep output small to avoid context overflow
            BUILD_OUTPUT=$($TEST_CMD 2>&1 | grep -iE "error|failed|warning" | head -20)
            COMMIT_BEFORE=$(git rev-parse HEAD 2>/dev/null)
            DIRTY_BEFORE=$(git status --porcelain 2>/dev/null | md5sum)

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
            log "INFO" "Claude exited with code $CLAUDE_EXIT"

            COMMIT_AFTER=$(git rev-parse HEAD 2>/dev/null)
            DIRTY_AFTER=$(git status --porcelain 2>/dev/null | md5sum)

            if [ "$COMMIT_BEFORE" = "$COMMIT_AFTER" ] && [ "$DIRTY_BEFORE" = "$DIRTY_AFTER" ]; then
                echo ""
                echo "⚠ Claude claimed to work but made NO actual changes!"
                log "WARN" "Claude hallucination - no actual changes made"
                STAT_CLAUDE_HALLUCINATIONS=$((STAT_CLAUDE_HALLUCINATIONS + 1))
            else
                echo ""
                echo "✓ Claude made actual changes."
                log "INFO" "Claude made actual changes"
                DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l)
                if [ "$DIRTY_COUNT" -gt 0 ]; then
                    echo "Testing uncommitted changes..."
                    if $TEST_CMD 2>&1; then
                        echo "✓ Build passes! Auto-committing Claude's work..."
                        log "INFO" "Claude changes compile, auto-committing"
                        git add -A
                        git commit -m "Auto-commit: Claude Code changes that compile"
                        # Verify commit before pushing
                        if $TEST_CMD 2>&1; then
                            git push
                            STAT_COMMITS=$((STAT_COMMITS + 1))
                        else
                            echo "✗ Committed code fails - reverting"
                            log "ERROR" "Claude commit fails build, reverting"
                            STAT_REVERTS=$((STAT_REVERTS + 1))
                            git reset --hard HEAD~1
                        fi
                    else
                        echo "✗ Build FAILS - reverting Claude's broken code..."
                        log "WARN" "Claude changes don't compile, reverting"
                        STAT_REVERTS=$((STAT_REVERTS + 1))
                        git checkout -- .
                        git clean -fd 2>/dev/null
                    fi
                fi
                STUCK_COUNT=0
            fi
        fi
    fi

    # Periodic sanity check (uses haiku to keep costs low)
    if [ $((SESSION % SANITY_CHECK_INTERVAL)) -eq 0 ] && [ $SESSION -gt 0 ]; then
        echo ""
        echo "Running periodic sanity check (session $SESSION)..."
        log "INFO" "Periodic sanity check at session $SESSION"
        BUILD_CHECK_FULL=$($TEST_CMD 2>&1)
        BUILD_CHECK=$(echo "$BUILD_CHECK_FULL" | grep -iE "error|failed|warning" | head -15)
        if echo "$BUILD_CHECK_FULL" | grep -qi "error\|failed"; then
            echo "⚠ Sanity check found errors - calling Claude haiku to fix..."
            log "WARN" "Sanity check failed, calling haiku"
            STAT_CLAUDE_CALLS=$((STAT_CLAUDE_CALLS + 1))

            timeout 120 claude --print --dangerously-skip-permissions --model haiku "
Quick sanity check. Build errors:

$BUILD_CHECK

Please fix any issues and ensure build passes. Be brief.
"
            DIRTY_HAIKU=$(git status --porcelain 2>/dev/null | wc -l)
            if [ "$DIRTY_HAIKU" -gt 0 ]; then
                if $TEST_CMD 2>&1; then
                    echo "✓ Haiku fixed the build!"
                    log "INFO" "Haiku fixed the build"
                    git add -A
                    git commit -m "Auto-commit: Claude haiku build fix"
                    # Verify commit before pushing
                    if $TEST_CMD 2>&1; then
                        git push
                        STAT_COMMITS=$((STAT_COMMITS + 1))
                    else
                        echo "✗ Committed code fails - reverting"
                        log "ERROR" "Haiku commit fails build, reverting"
                        STAT_REVERTS=$((STAT_REVERTS + 1))
                        git reset --hard HEAD~1
                    fi
                else
                    echo "✗ Haiku's fix didn't work - reverting..."
                    log "WARN" "Haiku fix failed, reverting"
                    STAT_REVERTS=$((STAT_REVERTS + 1))
                    git checkout -- .
                    git clean -fd 2>/dev/null
                fi
            fi
        else
            echo "✓ Sanity check passed"
            log "INFO" "Sanity check passed"
        fi
    fi

    # Strategic planning session (uses Opus for high-level thinking)
    if [ $((SESSION % PLANNING_INTERVAL)) -eq 0 ] && [ $SESSION -gt 0 ]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║           STRATEGIC PLANNING SESSION                       ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        log "INFO" "Starting planning session at session $SESSION"
        STAT_PLANNING_SESSIONS=$((STAT_PLANNING_SESSIONS + 1))
        STAT_CLAUDE_CALLS=$((STAT_CLAUDE_CALLS + 1))

        COMPLETED_TASKS=$(grep "\[x\]" "$INSTRUCTIONS_FILE" | tail -10)
        REMAINING_TASKS=$(grep "\[ \]" "$INSTRUCTIONS_FILE")
        RECENT_COMMITS=$(git log --oneline -10 2>/dev/null)
        CODE_STRUCTURE=$(find . -name "*.rs" -o -name "*.py" -o -name "*.ts" -o -name "*.go" 2>/dev/null | grep -v node_modules | grep -v target | head -30)

        INSTRUCTIONS_BEFORE=$(md5sum "$INSTRUCTIONS_FILE" 2>/dev/null)

        timeout 600 claude --print --dangerously-skip-permissions "
You are the visionary architect and strategic planner for $PROJECT_NAME.

SESSION STATS:
- Sessions completed: $SESSION
- Tasks done: $DONE
- Tasks remaining: $TODO

RECENT PROGRESS (last 10 commits):
$RECENT_COMMITS

RECENTLY COMPLETED TASKS:
$COMPLETED_TASKS

CURRENT REMAINING TASKS:
$REMAINING_TASKS

CURRENT CODE STRUCTURE:
$CODE_STRUCTURE

YOUR MISSION - EVOLVE THE VISION:

1. CELEBRATE PROGRESS: Review what's been accomplished and how the project is taking shape

2. EXPAND THE ROADMAP: The roadmap should always be growing. Add new features that would make this a more capable, interesting project:
   - What's the next logical capability after current tasks?
   - What would make this project unique or impressive?
   - Think about what features would be fun to implement and demo

3. REFINE PRIORITIES: Reorder tasks so the most impactful/unblocking work comes first

4. ADD DETAIL: For complex upcoming tasks, add implementation hints or break them into subtasks

5. MAINTAIN VISION: Keep a 'Vision' or 'Goals' section at the top describing what this project is becoming

UPDATE $INSTRUCTIONS_FILE:
- Add 3-5 NEW tasks beyond what's currently listed (always be expanding)
- Reorder if needed (dependencies first, then high-impact features)
- Add brief implementation hints for tricky tasks
- Keep checkbox format: - [ ] todo, - [x] done
- Group related tasks under phase headings

PHILOSOPHY:
- This project should keep getting more capable and interesting
- Each planning session should leave the roadmap MORE ambitious, not less
- Balance achievable near-term tasks with exciting longer-term goals
- The local AI (aider) works best with clear, specific tasks

After updating, commit with message: 'docs: planning session - expand roadmap'
"
        PLANNING_EXIT=$?
        log "INFO" "Planning session exited with code $PLANNING_EXIT"

        INSTRUCTIONS_AFTER=$(md5sum "$INSTRUCTIONS_FILE" 2>/dev/null)
        if [ "$INSTRUCTIONS_BEFORE" != "$INSTRUCTIONS_AFTER" ]; then
            echo "✓ Roadmap updated by planning session"
            log "INFO" "Roadmap was updated by planning session"

            DIRTY_PLAN=$(git status --porcelain "$INSTRUCTIONS_FILE" 2>/dev/null | wc -l)
            if [ "$DIRTY_PLAN" -gt 0 ]; then
                git add "$INSTRUCTIONS_FILE"
                git commit -m "docs: planning session - expand roadmap (session $SESSION)"
                git push
                STAT_COMMITS=$((STAT_COMMITS + 1))
                log "INFO" "Committed roadmap expansion"
            fi
        else
            echo "Roadmap unchanged (planning found no updates needed)"
            log "INFO" "Planning session made no roadmap changes"
        fi
    fi

    # Stop when all tasks complete
    if [ "$TODO" -eq 0 ]; then
        echo "All tasks complete!"
        log "INFO" "All tasks complete!"
        break
    fi

    echo ""
    sleep 1
done

print_stats
