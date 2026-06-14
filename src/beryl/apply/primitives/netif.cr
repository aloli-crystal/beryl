require "../primitive"

module Beryl::Apply
  # Primitive `netif` : pose une IP statique sur une interface réseau, de
  # façon persistante (`sysrc ifconfig_<iface>`) ET immédiate (`ifconfig`).
  # Idempotente : skip si l'interface porte déjà l'IP ET que le rc.conf est
  # à jour. Ne touche QUE l'interface nommée (sûr pour une iface privée
  # comme le vRack — l'interface publique n'est pas affectée).
  #
  #     - netif:
  #         iface: ix1
  #         ip: 192.168.42.10
  #         netmask: 255.255.255.0   # optionnel
  class Netif < Primitive
    def name : String
      "netif"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      iface = (string(params, "iface") || "auto").strip
      ip = required_string(params, "ip")
      return StepResult.failed("`ip` requis (IP privée du host sur le réseau)") if ip.empty?
      netmask = string(params, "netmask") || "255.255.255.0"

      # Auto-détection (iface vide ou "auto") : le NIC vRack = la SEULE
      # interface Ethernet physique `status: active` SANS IPv4 (l'interface
      # publique en a une ; l'USB/IPMI `ue*`, le loopback et les ifaces
      # virtuelles sont exclus). Ambiguïté ou absence → on exige un `iface:`.
      if iface.empty? || iface == "auto"
        candidates = detect_vrack_iface(shell)
        case candidates.size
        when 1 then iface = candidates.first
        when 0
          return StepResult.failed("auto-détection : aucune interface Ethernet active sans IPv4 — précisez `iface:` explicitement")
        else
          return StepResult.failed("auto-détection ambiguë (#{candidates.join(", ")}) — précisez `iface:`")
        end
      end

      # L'interface doit EXISTER avant toute écriture : sinon netif
      # laisserait un `ifconfig_<iface>` parasite dans rc.conf (warning au
      # boot) et renverrait une erreur opaque. On échoue tôt en listant les
      # interfaces — le nom du NIC vRack varie selon le matériel (ix, igb,
      # bce, mlxen…), `ix1` n'est qu'un défaut.
      unless shell.exec("ifconfig #{Process.quote(iface)} 2>/dev/null", raise_on_error: false).success?
        available = shell.exec("ifconfig -l 2>/dev/null", raise_on_error: false).stdout.strip
        return StepResult.failed("interface #{iface} absente — interfaces disponibles : #{available}")
      end

      rc_var = "ifconfig_#{iface}"
      rc_val = "inet #{ip} netmask #{netmask}"
      has_ip = shell.exec(
        "ifconfig #{Process.quote(iface)} inet 2>/dev/null | grep -qw #{Process.quote(ip)}",
        raise_on_error: false,
      ).success?
      rc_current = shell.exec("sysrc -n #{Process.quote(rc_var)} 2>/dev/null", raise_on_error: false).stdout.strip

      if has_ip && rc_current == rc_val
        return StepResult.skipped("#{iface} déjà à #{ip}")
      end
      return StepResult.applied("#{iface} → #{ip} netmask #{netmask} (dry-run)") if dry_run

      shell.exec("sysrc #{Process.quote("#{rc_var}=#{rc_val}")}")                                                # persistance (boot)
      shell.exec("ifconfig #{Process.quote(iface)} inet #{Process.quote(ip)} netmask #{Process.quote(netmask)}") # immédiat
      StepResult.applied("#{iface} configuré : #{ip} netmask #{netmask}")
    end

    # Détecte le(s) NIC vRack candidats : interface Ethernet physique
    # `status: active` SANS adresse IPv4 (l'IPv6 link-local ne compte pas).
    # Exclut loopback, USB/IPMI (`ue*`) et interfaces virtuelles. Le caller
    # n'accepte la détection que si elle renvoie EXACTEMENT un candidat.
    private def detect_vrack_iface(shell : Shell) : Array(String)
      script = "for i in $(ifconfig -l ether 2>/dev/null); do " \
               "case \"$i\" in ue*|lo*|tap*|tun*|bridge*|vlan*|wg*) continue;; esac; " \
               "ifconfig \"$i\" 2>/dev/null | grep -q 'status: active' || continue; " \
               "ifconfig \"$i\" 2>/dev/null | grep -qw inet && continue; " \
               "echo \"$i\"; done"
      shell.exec(script, raise_on_error: false).stdout.split
    end
  end

  Primitive.register(Netif.new)
end
