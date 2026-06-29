#!/usr/bin/env bash
# Safely detects locally installed JetBrains IDEs on macOS/Linux.
# This script only inventories installation/config/cache paths.
# It does not modify files, environment variables, VM options, licenses, or network settings.

set -u

OUTPUT_JSON=false
if [[ "${1:-}" == "--json" ]]; then
  OUTPUT_JSON=true
fi

case "$(uname -s)" in
  Darwin) OS="macOS" ;;
  Linux)  OS="Linux" ;;
  *)      OS="Unknown" ;;
esac

PRODUCT_MAP=$'idea:IntelliJ IDEA\nidea64:IntelliJ IDEA\npycharm:PyCharm\npycharm64:PyCharm\nwebstorm:WebStorm\nwebstorm64:WebStorm\nrider:Rider\nrider64:Rider\ndatagrip:DataGrip\ndatagrip64:DataGrip\nclion:CLion\nclion64:CLion\ngoland:GoLand\ngoland64:GoLand\nphpstorm:PhpStorm\nphpstorm64:PhpStorm\nrubymine:RubyMine\nrubymine64:RubyMine\ndataspell:DataSpell\ndataspell64:DataSpell\nrustrover:RustRover\nrustrover64:RustRover\nappcode:AppCode'

json_escape() {
  local s=${1//\\/\\\\}
  s=${s//"/\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

product_name_for_exe() {
  local exe="$1"
  local key="${exe%.*}"
  printf '%s\n' "$PRODUCT_MAP" | awk -F: -v k="$key" '$1 == k { print $2; found=1 } END { if (!found) exit 1 }'
}

add_existing_root() {
  local root="$1"
  [[ -n "$root" && -d "$root" ]] && printf '%s\n' "$root"
}

candidate_roots() {
  if [[ "$OS" == "macOS" ]]; then
    add_existing_root "/Applications"
    add_existing_root "$HOME/Applications"
    add_existing_root "$HOME/Library/Application Support/JetBrains/Toolbox/apps"
    add_existing_root "/opt/JetBrains"
    add_existing_root "$HOME/JetBrains"
  else
    add_existing_root "$HOME/.local/share/JetBrains/Toolbox/apps"
    add_existing_root "$HOME/.cache/JetBrains"
    add_existing_root "$HOME/.config/JetBrains"
    add_existing_root "$HOME/JetBrains"
    add_existing_root "/opt/JetBrains"
    add_existing_root "/usr/local/JetBrains"
    add_existing_root "/snap"
    for mount_root in /mnt/* /media/*; do
      [[ -d "$mount_root/JetBrains" ]] && add_existing_root "$mount_root/JetBrains"
    done
  fi
}

read_idea_property() {
  local install_path="$1"
  local key="$2"
  local properties_file="$install_path/bin/idea.properties"
  [[ -f "$properties_file" ]] || return 0

  local value
  value=$(awk -F= -v k="$key" '
    $0 !~ /^\s*#/ && $1 ~ "^\\s*" k "\\s*$" {
      sub(/^[^=]*=/, "")
      gsub(/^\s+|\s+$/, "")
      print
      exit
    }' "$properties_file")

  [[ -z "$value" ]] && return 0
  value="${value//\$\{user.home\}/$HOME}"
  printf '%s\n' "$value"
}

find_installations() {
  local roots
  roots=$(candidate_roots | awk '!seen[$0]++')

  while IFS= read -r root; do
    [[ -n "$root" ]] || continue

    while IFS= read -r exe_path; do
      [[ -f "$exe_path" ]] || continue

      local exe_name bin_path install_path product_name custom_config source_root
      exe_name=$(basename "$exe_path")
      product_name=$(product_name_for_exe "$exe_name" 2>/dev/null || true)
      [[ -n "$product_name" ]] || continue

      bin_path=$(dirname "$exe_path")
      install_path=$(dirname "$bin_path")
      custom_config=$(read_idea_property "$install_path" "idea.config.path")
      source_root="$root"

      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$product_name" "$exe_name" "$install_path" "$bin_path" "$source_root" "$custom_config"
    done < <(find "$root" -maxdepth 9 -type f \( \
      -name 'idea' -o -name 'idea64' -o -name 'idea.sh' -o \
      -name 'pycharm' -o -name 'pycharm64' -o -name 'pycharm.sh' -o \
      -name 'webstorm' -o -name 'webstorm64' -o -name 'webstorm.sh' -o \
      -name 'rider' -o -name 'rider64' -o -name 'rider.sh' -o \
      -name 'datagrip' -o -name 'datagrip64' -o -name 'datagrip.sh' -o \
      -name 'clion' -o -name 'clion64' -o -name 'clion.sh' -o \
      -name 'goland' -o -name 'goland64' -o -name 'goland.sh' -o \
      -name 'phpstorm' -o -name 'phpstorm64' -o -name 'phpstorm.sh' -o \
      -name 'rubymine' -o -name 'rubymine64' -o -name 'rubymine.sh' -o \
      -name 'dataspell' -o -name 'dataspell64' -o -name 'dataspell.sh' -o \
      -name 'rustrover' -o -name 'rustrover64' -o -name 'rustrover.sh' -o \
      -name 'appcode' -o -name 'appcode.sh' \
    \) 2>/dev/null)
  done <<< "$roots" | awk -F '\t' '!seen[$3 FS $2]++'
}

RESULTS=$(find_installations)

if [[ -z "$RESULTS" ]]; then
  echo "No JetBrains IDE installations were found in common locations, Toolbox folders, /opt, /snap, or mounted JetBrains folders." >&2
  echo "Tip: run with --json for machine-readable output, or add your custom root to candidate_roots()." >&2
  exit 2
fi

if [[ "$OUTPUT_JSON" == true ]]; then
  echo '['
  first=true
  while IFS=$'\t' read -r product executable install_path bin_path source_root custom_config; do
    [[ "$first" == true ]] || echo ','
    first=false
    printf '  {"product":"%s","executable":"%s","installPath":"%s","binPath":"%s","sourceRoot":"%s","customConfigPath":"%s"}' \
      "$(json_escape "$product")" \
      "$(json_escape "$executable")" \
      "$(json_escape "$install_path")" \
      "$(json_escape "$bin_path")" \
      "$(json_escape "$source_root")" \
      "$(json_escape "$custom_config")"
  done <<< "$RESULTS"
  echo
  echo ']'
else
  printf '%-18s %-18s %s\n' 'Product' 'Executable' 'InstallPath'
  printf '%-18s %-18s %s\n' '-------' '----------' '-----------'
  while IFS=$'\t' read -r product executable install_path _bin_path _source_root _custom_config; do
    printf '%-18s %-18s %s\n' "$product" "$executable" "$install_path"
  done <<< "$RESULTS"
fi
