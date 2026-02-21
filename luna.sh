#!/bin/bash
set -euo pipefail # was getting some weird error without this

#LUNA IS A ReAct style agent reason + action

f_p=$(pwd) #path of files
RAG="$f_p/memory/rag.py"
RAG_DAEMON="$f_p/memory/rag_daemon.py"
RAG_SOCKET="/tmp/luna_rag.sock"    # unix socket used by the daemon
MODEL_SMALL="qwen2:1.5b-instruct"
MODEL_MEDIUM="llama3.2:3b-instruct-q4_k_m"
MODEL_LARGE="mannix/llama3.1-8b-lexi:q4_k_m"
LUNA_MODE="ephemeral"   # change to daemon when needed
MODEL_STATS="$f_p/logs/model_stats.log" #for response times and what not

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

# RAG call — uses daemon socket if running, falls back to direct python call (slower but always works)
# Usage: rag_call <add|query> <text>
rag_call() {
    local mode="$1"
    local text="$2"

    if [[ -S "$RAG_SOCKET" ]]; then
        # Daemon is running — send JSON over socket, no python startup cost
        local req="{\"mode\": \"$mode\", \"text\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")}"
        local res
        res=$(echo "$req" | socat - UNIX-CONNECT:"$RAG_SOCKET" 2>/dev/null)
        if [[ $? -eq 0 && -n "$res" ]]; then
            if [[ "$mode" == "query" ]]; then
                python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('result',''))" "$res"
            else
                python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('message',''))" "$res"
            fi
            return 0
        fi
    fi

    # Fallback to direct python call if daemon is not running
    python3 "$RAG" "$mode" "$text" 2>/dev/null
}

# Case-insensitive field extraction
extract_field() {
    local response="$1"
    local field="$2"

    echo "$response" | awk -v f="$field" '
        BEGIN {IGNORECASE=1}
        $0 ~ "^[[:space:]]*"f":" {
            sub("^[[:space:]]*"f":[[:space:]]*", "")
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
                OUTPUT=$(rag_call add "$args")  # uses daemon socket if running, else direct python
                STATUS=$?
            fi
            ;;

        finish)
            local clean_args="${args,,}"  # lowercase for comparison
            if [ -n "$args" ] && [ "$clean_args" != "none" ]; then
                OUTPUT="$args"
            else
                OUTPUT="$SCRATCHPAD"
            fi
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

########################################
# MODEL ROUTER (Deterministic)
########################################

route_model() {
    local goal="$1"
    local length=${#goal}

    # Detect code blocks
    if echo "$goal" | grep -q '```'; then
        echo "$MODEL_LARGE|code_block"
        return
    fi

    # Long input
    if [ "$length" -gt 200 ]; then
        echo "$MODEL_LARGE|long_input"
        return
    fi

    # Architectural / reasoning keywords
    if echo "$goal" | grep -qiE "design|architecture|optimize|refactor|analyze|system|build|compare|simulate|distributed|performance"; then
        echo "$MODEL_LARGE|keyword_trigger"
        return
    fi

    # Default
    echo "$MODEL_MEDIUM|default_simple"
}

run_agent() {
    GOAL="$*" # can use $* as well if you are getting any error with $@ use $*
    STEP=0
    START_TIME=$(date +%s.%N) #start reaponse time
    # Determine which model to start with
    ROUTE_RESULT=$(route_model "$GOAL")
    MODEL_CHOICE=$(echo "$ROUTE_RESULT" | cut -d'|' -f1)
    ROUTE_REASON=$(echo "$ROUTE_RESULT" | cut -d'|' -f2)

    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo "ROUTER DECISION: $MODEL_CHOICE"
        echo "ROUTER REASON: $ROUTE_REASON"
    fi

    SCRATCHPAD_COUNT=0
    LAST_ACTION="none"
    LAST_OBSERVATION="none"
    FAILURE_COUNT=0
    REPEAT_COUNT=0
    PREV_ACTION=""
    PREV_ARGS=""

    RELEVANT_MEMORY=$(rag_call query "$GOAL")  # uses daemon socket if running, else direct python


    while [ $STEP -lt $MAX_STEPS ]; do

        PROMPT=$(build_prompt)
        RESPONSE=$(run_model "$MODEL_CHOICE" "$PROMPT")
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo "MODEL RAW RESPONSE:"
            echo "$RESPONSE"
        fi

        ACTION=$(extract_field "$RESPONSE" "ACTION")
        ARGS=$(extract_field "$RESPONSE" "ARGS")

        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo "PARSED ACTION: [$ACTION]"
            echo "PARSED ARGS: [$ARGS]"
        fi


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

        #  Prevent multiple scratchpad updates
        # If model tries to answer using scratchpad, convert to finish
        if [[ "$ACTION" == "scratchpad_update" ]]; then
            SCRATCHPAD="$ARGS"
            ACTION="finish"
            ARGS="$SCRATCHPAD"
        fi


        if [[ "$ACTION" == "finish" ]]; then
            RESULT=$(execute_tool "$ACTION" "$ARGS")

            END_TIME=$(date +%s.%N)
            RESPONSE_TIME=$(echo "$END_TIME - $START_TIME" | bc)

            if [[ "$DEBUG_MODE" == "true" ]]; then
                echo "MODEL USED: $MODEL_CHOICE"
                echo "RESPONSE TIME: ${RESPONSE_TIME}s"
            fi

            echo "$(date) | $MODEL_CHOICE | ${RESPONSE_TIME}s" >> "$MODEL_STATS"

            echo "$RESULT"
            break
        fi


        # Convert memory_store into direct answer
        if [[ "$ACTION" == "memory_store" ]]; then
            execute_tool "memory_store" "$ARGS" > /dev/null  # fix: was skipping actual storage
            ACTION="finish"
            ARGS=""  # fix: clear args so finish falls back to $SCRATCHPAD, not the stored memory text
        fi

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

        if [[ "$ACTION" == "finish" ]]; then
            echo "$RESULT"
            break
        fi

        LAST_ACTION="$ACTION"
        LAST_OBSERVATION="$RESULT"
        STEP=$((STEP+1))
    done

    # If we hit MAX_STEPS without finish, output what we have
    if [ "$ACTION" != "finish" ]; then
        END_TIME=$(date +%s.%N)
        RESPONSE_TIME=$(echo "$END_TIME - $START_TIME" | bc)

        echo "$(date) | $MODEL_CHOICE | ${RESPONSE_TIME}s | max_steps" >> "$MODEL_STATS"

        echo "$SCRATCHPAD"
    fi
} #main of the code without this , it is cooked

########################################
# INTENT ROUTER (MODEL_SMALL)
# Uses a tiny model for single-token classification instead of regex.
# MODEL_SMALL (1.5b) is fast enough that it adds minimal latency.
# To add a new intent: add a line to the prompt categories + a case branch below.
########################################

route_intent() {
    local input="$1"

    local ROUTE_PROMPT="Classify the user input into ONE category. Reply with ONLY the category name, nothing else.

Categories:
  app_open      — user wants to open an app (spotify, browser, editor, file manager)
  memory_save   — user says 'remember X' or 'I am/use/have/like/hate X'
  memory_ask    — user asks what they told you, or asks about personal preferences
  file_op       — list files, find logs, basic file listing
  agent         — complex task: create, write, run, find, delete, explain, reason, analyse
  chat          — greeting or casual conversation

Input: $input
Category:"

    local result
    result=$(ollama run "$MODEL_SMALL" "$ROUTE_PROMPT" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    # Validate result — fall back to agent if model returns something unexpected
    case "$result" in
        app_open|memory_save|memory_ask|file_op|agent|chat) echo "$result" ;;
        *) echo "agent" ;;
    esac
}

########################################
# ENTRY ROUTING (HELPS IN MORE ACCURATE RESULTS)
########################################

GOAL="$*"
LOWER=$(echo "$GOAL" | tr '[:upper:]' '[:lower:]')

# Daemon management — handle before routing so it works without MODEL_SMALL
if [[ "$LOWER" == "luna daemon start" ]]; then
    if [[ -S "$RAG_SOCKET" ]]; then
        echo "Daemon is already running."
    else
        echo "Starting LUNA RAG daemon..."
        nohup python3 "$RAG_DAEMON" start > "$f_p/logs/rag_daemon.log" 2>&1 &
        sleep 2  # give it time to load the embedding model
        echo "Daemon started. Log: logs/rag_daemon.log"
    fi
    exit 0
fi

if [[ "$LOWER" == "luna daemon stop" ]]; then
    python3 "$RAG_DAEMON" stop
    exit 0
fi

if [[ "$LOWER" == "luna daemon status" ]]; then
    python3 "$RAG_DAEMON" status
    exit 0
fi

if [[ "$DEBUG_MODE" == "true" ]]; then
    echo "DEBUG: Input GOAL='$GOAL'"
    echo "DEBUG: Lowercased='$LOWER'"
fi

# Run MODEL_SMALL to classify intent — replaces the old regex block
INTENT=$(route_intent "$GOAL")

if [[ "$DEBUG_MODE" == "true" ]]; then
    echo "DEBUG: INTENT='$INTENT'"
fi

case "$INTENT" in

    app_open)
        # Sub-route by app keyword — MODEL_SMALL only tells us it's an app, not which one
        if [[ "$LOWER" == *"spotify"* ]]; then
            $spotify & echo "Opening Spotify..."
        elif [[ "$LOWER" == *"browser"* ]]; then
            $browser & echo "Opening $browser..."
        elif [[ "$LOWER" == *"editor"* || "$LOWER" == *"zed"* || "$LOWER" == *"text editor"* ]]; then
            $editor & echo "Opening $editor..."
        elif [[ "$LOWER" == *"explorer"* || "$LOWER" == *"file manager"* || "$LOWER" == *"file handler"* ]]; then
            $explorer & echo "Opening $explorer..."
        else
            echo "Which app would you like to open?"
        fi
        ;;

    memory_save)
        # Prompt for confirmation if it's an "I am/use/have..." style statement
        if [[ "$LOWER" =~ ^i\ (am|use|have|like|remember|hate) ]]; then
            echo "You mentioned: \"$GOAL\""
            echo "Should I remember this? (yes/no)"
            read CONFIRM
            if [[ "$CONFIRM" == "yes" ]]; then
                rag_call add "$GOAL"
            fi
        else
            # "remember X" — strip the trigger word and store directly
            MEMORY_TEXT="${GOAL#[Rr]emember }"
            OUTPUT=$(rag_call add "$MEMORY_TEXT")
            echo "$OUTPUT"
        fi
        ;;

    memory_ask)
        # Always goes through agent so RAG context gets injected into the prompt
        run_agent "$GOAL"
        ;;

    file_op)
        # the following will be basic stuff, we don't want to send everything to LUNA and make more tokens.
        if [[ "$LOWER" == *"find logs"* ]]; then
            ls -d logs 2>/dev/null || echo "logs not found"
        else
            ls -la
        fi
        ;;

    chat)
        # Default conversation — small, no agent needed
        ollama run "$MODEL_MEDIUM" "Respond briefly and calmly: $GOAL"
        ;;

    agent|*)
        # Action keywords and everything else goes to the full ReAct agent
        run_agent "$GOAL"
        ;;

esac
exit 0
