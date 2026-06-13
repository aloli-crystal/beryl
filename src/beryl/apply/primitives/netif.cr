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
      iface = required_string(params, "iface")
      ip = required_string(params, "ip")
      return StepResult.failed("`ip` requis (IP privée du host sur le réseau)") if ip.empty?
      netmask = string(params, "netmask") || "255.255.255.0"

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
  end

  Primitive.register(Netif.new)
end
