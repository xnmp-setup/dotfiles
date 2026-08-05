# Catppuccin Mocha — deep purple-blue base with soft pastel accents
# Palette: bg=#1e1e2e, accent=#cba6f7, green=#a6e3a1, yellow=#f9e2af, blue=#89b4fa, magenta=#f5c2e7, red=#f38ba8, cyan=#94e2d5

typeset -g POWERLEVEL9K_DIR_FOREGROUND=111        # soft entity blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=243  # muted blue-grey
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=183  # bright lavender

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=151   # soft green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=151
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=223 # warm yellow
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=151

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=151  # soft green
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=211  # red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=116  # cyan
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=151
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=151
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=211
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=211
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=211

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=211  # red

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%151F'  # soft green
typeset -g MY_GIT_COLOR_MODIFIED='%223F'  # warm yellow
typeset -g MY_GIT_COLOR_UNTRACKED='%111F'  # entity blue
typeset -g MY_GIT_COLOR_CONFLICTED='%211F'  # red
