//! Shell completion script generation for `zkdocs --generate-completion
//! <bash|zsh|fish>` (plans/future_features.md §10.2). Static flag/command
//! names are known at generation time and baked into the script; symbol
//! names are project-specific, so each script instead shells out to
//! `zkdocs --list-symbols` at completion time (see `show.printSymbolNames`)
//! to complete `zkdocs show <TAB>` against the real symbol tree of whatever
//! project the user's shell is currently in.
const std = @import("std");
const zargs = @import("zargunaught");
const Printer = zargs.print.Printer;

pub const Shell = enum {
    bash,
    zsh,
    fish,

    pub fn fromStr(s: []const u8) ?Shell {
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        return null;
    }
};

pub fn printScript(printer: *const Printer, shell: Shell) !void {
    switch (shell) {
        .bash => try printer.print("{s}", .{bash_script}),
        .zsh => try printer.print("{s}", .{zsh_script}),
        .fish => try printer.print("{s}", .{fish_script}),
    }
}

const bash_script =
    \\# zkdocs bash completion.
    \\# Install: zkdocs --generate-completion bash > /etc/bash_completion.d/zkdocs
    \\# or source it from your .bashrc.
    \\_zkdocs_completions() {
    \\    local cur prev
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\
    \\    local flags="--conf --root --name --out --theme --emoji --dump --verbose --version --help --list-symbols --generate-completion"
    \\    local commands="show"
    \\
    \\    if [[ "$prev" == "show" ]]; then
    \\        COMPREPLY=( $(compgen -W "$(zkdocs --list-symbols 2>/dev/null)" -- "$cur") )
    \\        return
    \\    fi
    \\
    \\    case "$prev" in
    \\        --theme)
    \\            COMPREPLY=( $(compgen -W "default monokai vscode-light vscode-dark" -- "$cur") )
    \\            return ;;
    \\        --emoji)
    \\            COMPREPLY=( $(compgen -W "none unicode twemoji noto openmoji" -- "$cur") )
    \\            return ;;
    \\        --generate-completion)
    \\            COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
    \\            return ;;
    \\        --conf|--root|--out)
    \\            COMPREPLY=( $(compgen -f -- "$cur") )
    \\            return ;;
    \\        --name)
    \\            return ;;
    \\    esac
    \\
    \\    if [[ "$cur" == -* ]]; then
    \\        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
    \\    elif [[ "$COMP_CWORD" == 1 ]]; then
    \\        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\    fi
    \\}
    \\complete -F _zkdocs_completions zkdocs
    \\
;

const zsh_script =
    \\#compdef zkdocs
    \\# zkdocs zsh completion.
    \\# Install: zkdocs --generate-completion zsh > "${fpath[1]}/_zkdocs"
    \\
    \\_zkdocs() {
    \\    local -a flags
    \\    flags=(
    \\        '(-c --conf)'{-c,--conf}'[Path to zkdocs.conf project config file]:file:_files'
    \\        '(-r --root)'{-r,--root}'[Root source file to extract symbols from]:file:_files'
    \\        '(-n --name)'{-n,--name}'[Display name for the project]:name:'
    \\        '(-o --out)'{-o,--out}'[Output directory for generated docs]:dir:_files -/'
    \\        '(-t --theme)'{-t,--theme}'[Color theme]:theme:(default monokai vscode-light vscode-dark)'
    \\        '(-e --emoji)'{-e,--emoji}'[Emoji provider]:provider:(none unicode twemoji noto openmoji)'
    \\        '(-d --dump)'{-d,--dump}'[Dump the full extracted symbol tree to stdout]'
    \\        '(-V --verbose)'{-V,--verbose}"[With show/--dump, also print each function's body source]"
    \\        '(-v --version)'{-v,--version}'[Print the zkdocs version and exit]'
    \\        '(-h --help)'{-h,--help}'[Print help information]'
    \\        '--list-symbols[Print all documented symbol names, one per line]'
    \\        '--generate-completion[Print a shell completion script]:shell:(bash zsh fish)'
    \\    )
    \\
    \\    if (( CURRENT == 2 )); then
    \\        local -a symbols commands
    \\        symbols=(${(f)"$(zkdocs --list-symbols 2>/dev/null)"})
    \\        commands=("show:Print a symbol's signature and doc comment")
    \\        _describe -t commands 'command' commands
    \\        _describe -t symbols 'symbol' symbols
    \\        _arguments -s $flags
    \\        return
    \\    fi
    \\
    \\    if [[ ${words[2]} == show ]]; then
    \\        local -a symbols
    \\        symbols=(${(f)"$(zkdocs --list-symbols 2>/dev/null)"})
    \\        _describe -t symbols 'symbol' symbols
    \\        return
    \\    fi
    \\
    \\    _arguments -s $flags
    \\}
    \\
    \\_zkdocs "$@"
    \\
;

const fish_script =
    \\# zkdocs fish completion.
    \\# Install: zkdocs --generate-completion fish > ~/.config/fish/completions/zkdocs.fish
    \\
    \\function __zkdocs_list_symbols
    \\    zkdocs --list-symbols 2>/dev/null
    \\end
    \\
    \\complete -c zkdocs -n '__fish_use_subcommand' -a show -d "Print a symbol's signature and doc comment"
    \\complete -c zkdocs -n '__fish_seen_subcommand_from show' -a '(__zkdocs_list_symbols)'
    \\
    \\complete -c zkdocs -s c -l conf -d 'Path to zkdocs.conf project config file' -rF
    \\complete -c zkdocs -s r -l root -d 'Root source file to extract symbols from' -rF
    \\complete -c zkdocs -s n -l name -d 'Display name for the project' -r
    \\complete -c zkdocs -s o -l out -d 'Output directory for generated docs' -rF
    \\complete -c zkdocs -s t -l theme -d 'Color theme' -rxa 'default monokai vscode-light vscode-dark'
    \\complete -c zkdocs -s e -l emoji -d 'Emoji provider' -rxa 'none unicode twemoji noto openmoji'
    \\complete -c zkdocs -s d -l dump -d 'Dump the full extracted symbol tree to stdout'
    \\complete -c zkdocs -s V -l verbose -d "Also print each function's body source"
    \\complete -c zkdocs -s v -l version -d 'Print the zkdocs version and exit'
    \\complete -c zkdocs -s h -l help -d 'Print help information'
    \\complete -c zkdocs -l list-symbols -d 'Print all documented symbol names, one per line'
    \\complete -c zkdocs -l generate-completion -d 'Print a shell completion script' -rxa 'bash zsh fish'
    \\
;
