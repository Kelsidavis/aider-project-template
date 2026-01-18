#!/bin/bash
# Continuous development script
# Edit PROJECT_DIR and FILE_PATTERN for your project

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILE_PATTERN="*.py"  # Change to *.rs, *.ts, *.go, etc.

cd "$PROJECT_DIR"

echo "Starting continuous development..."
echo "Press Ctrl+C to stop"
echo ""

SESSION=0

while true; do
    SESSION=$((SESSION + 1))
    COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    DONE=$(grep -c "\[x\]" INSTRUCTIONS.md 2>/dev/null || echo "0")
    TODO=$(grep -c "\[ \]" INSTRUCTIONS.md 2>/dev/null || echo "0")

    # Get next 3 unchecked items
    NEXT_TASKS=$(grep -m3 "\[ \]" INSTRUCTIONS.md | sed 's/- \[ \] /  - /')

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ Session: $SESSION | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "║ Commits: $COMMITS | Done: $DONE | Todo: $TODO"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Find source files (edit pattern as needed)
    SRC_FILES=$(find . -name "$FILE_PATTERN" -not -path "./.git/*" 2>/dev/null | tr '\n' ' ')

    aider $SRC_FILES \
        INSTRUCTIONS.md \
        --message "
Read INSTRUCTIONS.md. Work through unchecked [ ] items.

NEXT TASKS:
$NEXT_TASKS

CRITICAL: After EVERY change, run the build/test command.
Code must pass ALL tests with ZERO warnings before marking [x].

WORKFLOW:
1. Implement feature
2. RUN THE BUILD/TEST - do not skip this step
3. Fix ALL errors and warnings
4. Only mark [x] when tests pass
5. Move to next task

Use WHOLE edit format - output complete file contents.
"

    EXIT_CODE=$?

    COMMITS_AFTER=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    NEW_COMMITS=$((COMMITS_AFTER - COMMITS))

    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ Session $SESSION complete (exit: $EXIT_CODE)"
    echo "│ New commits: $NEW_COMMITS | Total: $COMMITS_AFTER"
    echo "└─────────────────────────────────────────────────────────────┘"

    if [ $NEW_COMMITS -gt 0 ]; then
        echo ""
        echo "Recent commits:"
        git log --oneline -n $NEW_COMMITS
    fi

    # Stop when all tasks complete
    if [ "$TODO" -eq 0 ]; then
        echo "All tasks complete!"
        break
    fi

    echo ""
    sleep 1
done
