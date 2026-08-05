# Horizon Dark — cinematic sunset-noir dark color scheme
# Palette: bg=#1c1e26, red=#e95678, green=#29d398, yellow/orange=#fab795, cyan=#59e1e3, blue=#26bbd9, magenta=#ee64ac

typeset -g POWERLEVEL9K_DIR_FOREGROUND=38        # horizon blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=236  # muted bg3 border
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=80  # horizon cyan

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=42   # horizon green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=42
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=216 # horizon orange
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=42

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=204  # horizon red
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=211  # bright horizon red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=80  # horizon cyan
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=42
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=42
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=204
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=204
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=204

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=204  # horizon red

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%42F'  # horizon green
typeset -g MY_GIT_COLOR_MODIFIED='%216F'  # horizon orange
typeset -g MY_GIT_COLOR_UNTRACKED='%38F'  # horizon blue
typeset -g MY_GIT_COLOR_CONFLICTED='%211F'  # bright horizon red
