import SlateTermCore

/// Additional host telemetry alongside (not instead of) Ghostty's OSC integration.
/// The zsh wrapper restores the user's startup directory before sourcing their .zshenv;
/// zsh then reads their normal .zprofile/.zshrc. No user files are modified.
///
/// Every shell numbers its reports so that a command's prompt is exactly one after its
/// running report. The host pairs them by number because reports can arrive out of order.
public enum ShellIntegration {
    public static func hooks(for shell: ShellKind) -> String {
        switch shell {
        case .zsh: return zshHooks
        case .bash: return bashHooks
        case .fish: return fishHooks
        }
    }

    /// bash imports PROMPT_COMMAND from the environment and runs it at the first prompt,
    /// after all startup files. This works for every bash, including Apple's 3.2, which
    /// ignores the ENV-based startup Ghostty uses. If a startup file replaces
    /// PROMPT_COMMAND, the shell simply runs without Slate's integration.
    public static let bashBootstrap = #"builtin source "$SLATE_TERM_BASH_INIT""#

    public static let zshBootstrap = #"""
    if [[ ${SLATE_TERM_USER_ZDOTDIR_SET-0} == 1 ]]; then
        'builtin' 'export' ZDOTDIR="$SLATE_TERM_USER_ZDOTDIR"
    else
        'builtin' 'unset' ZDOTDIR
    fi
    'builtin' 'typeset' _slate_user_env="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_slate_user_env" ]] || 'builtin' 'source' '--' "$_slate_user_env"
    'builtin' 'unset' _slate_user_env
    """# + "\n" + zshHooks

    public static let zshHooks = #"""
    if [[ -o interactive && -n ${SLATE_TERM_CONTEXT_TOKEN-} && -z ${SLATE_TERM_SHELL_PID-} ]]; then
        'builtin' 'export' SLATE_TERM_SHELL_PID=$$
        'builtin' 'typeset' -gi _slate_context_sequence=0 _slate_run_installed=0
        function _slate_run() {
            builtin emulate -L zsh -o no_aliases
            builtin local -a _slate_options
            # PREBUFFER holds earlier lines at a continuation prompt.
            [[ -z "$BUFFER" && -z "$PREBUFFER" && "$CONTEXT" == start ]] && _slate_options+=(--empty-buffer)
            builtin local line
            line=$("$SLATE_TERM_CLI" shell run-input --pid "$$" "${_slate_options[@]}" 2>/dev/null) || return 0
            [[ -n "$line" ]] || return 0
            BUFFER="$line"
            CURSOR=${#BUFFER}
            zle .accept-line
        }
        function _slate_context_precmd() {
            builtin local -i previous_status=$?
            builtin emulate -L zsh -o no_aliases
            if (( !_slate_run_installed )) && [[ -n ${SLATE_TERM_RUN_KEY-} ]]; then
                builtin zle -N _slate_run
                builtin local map
                for map in main emacs viins vicmd; do
                    builtin bindkey -M "$map" "$SLATE_TERM_RUN_KEY" _slate_run
                done
                _slate_run_installed=1
            fi
            (( ++_slate_context_sequence ))
            "$SLATE_TERM_CLI" shell update --shell zsh --run-input true --state prompt --pid "$$" --sequence "$_slate_context_sequence" --cwd="$PWD" --exit-code "$previous_status" >/dev/null 2>&1
            return 0
        }
        function _slate_context_preexec() {
            builtin emulate -L zsh -o no_aliases
            (( ++_slate_context_sequence ))
            "$SLATE_TERM_CLI" shell update --shell zsh --run-input true --state running --pid "$$" --sequence "$_slate_context_sequence" --cwd="$PWD" --command="${1[1,4096]}" >/dev/null 2>&1
            return 0
        }
        'builtin' 'typeset' -ga precmd_functions preexec_functions
        precmd_functions+=(_slate_context_precmd)
        preexec_functions+=(_slate_context_preexec)
    fi
    """#

    /// bash 3.2+. Runs need bash 4.4+: `bind -x` reads the edit line, and PS0 marks the
    /// moment a command starts. Older bash reports state through bash-preexec, which
    /// Ghostty's script loads. Prompts are 2n and commands 2n+1, so the PS0 subshell never
    /// needs to change the counter.
    public static let bashHooks = #"""
    if [[ $- == *i* && -n ${SLATE_TERM_CONTEXT_TOKEN-} && -z ${SLATE_TERM_SHELL_PID-} && -z ${TMUX-} && -z ${STY-} ]]; then
        builtin export SLATE_TERM_SHELL_PID=$$
        # Children must not repeat the bootstrap.
        builtin export -n PROMPT_COMMAND
        _slate_n=0 _slate_hist= _slate_claimed= _slate_line=0 _slate_nil= _slate_run_input=false
        (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) && _slate_run_input=true
        # Expand to nothing, but record in this shell which line the editor is reading:
        # 1 a primary prompt, 2 a continuation, 0 a running command (PS0). The offset is
        # evaluated only when _slate_nil is set, and only with promptvars on.
        _slate_mark_prompt='${_slate_nil:$((_slate_line=1)):0}'
        _slate_mark_continuation='${_slate_nil:$((_slate_line=2)):0}'
        _slate_mark_running='${_slate_nil:$((_slate_line=0)):0}$(_slate_preexec)'
        # Apple's bash 3.2 gets no Ghostty injection. Ghostty's script still adds prompt marks
        # and bash-preexec without re-running startup files, but it is not written for bash 3.2
        # under set -u (it reads BASHPID and unset feature flags). Load only bash-preexec then.
        if ! builtin declare -F __ghostty_precmd >/dev/null && [[ -d ${GHOSTTY_RESOURCES_DIR-}/shell-integration/bash ]]; then
            if [[ $- == *u* && $_slate_run_input == false ]]; then
                [[ -n ${bash_preexec_imported-} ]] || builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/bash-preexec.sh"
            else
                # Ghostty sets this when it injects; its prompt hooks read it unguarded.
                : "${GHOSTTY_SHELL_FEATURES=}"
                _slate_nounset=${-//[!u]/}
                builtin set +u
                builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash"
                [[ -n $_slate_nounset ]] && builtin set -u
                builtin unset _slate_nounset
            fi
        fi
        function _slate_prompt() {
            builtin local status=$?
            _slate_n=$(( _slate_n + 1 ))
            _slate_claimed=
            # HISTCMD differs between bash versions; the last entry's number does not.
            _slate_hist=$(HISTTIMEFORMAT= builtin history 1)
            _slate_hist=${_slate_hist#"${_slate_hist%%[![:space:]]*}"}
            _slate_hist=${_slate_hist%%[!0-9]*}
            "$SLATE_TERM_CLI" shell update --shell bash --run-input "$_slate_run_input" --state prompt --pid "$$" --sequence "$(( 2 * _slate_n ))" --cwd="$PWD" --exit-code "$status" >/dev/null 2>&1
            return "$status"
        }
        function _slate_preexec() {
            # Assign separately: with the builtin prefix, `local x=$y` word-splits $y.
            builtin local command entry number
            command=$_slate_claimed
            if [[ -z $command ]]; then
                entry=$(HISTTIMEFORMAT= builtin history 1)
                entry=${entry#"${entry%%[![:space:]]*}"}
                number=${entry%%[!0-9]*}
                # A command missing from history (ignorespace, history off) would
                # otherwise report the previous entry. Unknown text is sent as empty.
                if [[ -n $number && $number != "$_slate_hist" ]]; then
                    command=${entry#"$number"}
                    command=${command#\*}
                    command=${command#  }
                fi
            fi
            # An empty `--command=` is a missing value; leave it out when the text is unknown.
            builtin local -a text
            text=()
            [[ -n $command ]] && text=(--command="${command:0:4096}")
            "$SLATE_TERM_CLI" shell update --shell bash --run-input "$_slate_run_input" --state running --pid "$$" --sequence "$(( 2 * _slate_n + 1 ))" --cwd="$PWD" ${text[@]+"${text[@]}"} >/dev/null 2>&1
            # bash-preexec with extdebug skips the user's command when a hook fails.
            return 0
        }
        # Last in PROMPT_COMMAND, after prompt frameworks rewrite these strings.
        function _slate_ensure() {
            builtin local status=$?
            [[ ${PS0-} == *"$_slate_mark_running"* ]] || PS0=$_slate_mark_running${PS0-}
            [[ ${PS1-} == *"$_slate_mark_prompt"* ]] || PS1=$_slate_mark_prompt${PS1-}
            [[ ${PS2-} == *"$_slate_mark_continuation"* ]] || PS2=$_slate_mark_continuation${PS2-}
            return "$status"
        }
        if [[ -n ${bash_preexec_imported-} ]]; then
            # First, so a failing hook later in the list cannot stop Slate's reports.
            precmd_functions=(_slate_prompt ${precmd_functions[@]+"${precmd_functions[@]}"})
            preexec_functions=(_slate_preexec ${preexec_functions[@]+"${preexec_functions[@]}"})
        elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
            PROMPT_COMMAND=(_slate_prompt "${PROMPT_COMMAND[@]}" _slate_ensure)
        else
            # First, so it sees the command's status; both hooks return that status unchanged.
            PROMPT_COMMAND="_slate_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND};_slate_ensure"
        fi
        if [[ $_slate_run_input == true && -n ${SLATE_TERM_RUN_KEY-} ]]; then
            # bind -x cannot accept the line itself. The run key expands to two private
            # keys: the first claims the run and rebinds the second to accept-line, or
            # to a no-op when refused, so a refusal never submits the user's draft.
            function _slate_run() {
                builtin local empty= line
                # Fail closed: claim only at an empty primary prompt whose markers are intact,
                # never in a continuation, a draft, or a program reading input with `read -e`.
                if [[ -z ${READLINE_LINE-} && $_slate_line == 1 && ${PS0-} == *"$_slate_mark_running"* \
                      && ${PS1-} == *"$_slate_mark_prompt"* && ${PS2-} == *"$_slate_mark_continuation"* ]] \
                   && builtin shopt -q promptvars; then
                    empty=--empty-buffer
                fi
                if line=$("$SLATE_TERM_CLI" shell run-input --pid "$$" $empty 2>/dev/null) && [[ -n $line ]]; then
                    READLINE_LINE=$line
                    READLINE_POINT=${#line}
                    _slate_claimed=$line
                    builtin bind '"\e[slate-accept~": accept-line'
                else
                    builtin bind -x '"\e[slate-accept~": :'
                fi
                return 0
            }
            for _slate_map in emacs vi-insert vi-command; do
                builtin bind -m "$_slate_map" "\"\\e${SLATE_TERM_RUN_KEY:1}\": \"\\e[slate-claim~\\e[slate-accept~\"" 2>/dev/null
                builtin bind -m "$_slate_map" -x '"\e[slate-claim~": _slate_run' 2>/dev/null
                builtin bind -m "$_slate_map" -x '"\e[slate-accept~": :' 2>/dev/null
            done
            builtin unset _slate_map
        fi
        if [[ -n ${bash_preexec_imported-} && "${PROMPT_COMMAND[*]-}" == *__bp_install* ]] && builtin declare -F __bp_install >/dev/null; then
            # bash-preexec would install at the next prompt and miss the first command.
            # Install now; its precmd call reports this prompt. Arm only when PS1 is
            # drawn, because the rest of this prompt's PROMPT_COMMAND is not a command.
            # A later prompt hook that replaces PS1 loses only this first report.
            builtin true
            __bp_install
            __bp_preexec_interactive_mode=
            PS1='${_slate_nil:$((__bp_preexec_interactive_mode=1)):0}'${PS1-}
        else
            _slate_ensure
            # The bootstrap runs inside the first prompt, so report that prompt now,
            # with status 0 rather than that of the test above.
            builtin true
            _slate_prompt
        fi
    fi
    # Drop the bootstrap entry; bash already copied the value it is executing.
    if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
        for _slate_i in "${!PROMPT_COMMAND[@]}"; do
            [[ ${PROMPT_COMMAND[_slate_i]} == *SLATE_TERM_BASH_INIT* ]] && builtin unset 'PROMPT_COMMAND[_slate_i]'
        done
        builtin unset _slate_i
    else
        # Remove the entry with its separator. Leaving a placeholder such as `:` would
        # reset $? for every later entry, including the user's own prompt hooks.
        _slate_boot='builtin source "$SLATE_TERM_BASH_INIT"'
        for _slate_sep in ';' $'\n'; do
            PROMPT_COMMAND=${PROMPT_COMMAND//"$_slate_boot$_slate_sep"/}
            PROMPT_COMMAND=${PROMPT_COMMAND//"$_slate_sep$_slate_boot"/}
        done
        PROMPT_COMMAND=${PROMPT_COMMAND//"$_slate_boot"/}
        builtin unset _slate_boot _slate_sep
    fi
    builtin export -n PROMPT_COMMAND
    """#

    /// fish 3.1+ (`string collect`), loaded with `--init-command` after config.fish. fish edits
    /// a multi-line command in one buffer, so an empty `commandline` at a prompt really is an
    /// empty prompt. The run key is a single private-use character, which fish 3 and fish 4
    /// both bind as a plain key.
    public static let fishHooks = #"""
    set -l __slate_version (string split . -- $version)
    # One line: in fish a new line would end the condition.
    if status is-interactive; and set -q SLATE_TERM_CONTEXT_TOKEN; and test -z "$SLATE_TERM_SHELL_PID"; and begin; test "$__slate_version[1]" -gt 3 2>/dev/null; or begin; test "$__slate_version[1]" -eq 3 2>/dev/null; and test "$__slate_version[2]" -ge 1 2>/dev/null; end; end
        set -gx SLATE_TERM_SHELL_PID $fish_pid
        set -g __slate_n 0
        set -g __slate_status 0
        # Only a command prompt sets this; `read` and running programs never do.
        set -g __slate_at_prompt 0
        # fish_postexec is where the command's status is defined; empty lines keep the last one.
        function __slate_postexec --on-event fish_postexec
            set -g __slate_status $status
        end
        function __slate_prompt --on-event fish_prompt
            set -g __slate_n (math "$__slate_n + 1")
            set -g __slate_at_prompt 1
            "$SLATE_TERM_CLI" shell update --shell fish --run-input true --state prompt --pid $fish_pid --sequence (math "2 * $__slate_n") --cwd="$PWD" --exit-code $__slate_status >/dev/null 2>&1
        end
        function __slate_preexec --on-event fish_preexec
            set -g __slate_at_prompt 0
            set -l command (string sub --length 4096 -- "$argv[1]" | string collect)
            "$SLATE_TERM_CLI" shell update --shell fish --run-input true --state running --pid $fish_pid --sequence (math "2 * $__slate_n + 1") --cwd="$PWD" --command="$command" >/dev/null 2>&1
        end
        function __slate_run
            set -l options
            set -l buffer (commandline | string collect)
            if test -z "$buffer"; and test "$__slate_at_prompt" = 1; and not commandline --paging-mode; and not commandline --search-mode 2>/dev/null
                set options --empty-buffer
            end
            set -l line ("$SLATE_TERM_CLI" shell run-input --pid $fish_pid $options 2>/dev/null | string collect); or return 0
            test -n "$line"; or return 0
            commandline --replace -- $line
            commandline --function execute
        end
        # User bindings survive fish_vi_key_bindings, which only resets the preset layer.
        for mode in default insert visual
            bind --mode $mode \U10FFFD __slate_run
        end
        # fish emits fish_prompt for the first prompt after this file is read.
    end
    """#
}
