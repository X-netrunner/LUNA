#!/bin/bash
set -euo pipefail # was getting some weird error without this

#LUNA IS A ReAct style agent reason + action

f_p=$(pwd) #path of files
RAG="$f_p/memory/rag.py"
MODEL_SMALL="qwen2:1.5b-instruct"
MODEL_MEDIUM="llama3.2:3b-instruct-q4_k_m"
MODEL_LARGE="mannix/llama3.1-8b-lexi:q4_k_m"
LUNA_MODE="ephemeral"   # change to daemon when needed

MAX_STEPS=6 #ensures that it doesn't go into an infinte loop

LOG_FILE="$f_p/logs/agent.log" #normal log
LONG_MEMORY="$f_p/memory/long_term.log" #will use later to make sure LUNA will still be relavent using previous chat data
CRITICAL_FILES=("$f_p/luna.sh" "$f_p/prompts/system.txt") #personallities , rules and what not

SCRATCHPAD="" #think about it like cache but for LUNA it will help to keep some data relavent till the session ends.
DEBUG_MODE=false #if you turn it on you will see SCRATCHPAD data. tbh its not working well right now
export LUNA_DEBUG=$DEBUG_MODE #sends this to rag.py

#User based variables
spotify="spotify" #if its flatpak do com.spotify.Client
editor="zeditor" #if you use vscode use that
browser="zen-browser"
explorer="thunar"

mkdir -p logs memory

run_model() {
    local model="$1"
    local prompt="$2"
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo "Running: $model"
    fi
    ollama run "$model" "$prompt"
} #just to make it modular for future editting everything will come back here to run the model

# Case-insensitive field extraction
extract_field() {
    local response="$1"
    local field="$2"

    echo "$response" | awk -v f="$field" '
        BEGIN {IGNORECASE=1}
        $0 ~ "^"f":" {
            sub("^"f":[[:space:]]*", "")
            print
            exit
        }
    '
} # this will get the data from the terminal and send as string data to the user as models can only send back string data

execute_tool() {
    local action="$1"
    local args="$2"
    local OUTPUT=""
    local STATUS=0

    case "$action" in
        shell)
            set +e
            OUTPUT=$(timeout 10s bash -c "$args" 2>&1)
            STATUS=$?
            set -e
            ;;
        read_file)
            OUTPUT=$(cat "$args" 2>&1)
            STATUS=$?
            ;;
        scratchpad_update)
            SCRATCHPAD="$args"
            OUTPUT="Scratchpad updated."
            STATUS=0
            ;;
        write_file)
            local FILE=$(echo "$args" | cut -d'|' -f1)
            local CONTENT=$(echo "$args" | cut -d'|' -f2-)

            for file in "${CRITICAL_FILES[@]}"; do
                if [[ "$FILE" == "$file" ]]; then
                    OUTPUT="__ERROR__ Attempt to modify protected file."
                    STATUS=1
                    echo "$OUTPUT"
                    return
                fi
            done

            echo "$CONTENT" > "$FILE" 2>&1
            STATUS=$?
            OUTPUT="Write attempted."
            ;;
        memory_store)
            if [[ "$args" =~ \? ]]; then
                OUTPUT="__ERROR__ Questions should not be stored as memory."
                STATUS=1
            else
                OUTPUT=$(python3 $RAG add "$args" 2>&1)
                STATUS=$?
            fi
            ;;

        finish)
            OUTPUT="$args"
            STATUS=0
            ;;
        *)
            OUTPUT="Invalid action."
            STATUS=1
            ;;
    esac

    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo "---- SCRATCHPAD ----"
        echo "$SCRATCHPAD"
        echo "--------------------"
    fi

    if [ $STATUS -ne 0 ]; then
        echo "__ERROR__ $OUTPUT"
    else
        echo "$OUTPUT"
    fi
} #yk how before it was sending that string back from terminal , well this run those commands

build_prompt() {
    cat prompts/system.txt 2>/dev/null || echo "SYSTEM: You are Luna, a helpful AI assistant."
    echo ""
    echo "GOAL: $GOAL"
    echo "SCRATCHPAD:"
    echo "$SCRATCHPAD"
    echo ""
    echo "LAST_ACTION: $LAST_ACTION"
    echo "LAST_TOOL_RESULT:"
    echo "$LAST_OBSERVATION"
    echo ""
    echo "RELEVANT_MEMORY:"
    echo "${RELEVANT_MEMORY:-No memory yet.}"
}

log_step() {
    {
        echo "STEP $STEP"
        echo "$1"
        echo "--------------------------------"
    } >> "$LOG_FILE"
}

run_agent() {
    GOAL="$*" # can use $* as well if you are getting any error with $@ use $*
    STEP=0
    LAST_ACTION="none"
    LAST_OBSERVATION="none"
    FAILURE_COUNT=0
    REPEAT_COUNT=0
    PREV_ACTION=""
    PREV_ARGS=""

    RELEVANT_MEMORY=$(python3 $RAG query "$GOAL" 2>/dev/null)
    if [[ -n "$RELEVANT_MEMORY" ]]; then
        echo "$RELEVANT_MEMORY"
        return
    fi


    while [ $STEP -lt $MAX_STEPS ]; do

        PROMPT=$(build_prompt)

        RESPONSE=$(run_model "$MODEL_MEDIUM" "$PROMPT")
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo "MODEL RAW RESPONSE:"
            echo "$RESPONSE"
        fi

        ACTION=$(extract_field "$RESPONSE" "ACTION")
        ARGS=$(extract_field "$RESPONSE" "ARGS")

        # Escalate if malformed
        if [ -z "$ACTION" ]; then
            RESPONSE=$(run_model "$MODEL_MEDIUM" "$PROMPT")
            ACTION=$(extract_field "$RESPONSE" "ACTION")
            ARGS=$(extract_field "$RESPONSE" "ARGS")
        fi

        if [ -z "$ACTION" ]; then
            RESPONSE=$(run_model "$MODEL_LARGE" "$PROMPT")
            ACTION=$(extract_field "$RESPONSE" "ACTION")
            ARGS=$(extract_field "$RESPONSE" "ARGS")
        fi

        # Guard
        if [ -z "$ACTION" ]; then
            echo "Model failed to return valid ACTION."
            break
        fi

        log_step "$RESPONSE"

        # Repeat detection
        if [[ "$ACTION" == "$PREV_ACTION" && "$ARGS" == "$PREV_ARGS" ]]; then
            REPEAT_COUNT=$((REPEAT_COUNT+1))
        else
            REPEAT_COUNT=0
        fi

        PREV_ACTION="$ACTION"
        PREV_ARGS="$ARGS"

        if [ $REPEAT_COUNT -ge 2 ]; then
            LAST_OBSERVATION="Repeated action detected."
            PROMPT=$(build_prompt)
            RESPONSE=$(run_model "$MODEL_LARGE" "$PROMPT")
            ACTION=$(extract_field "$RESPONSE" "ACTION")
            ARGS=$(extract_field "$RESPONSE" "ARGS")
            REPEAT_COUNT=0
        fi

        RESULT=$(execute_tool "$ACTION" "$ARGS")
        log_step "$RESULT"

        if [[ "$RESULT" == __ERROR__* ]]; then
            FAILURE_COUNT=$((FAILURE_COUNT+1))
        else
            FAILURE_COUNT=0
        fi

        if [ $FAILURE_COUNT -ge 2 ]; then
            LAST_OBSERVATION="$RESULT"
            PROMPT=$(build_prompt)
            RESPONSE=$(run_model "$MODEL_LARGE" "$PROMPT")
            ACTION=$(extract_field "$RESPONSE" "ACTION")
            ARGS=$(extract_field "$RESPONSE" "ARGS")
            FAILURE_COUNT=0
            RESULT=$(execute_tool "$ACTION" "$ARGS")
        fi

        if [ "$ACTION" == "finish" ]; then
            echo "$RESULT"
            break
        fi

        LAST_ACTION="$ACTION"
        LAST_OBSERVATION="$RESULT"
        STEP=$((STEP+1))
    done

    # If we hit MAX_STEPS without finish, output what we have
    if [ "$ACTION" != "finish" ]; then
        echo "$SCRATCHPAD"
    fi
} #main of the code without this , it is cooked

########################################
# ENTRY ROUTING (HELPS IN MORE ACCURATE RESULTS)
########################################

GOAL="$*"
LOWER=$(echo "$GOAL" | tr '[:upper:]' '[:lower:]')

if [[ "$LOWER" =~ ^i\ (am|use|have|like|remember|hate) ]]; then
    echo "You mentioned: \"$GOAL\""
    echo "Should I remember this? (yes/no)"
    read CONFIRM
    if [[ "$CONFIRM" == "yes" ]]; then
        python3 $RAG add "$GOAL"
    fi
    exit 0
fi

if [[ "$DEBUG_MODE" == "true" ]]; then
    echo "DEBUG: Input GOAL='$GOAL'"
    echo "DEBUG: Lowercased='$LOWER'"
fi

# 🔥 REMEMBER ROUTE (MUST BE AFTER GOAL/LOWER)
if [[ "$LOWER" == remember* ]]; then
    MEMORY_TEXT="${GOAL#remember }"
    OUTPUT=$(python3 $RAG add "$MEMORY_TEXT" 2>/dev/null)
    echo "$OUTPUT"
    exit 0
fi

# the following will be basic stuff, we don't want to send everything to LUNA and make more tokens.
if [[ "$LOWER" == *"list"* && "$LOWER" == *"file"* ]]; then
    ls -la
    exit 0
fi

if [[ "$LOWER" == *"find logs"* ]]; then
    ls -d logs 2>/dev/null || echo "logs not found"
    exit 0
fi

if [[ "$LOWER" == *"open spotify"* || "$LOWER" == *"spotify"* ]]; then
    $spotify &
    echo "Opening Spotify..."
    exit 0
fi

if [[ "$LOWER" == *"open explorer"* || "$LOWER" == *"file handler"* || "$LOWER" == *"file manager"* ]]; then
    $explorer &
    echo "Opening $explorer..."
    exit 0
fi

if [[ "$LOWER" == *"open browser"* || "$LOWER" == *"browser"* ]]; then
    $browser &
    echo "Opening $browser..."
    exit 0
fi

if [[ "$LOWER" == *"open editor"* || "$LOWER" == *"zed"* || "$LOWER" == *"text editor"* ]]; then
    $editor &
    echo "Opening $editor..."
    exit 0
fi

# Knowledge-style questions should still use agent (so RAG works)
if [[ "$LOWER" == *"what"* || "$LOWER" == *"explain"* || "$LOWER" == *"why"* || "$LOWER" == *"how"* || "$LOWER" == *"where"* ]]; then
    run_agent "$GOAL"
    exit 0
fi

# Action keywords → Agent
if [[ "$LOWER" == *"list"* || "$LOWER" == *"find"* || "$LOWER" == *"create"* || "$LOWER" == *"delete"* || "$LOWER" == *"write"* || "$LOWER" == *"run"* ]]; then
    run_agent "$GOAL"
    exit 0
fi

# Default conversation
if [[ "$LOWER" =~ ^(hi|hello|hey|how\ are\ you|whats\ up|what\'s\ up)$ ]]; then
    ollama run "$MODEL_MEDIUM" "Respond briefly and calmly: $GOAL"
    exit 0
fi

run_agent "$GOAL"
exit 0
