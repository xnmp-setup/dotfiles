# Gruvbox — classic retro-warm dark color scheme (medium contrast)
# Palette: bg0=#282828, red=#FB4934, green=#B8BB26, yellow=#FABD2F, aqua=#8EC07C, blue=#83A598, purple=#D3869B

typeset -g POWERLEVEL9K_DIR_FOREGROUND=109        # gruvbox blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=238  # muted bg3 border
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=108  # gruvbox aqua

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=142   # gruvbox green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=142
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=214 # gruvbox yellow
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=142

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=167  # gruvbox red
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=203  # bright gruvbox red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=108  # gruvbox aqua
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=142
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=142
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=167
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=167
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=167

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=167  # gruvbox red

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%142F'  # gruvbox green
typeset -g MY_GIT_COLOR_MODIFIED='%214F'  # gruvbox yellow
typeset -g MY_GIT_COLOR_UNTRACKED='%109F'  # gruvbox blue
typeset -g MY_GIT_COLOR_CONFLICTED='%203F'  # bright gruvbox red
