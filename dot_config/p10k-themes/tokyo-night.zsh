# Tokyo Night — cool, night-city inspired dark color scheme
# Palette: bg=#1a1b26, red=#f7768e, green=#9ece6a, yellow=#e0af68, blue=#7aa2f7, purple=#bb9af7

typeset -g POWERLEVEL9K_DIR_FOREGROUND=111        # tokyo night blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=60  # muted bg2 border
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=80  # tokyo night cyan

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=150   # tokyo night green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=150
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=180 # tokyo night yellow
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=150

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=211  # tokyo night red
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=203  # bright tokyo night red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=80  # tokyo night cyan
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=150
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=150
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=211
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=211
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=211

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=211  # tokyo night red

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%150F'  # tokyo night green
typeset -g MY_GIT_COLOR_MODIFIED='%180F'  # tokyo night yellow
typeset -g MY_GIT_COLOR_UNTRACKED='%111F'  # tokyo night blue
typeset -g MY_GIT_COLOR_CONFLICTED='%203F'  # bright tokyo night red
