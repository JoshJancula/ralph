#!/usr/bin/env bash
# ANSI styling for install.sh. Disable when NO_COLOR is set (any value; see https://no-color.org) or
# RALPH_INSTALL_NO_COLOR=1. No output when sourced except via install_colors_init / install_print_help.
#
# All printf calls use an explicit format string as the first argument so placeholders are never
# mistaken for literal text (printf only interprets % in the format string, not in data arguments).
#
# Installer --help uses the shared help-render helpers (stdout TTY only for color). Progress
# logging below may also color when stderr is a TTY so status lines stay readable when stdout
# is redirected.

_install_colors_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_help_style_init &>/dev/null; then
  # shellcheck source=../help-render.sh
  source "$_install_colors_dir/../help-render.sh"
fi

install_colors_init() {
  if [[ ( -t 1 || -t 2 ) && "${NO_COLOR+x}" != x && "${RALPH_INSTALL_NO_COLOR:-0}" != "1" ]]; then
    C_R=$'\033[31m'
    C_G=$'\033[32m'
    C_Y=$'\033[33m'
    C_B=$'\033[34m'
    C_MAG=$'\033[35m'
    C_C=$'\033[36m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
  else
    C_R="" C_G="" C_Y="" C_B="" C_MAG="" C_C="" C_BOLD="" C_DIM="" C_RST=""
  fi
}

# Structured installer help for ./install.sh --help and ralph install --help.
# Writes to stdout. Color only when stdout is a TTY (via ralph_help_style_init).
install_print_help() {
  ralph_help_title 'Usage: ./install.sh [OPTIONS] [TARGET_DIR]'
  ralph_help_note 'Also: ralph install [OPTIONS] [TARGET_DIR] (after a global install).'
  ralph_help_note 'TARGET_DIR defaults to the current directory. Mutually exclusive with --global.'
  ralph_help_note 'See docs/INSTALL.md for layout, upgrade, and runtime config precedence.'

  ralph_help_section 'Local install'
  ralph_help_note 'Copy shared .ralph/ scripts, optional runtime rules/skills/hooks, and the dashboard into a project.'
  ralph_help_note 'Default is a full stack (--all). Stack flags limit which runtimes are copied.'
  ralph_help_note 'Does not install native runtime agent profiles.'

  ralph_help_section 'Global install'
  ralph_help_note 'Install once under ${RALPH_HOME:-$HOME/.ralph}/ for use across projects.'
  ralph_help_note 'Writes config to ${XDG_CONFIG_HOME:-$HOME/.config}/ralph/ and state to ${XDG_STATE_HOME:-$HOME/.local/state}/ralph/.'
  ralph_help_note 'Creates ~/.local/bin/ralph. Copies docs/ to $RALPH_HOME/docs/ when present.'
  ralph_help_note 'Without --force-global-runtime, existing $HOME/.<runtime>/ configs are preserved.'

  ralph_help_section 'Update / removal'
  ralph_help_note 'Re-run install to upgrade installer-owned assets. Recognized six-ID Ralph agent profile outputs are removed on upgrade; unrelated native agent files are preserved.'
  ralph_help_note 'Subtree-style vendor copies under TARGET are removed after install unless kept (submodule/clone, RALPH_INSTALL_KEEP_VENDOR=1). Set RALPH_INSTALL_REMOVE_VENDOR=1 to force vendor removal.'
  ralph_help_note '--uninstall removes Ralph-installed files from the manifest; --remove-vendor/--cleanup remove the vendored package directory; --purge does both for all stacks.'

  ralph_help_section 'Workflow / plugin follow-up'
  ralph_help_note 'Bundled workflows under bundle/.ralph/workflows/ install as installer-owned assets under TARGET/.ralph/workflows/ (local) or $RALPH_HOME/bundle/.ralph/workflows/ (global).'
  ralph_help_note 'Project state-root workflows and $RALPH_HOME/workflows/ are user data and are never recorded, overwritten, migrated, or uninstalled.'
  ralph_help_note 'Legacy .ralph/workflow-templates/ under the installer-owned root is removed on upgrade/uninstall.'
  ralph_help_note 'Generated plugin packages under plugins/ralph-orchestrator/<runtime>/ copy to $RALPH_HOME/plugins/ralph-orchestrator/<runtime>/ as installer-owned assets (local and global).'
  ralph_help_note 'Install validates package version/source metadata, updates those owned copies, and never host-installs plugins or touches $RALPH_HOME/plugin-installs/ journals.'
  ralph_help_note 'Uninstall removes packaged plugin assets under $RALPH_HOME/plugins/ only; host registrations and journals stay.'
  ralph_help_note 'After install, use ralph create workflow / ralph workflow start for workflows, and ralph plugin for host plugin lifecycle (install does not host-install plugins).'

  ralph_help_section 'Options'
  ralph_help_option '--all' '' 'Install everything (default).'
  ralph_help_option '--global' '' 'Global install under $RALPH_HOME (no TARGET_DIR).'
  ralph_help_option '--force-global-runtime' '' 'With --global, overwrite/update existing $HOME/.<runtime>/ configs.'
  ralph_help_option '--shared' '' 'Only .ralph/ (orchestrator, cleanup, plan-templates/, docs -> .ralph/docs/), including bash-lib helpers used by runtime hooks.'
  ralph_help_option '--cursor' '' '.cursor/ rules/skills; does not install native agents.'
  ralph_help_option '--codex' '' '.codex/ rules/skills + hooks/; does not install native agents.'
  ralph_help_option '--claude' '' '.claude/ rules/skills + hooks/; does not install native agents.'
  ralph_help_option '--opencode' '' '.opencode/ rules/skills + plugins/; does not install native agents.'
  ralph_help_option '--antigravity' '' '.agents/ rules/skills + hooks/; does not install native agents or agents.md.'
  ralph_help_option '--no-dashboard' '' 'Skip copying the dashboard (local: TARGET/.ralph/ralph-dashboard/; global: $RALPH_HOME/ralph-dashboard/).'
  ralph_help_option '-s, --silent' '' 'Non-interactive: skip conflicts, MCP prompts, and removal prompts.'
  ralph_help_option '-y, --yes' '' 'Assume yes for the already-installed overwrite prompt.'
  ralph_help_option '-n, --dry-run' '' 'Print what would be copied or removed; do not write.'
  ralph_help_option '-h, --help' '' 'Show this help on stdout and exit.'
  ralph_help_option '--remove-installed, --uninstall' '' 'Remove Ralph-installed files under TARGET (bundle manifest; honors stack flags).'
  ralph_help_option '--remove-vendor' '' 'Remove the vendored Ralph package directory when it sits under TARGET.'
  ralph_help_option '--cleanup' '' 'Same as --remove-vendor.'
  ralph_help_option '--purge' '' 'Full removal: uninstall all stacks and the dashboard, then remove vendor.'
  ralph_help_note 'NO_COLOR (any value) or RALPH_INSTALL_NO_COLOR=1 disables colored installer and help output.'

  ralph_help_section 'Examples'
  ralph_help_note 'git submodule add https://github.com/you/ralph.git vendor/ralph'
  ralph_help_note './vendor/ralph/install.sh'
  ralph_help_note './vendor/ralph/install.sh --cursor /path/to/other-repo'
  ralph_help_note './vendor/ralph/install.sh --antigravity /path/to/other-repo'
  ralph_help_note './install.sh --global'
  ralph_help_note './install.sh --global --yes'
  ralph_help_note './vendor/ralph/install.sh --cleanup -n'
  ralph_help_note './vendor/ralph/install.sh --purge --silent'
  ralph_help_note 'ralph install --help'
}

install_log_banner() {
  printf '%b%s%b %b%s%b\n' "${C_MAG}${C_BOLD}" "${1:-Ralph}" "${C_RST}" "${C_DIM}" "${2:-}" "${C_RST}"
}

install_log_phase() {
  printf '%b%s%b\n' "${C_C}${C_BOLD}" "$1" "${C_RST}"
}

install_log_ok() {
  printf '%b%s%b %b%s%b\n' "${C_G}${C_BOLD}" "$1" "${C_RST}" "${C_B}" "$2" "${C_RST}"
}

install_log_ok_detail() {
  printf '  %b%s%b %b%s%b\n' "${C_DIM}" "$1" "${C_RST}" "${C_B}" "$2" "${C_RST}"
}

install_log_skip() {
  printf '%b%s%b %b%s%b\n' "${C_Y}" "$1" "${C_RST}" "${C_DIM}" "$2" "${C_RST}" >&2
}

install_log_warn() {
  if [[ -n "${2:-}" ]]; then
    printf '%b%s%b %s\n' "${C_Y}${C_BOLD}" "$1" "${C_RST}" "$2" >&2
  else
    printf '%b%s%b\n' "${C_Y}" "$1" "${C_RST}" >&2
  fi
}

install_log_err() {
  if [[ -n "${2:-}" ]]; then
    printf '%b%s%b %s\n' "${C_R}${C_BOLD}" "$1" "${C_RST}" "$2" >&2
  else
    printf '%b%s%b\n' "${C_R}" "$1" "${C_RST}" >&2
  fi
}

install_log_dry() {
  printf '%b%s%b %s\n' "${C_Y}${C_BOLD}" "$1" "${C_RST}" "$2"
}

install_log_next_header() {
  printf '%b%s%b\n' "${C_C}${C_BOLD}" "$1" "${C_RST}"
}

install_log_next_line() {
  printf '  %b%s%b\n' "${C_DIM}" "$1" "${C_RST}"
}

install_log_divider() {
  printf '%b%s%b\n' "${C_MAG}${C_DIM}" "$1" "${C_RST}"
}
