require "ssh"

module Beryl::CLI
  # Pilotage d'un contrôleur RAID MATÉRIEL (MegaRAID, via `storcli`) DANS LE
  # RESCUE, avant bootstrap. Le rescue OVH ne fournit aucun outil contrôleur
  # → on récupère `storcli` depuis `storcli_url` (cf. `aloli/infra-bin`), puis
  # on liste / détruit / reconfigure les volumes.
  #
  # DESTRUCTIF, mais en rescue (avant install) → 100 % rejouable. Après une
  # reconfiguration, on demande à l'opérateur de REBOOTER le rescue : les
  # disques se ré-énumèrent proprement, et un nouveau `beryl scan` voit le
  # résultat (JBOD = N disques bruts, ou le nouveau volume).
  #
  # Les helpers de parsing / construction de commandes sont PURS (testables) ;
  # l'orchestration prend une `SSH::Connection` (le rescue).
  module RaidController
    STORCLI = "/tmp/storcli64"

    # ── Helpers purs (testés) ───────────────────────────────────────────

    # Nombre de contrôleurs d'après `storcli show ctrlcount`
    # (« Controller Count = N »).
    def self.controller_count(output : String) : Int32
      if m = output.match(/Controller Count\s*=\s*(\d+)/)
        m[1].to_i
      else
        0
      end
    end

    # Slots des disques physiques d'après `storcli /cX/eall/sall show` :
    # la 1re colonne « EID:Slt » (ex. « 252:0 ») de chaque ligne disque.
    def self.parse_drive_slots(output : String) : Array(String)
      slots = [] of String
      output.each_line do |line|
        tok = line.strip.split(/\s+/).first?
        next unless tok
        slots << tok if tok =~ /^\d+:\d+$/
      end
      slots.uniq
    end

    # Traduit un niveau RAID numérique beryl en type storcli. Refuse les
    # niveaux non gérés par une carte matérielle (ex. 7 = raidz3, ZFS only).
    def self.raid_type(num : Int32) : String
      case num
      when  0 then "raid0"
      when  1 then "raid1"
      when  5 then "raid5"
      when  6 then "raid6"
      when 10 then "raid10"
      else
        raise ArgumentError.new("le contrôleur ne gère pas RAID #{num} (matériel : 0, 1, 5, 6, 10)")
      end
    end

    def self.create_vd_command(cid : Int32, raid_num : Int32, slots : Array(String)) : String
      "/c#{cid} add vd type=#{raid_type(raid_num)} drives=#{slots.join(",")}"
    end

    # ── Orchestration (rescue) ──────────────────────────────────────────

    # Télécharge storcli dans le rescue et vérifie qu'il s'exécute.
    def self.fetch(conn : SSH::Connection, url : String) : Bool
      dl = conn.exec(
        "curl -fsSL #{Process.quote(url)} -o #{STORCLI} && chmod +x #{STORCLI}",
        raise_on_error: false)
      return false unless dl.success?
      conn.exec("#{STORCLI} show ctrlcount", raise_on_error: false).success?
    end

    # Id du 1er contrôleur (on gère le cas mono-contrôleur, le commun) ; nil
    # si storcli n'en voit aucun.
    def self.controller_id(conn : SSH::Connection) : Int32?
      txt = conn.exec("#{STORCLI} show ctrlcount", raise_on_error: false).stdout
      controller_count(txt) > 0 ? 0 : nil
    end

    # Bascule le contrôleur en JBOD (les disques physiques deviennent des
    # disques bruts pour ZFS) : détruit les volumes puis active le JBOD.
    def self.to_jbod!(conn : SSH::Connection, cid : Int32) : Nil
      # Suppression tolérante (pas de volume = rien à faire).
      conn.exec("#{STORCLI} /c#{cid}/vall delete force", raise_on_error: false)
      run!(conn, "/c#{cid} set jbod=on")
    end

    # Recrée un volume matériel à `raid_num` sur tous les disques physiques.
    def self.recreate!(conn : SSH::Connection, cid : Int32, raid_num : Int32) : Nil
      slots = parse_drive_slots(conn.exec("#{STORCLI} /c#{cid}/eall/sall show", raise_on_error: false).stdout)
      raise "aucun disque physique listé par storcli (/c#{cid}/eall/sall show)" if slots.empty?
      conn.exec("#{STORCLI} /c#{cid}/vall delete force", raise_on_error: false)
      run!(conn, create_vd_command(cid, raid_num, slots))
    end

    # Exécute une commande storcli, lève avec sa sortie si échec (storcli
    # signale « Status = Failure » dans sa sortie en plus du code retour).
    private def self.run!(conn : SSH::Connection, cmd : String) : Nil
      res = conn.exec("#{STORCLI} #{cmd}", raise_on_error: false)
      combined = "#{res.stdout}#{res.stderr}"
      raise "storcli #{cmd} a échoué :\n#{combined.strip}" if !res.success? || combined.includes?("Status = Failure")
    end
  end
end
