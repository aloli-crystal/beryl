require "../primitive"

module Beryl::Apply
  # Primitive `assert-tailscale-up` : refuse la suite si l'interface
  # `tailscale0` n'est pas UP et joint au mesh. Garde-fou indispensable
  # avant de basculer sshd en `ListenAddress {{tailscale_ip4}}` — sans
  # cette vérification, on risque de fermer l'accès SSH sans avoir
  # d'overlay de secours.
  #
  # Le paramètre optionnel `min_uptime_seconds` (défaut 30) impose en
  # plus que la session tailscale soit installée depuis au moins ces N
  # secondes (anti-fluctuation : on n'enchaîne pas un `tailscale up`
  # et un sshd bascule sans laisser le mesh se stabiliser).
  #
  #     - assert-tailscale-up:
  #         min_uptime_seconds: 30
  class AssertTailscaleUp < Primitive
    def name : String
      "assert-tailscale-up"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      min_uptime = string(params, "min_uptime_seconds").try(&.to_i?) || 30

      status_probe = shell.exec("tailscale status >/dev/null 2>&1", raise_on_error: false)
      unless status_probe.success?
        return StepResult.failed("tailscale status échoue : pas de session active sur ce host. Le mesh Headscale n'est pas opérationnel ici, abort.")
      end

      ip_probe = shell.exec("tailscale ip -4 2>/dev/null", raise_on_error: false)
      unless ip_probe.success? && ip_probe.stdout.includes?(".")
        return StepResult.failed("tailscale ip -4 ne retourne aucune IPv4 — interface non opérationnelle, abort.")
      end

      # `tailscale status --json` contient un champ uptime côté upstream
      # mais on ne s'y fie pas (instable selon les versions). Approximation
      # via `ifconfig tailscale0` parse de la durée — ou plus simple,
      # via `service tailscaled onestatus`. Hack pratique : vérifier
      # que `/var/run/tailscale/tailscaled.sock` est plus vieux que
      # `min_uptime` secondes.
      sock_probe = shell.exec(
        "find /var/run/tailscale/tailscaled.sock -mmin -#{(min_uptime / 60.0).ceil} 2>/dev/null | grep -q . && echo TOO_RECENT || echo OK",
        raise_on_error: false,
      )
      if sock_probe.stdout.strip == "TOO_RECENT"
        return StepResult.failed("tailscale up depuis moins de #{min_uptime} s — attendez quelques secondes que le mesh se stabilise et relancez.")
      end

      StepResult.skipped("tailscale UP (IP: #{ip_probe.stdout.strip})")
    end
  end

  Primitive.register(AssertTailscaleUp.new)
end
