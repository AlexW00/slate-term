/// Additional host telemetry alongside (not instead of) Ghostty's OSC integration.
/// This wrapper restores the user's startup directory before sourcing their .zshenv;
/// zsh then reads their normal .zprofile/.zshrc. No user files are modified.
public enum ShellIntegration {
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
            "$SLATE_TERM_CLI" shell update --state prompt --pid "$$" --sequence "$_slate_context_sequence" --cwd "$PWD" --exit-code "$previous_status" >/dev/null 2>&1
            return 0
        }
        function _slate_context_preexec() {
            builtin emulate -L zsh -o no_aliases
            (( ++_slate_context_sequence ))
            "$SLATE_TERM_CLI" shell update --state running --pid "$$" --sequence "$_slate_context_sequence" --cwd "$PWD" --command "${1[1,4096]}" >/dev/null 2>&1
            return 0
        }
        'builtin' 'typeset' -ga precmd_functions preexec_functions
        precmd_functions+=(_slate_context_precmd)
        preexec_functions+=(_slate_context_preexec)
    fi
    """#
}
