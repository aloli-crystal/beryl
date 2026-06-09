require "./bootstrap/mfsbsd_release"
require "./bootstrap/qemu_in_rescue"

# `MfsBSD` reste dispo (legacy, plus sur le chemin principal). La classe
# `Installer` (mono-disque) a été RETIRÉE : elle dupliquait le rendu de
# `install-pkgbase.sh` et est devenue incompatible avec le template
# multi-disque (Phase 2). La voie unique est `QemuInRescue`.
# Voir ADR-010 (ARCHITECTURE.adoc) et ADR-011.
require "./bootstrap/mfsbsd"

module Beryl
  # Bootstrap complet : Linux rescue → FreeBSD 15 installé UEFI-compatible.
  #
  # Depuis ADR-011 (supersede ADR-003), la voie principale est
  # `Beryl::Bootstrap::QemuInRescue` : FreeBSD s'installe dans une VM
  # QEMU lancée *depuis* le rescue Linux, avec le disque réel en
  # passthrough. Résultat : un système UEFI-bootable posé nativement
  # sur le bare metal, sans la couche mfsBSD qui ne boote pas sur les
  # firmwares UEFI-only modernes.
  module Bootstrap
  end
end
