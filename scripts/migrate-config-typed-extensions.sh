#!/usr/bin/env bash
# Migration de la config beryl vers les EXTENSIONS TYPÉES (ADR-015).
#
# Renomme les fichiers de `~/.config/beryl/` (ou du chemin passé en
# argument) vers la convention typée :
#   <société>/<domaine>.yml            -> <domaine>.domain.yml
#   <société>/<domaine>/<host>.yml     -> <host>.host.yml
#   <société>/<domaine>/<groupe>.yml   -> <groupe>.group.yml   (si dossier <groupe>/ voisin)
#   <société>/<domaine>/<groupe>/<host>.yml -> <host>.host.yml
#
# NE TOUCHE PAS : `_default.yml`, `_account.yml`, `.env.yml`,
# `.env.toml.age`, ni aucun fichier commençant par `_` ou `.`.
#
# Les recettes du dossier d'orchestration d'un host (`<host>/*.yml`)
# doivent devenir `*.recipe.yml` — ce script les SIGNALE mais ne les
# renomme pas automatiquement (un `.yml` dans un dossier host est
# ambigu : recette vs autre). Renommez-les à la main en `.recipe.yml`.
#
# SÛR PAR DÉFAUT : dry-run (affiche seulement). Ajoutez `--apply` pour
# exécuter. Utilise `git mv` si le dossier société est un dépôt git.
#
# Usage :
#   scripts/migrate-config-typed-extensions.sh [CONFIG_DIR] [--apply]
#   (CONFIG_DIR défaut : $XDG_CONFIG_HOME/beryl ou ~/.config/beryl)

set -euo pipefail

APPLY=false
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/beryl"
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    -h | --help) sed -n '2,/^set -/p' "$0" | sed -n '/^# /s/^# \?//p'; exit 0 ;;
    *) CONFIG_DIR="$arg" ;;
  esac
done

[ -d "$CONFIG_DIR" ] || { echo "Dossier config introuvable : $CONFIG_DIR" >&2; exit 1; }
echo "Config : $CONFIG_DIR"
$APPLY && echo "Mode : APPLY (renommage réel)" || echo "Mode : DRY-RUN (rien n'est modifié — ajoutez --apply)"

# Renomme via git mv si possible, sinon mv.
do_rename() {
  local src="$1" dst="$2" repo
  echo "  $src  ->  $(basename "$dst")"
  $APPLY || return 0
  repo="$(cd "$(dirname "$src")" && git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo" ]; then git -C "$repo" mv "$src" "$dst"; else mv "$src" "$dst"; fi
}

skip() { case "$(basename "$1")" in _*|.*) return 0;; *) return 1;; esac; }

# Sociétés = sous-dossiers (hors _*/.*)
for account in "$CONFIG_DIR"/*/; do
  [ -d "$account" ] || continue
  account="${account%/}"; skip "$account" && continue
  echo "société : $(basename "$account")"

  # Domaines = <account>/<domaine>.yml
  for dyml in "$account"/*.yml; do
    [ -e "$dyml" ] || continue
    skip "$dyml" && continue
    do_rename "$dyml" "${dyml%.yml}.domain.yml"
    domain_dir="${dyml%.yml}"
    [ -d "$domain_dir" ] || continue

    # Contenu du domaine
    for f in "$domain_dir"/*.yml; do
      [ -e "$f" ] || continue
      skip "$f" && continue
      base="${f%.yml}"
      if [ -d "$base" ]; then
        do_rename "$f" "${base}.group.yml"   # groupe (dossier voisin)
        for hf in "$base"/*.yml; do          # membres du groupe
          [ -e "$hf" ] || continue; skip "$hf" && continue
          do_rename "$hf" "${hf%.yml}.host.yml"
        done
      else
        do_rename "$f" "${base}.host.yml"     # host direct
      fi
    done

    # Dossiers d'orchestration <host>/ (à côté d'un <host>.host.yml) :
    # leurs *.yml sont des recettes -> à renommer .recipe.yml À LA MAIN.
    for hostdir in "$domain_dir"/*/; do
      hostdir="${hostdir%/}"
      [ -e "${hostdir}.host.yml" ] || continue
      for r in "$hostdir"/*.yml; do
        [ -e "$r" ] || continue
        echo "  [À FAIRE MANUEL] recette : $r -> $(basename "${r%.yml}").recipe.yml"
      done
    done
  done
done

echo "Terminé.${APPLY:+}"
$APPLY || echo "(dry-run — relancez avec --apply pour exécuter)"
