# Moteur `beryl apply` — architecture à 2 niveaux (cf.
# `apply-recipes-architecture.adoc`) :
#
#   * Niveau 1 — PRIMITIVES : tâches élémentaires idempotentes en
#     Crystal natif (`pkg-install`, …), enregistrées dans un registre.
#   * Niveau 2 — RECETTES YAML : fichiers `.yml` reliés par `requires:`,
#     résolus récursivement + tri topologique, exécutés step par step.
#
# Phase 1 (PoC) : `pkg-install` + résolveur + exécuteur. Les autres
# primitives (`service-enable`, `sysrc-set`, `user-update-keys`, …)
# arrivent en Phase 2.
require "./apply/shell"
require "./apply/primitive"
require "./apply/primitives/pkg_install"
require "./apply/template"
require "./apply/recipe"
require "./apply/resolver"
require "./apply/executor"

module Beryl::Apply
end
